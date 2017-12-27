#!/bin/bash -e

export WORKSPACE="${WORKSPACE:-$HOME}"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

# prepared image parameters
image_user="root"
base_image="/var/lib/libvirt/images/ubuntu-xenial.qcow2"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# check if environment is present
if virsh list --all | grep -q "${job_prefix}-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "${job_prefix}-"
  exit 1
fi

function run_machine() {
  local name="$1"
  local cpu="$2"
  local ram="$3"
  local mac_suffix="$4"
  local ip=$5

  echo "INFO: running machine $name $(date)"
  cp "$base_image" $pool_path/$name.qcow2
  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --cpu host \
    --virt-type kvm \
    --os-type=linux \
    --os-variant ubuntu16.04 \
    --disk path=$pool_path/$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$network_name,model=e1000,mac=$mac_base:$mac_suffix \
    --boot hd \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
  virsh net-update $network_name add ip-dhcp-host "<host mac='$mac_base:$mac_suffix' name='$name' ip='$ip' />"
  virsh start $name --force-boot
  echo "INFO: machine $name run $(date)"
}

function wait_kvm_machine() {
  local dest=$1
  local wait_cmd=${2:-ssh}
  local iter=0
  sleep 10
  while ! $wait_cmd $dest "uname -a" &>/dev/null ; do
    ((++iter))
    if (( iter > 9 )) ; then
      echo "ERROR: machine $dest is not accessible $(date)"
      exit 2
    fi
    sleep 10
  done
}

declare -A pkgs
pkgs["cont"]="mc wget bridge-utils"
pkgs["comp"]="mc wget openvswitch-switch sshpass"
pkgs["net"]="mc wget openvswitch-switch"
pkgs["bgp"]="mc wget"

function run_cloud_machine() {
  local prefix=$1
  local index=$2
  local cpu=$3
  local mem=$4
  local mac_var_name="os_${prefix}_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating ${prefix} $index (mac suffix $mac_suffix) $(date)"
  local ip="$network_addr.$mac_suffix"
  local name="${job_prefix}-${prefix}-${index}"

  run_machine $name $cpu $mem $mac_suffix $ip
  echo "INFO: start machine waiting: $name $(date)"
  wait_kvm_machine $image_user@$ip
  echo "INFO: adding machine $name to juju controller $(date)"
  juju-add-machine ssh:$image_user@$ip
  local mch=`get_machine_by_ip $ip`
  wait_kvm_machine $mch juju-ssh
  echo "INFO: machine $name (machine: $mch) is ready to prepare $(date)"
  # apply hostname
  juju-ssh $mch "sudo bash -c 'echo $name > /etc/hostname ; hostname $name'" 2>/dev/null
  # after first boot we must remove cloud-init
  juju-ssh $mch "sudo rm -rf /etc/systemd/system/cloud-init.target.wants /lib/systemd/system/cloud*"
  # add some configuration for lxd 
  juju-ssh $mch "echo 'supersede routers $network_addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  # install packages for node
  juju-ssh $mch "sudo apt-get -fy install ${pkgs[$prefix]}" &>/dev/null
  if [[ "$prefix" == "cont" ]]; then
    juju-scp "$my_dir/files/50-cloud-init-controller-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
    juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
    # steps to allow deploy openstack in lxd containers by juju
    juju-ssh $mch "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $mch "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-lxd\"/m' /etc/default/lxd-bridge" 2>/dev/null
  else
    juju-scp "$my_dir/files/50-cloud-init-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
    juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  fi
  # and reboot it to apply changes
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
}

# create virtual network
create_network $network_name $network_addr

# create volume's pool
virsh pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

# create and run machine for juju controller
cont_ip="$network_addr.$cont_idx"
run_machine ${job_prefix}-cont 1 2048 $cont_idx $cont_ip
wait_kvm_machine $image_user@$cont_ip
# and bootstraps it
echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$image_user@$cont_ip $juju_controller_name

# create and run machine for OpenStack controllers
run_cloud_machine cont 0 $controller_cpu $controller_mem
# create and run machines for compute service
run_cloud_machine comp 1 $compute_cpu $compute_mem
run_cloud_machine comp 2 $compute_cpu $compute_mem
# create and run machines for network nodes
run_cloud_machine net 1 $network_cpu $network_mem
run_cloud_machine net 2 $network_cpu $network_mem
run_cloud_machine net 3 $network_cpu $network_mem
# create and run machine for router emulator
run_cloud_machine bgp 1 $router_cpu $router_mem

# wait for all machines are up
wait_for_all_machines

echo "INFO: Environment created $(date)"

# print deployment status
virsh net-dhcp-leases $network_name
juju-status-tabular

trap - ERR EXIT
