#!/bin/bash -e

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

create_network $network_name $network_addr

# create pool
virsh pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

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

cont_ip="$network_addr.$cont_idx"
run_machine ${job_prefix}-cont 1 2048 $cont_idx $cont_ip
wait_kvm_machine $image_user@$cont_ip

echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$image_user@$cont_ip $juju_controller_name

function run_cloud_machine() {
  local name=${job_prefix}-$1
  local mac_suffix=$2
  local mem=$3
  local ip=$4

  local ip="$network_addr.$mac_suffix"
  run_machine $name 4 $mem $mac_suffix $ip
  echo "INFO: start machine $name waiting $name $(date)"
  wait_kvm_machine $image_user@$ip
  echo "INFO: adding machine $name to juju controller $(date)"
  juju-add-machine ssh:$image_user@$ip
  mch=`get_machine_by_ip $ip`
  wait_kvm_machine $mch juju-ssh
  # apply hostname
  juju-ssh $mch "sudo bash -c 'echo $name > /etc/hostname ; hostname $name'" 2>/dev/null
  # after first boot we must remove cloud-init
  juju-ssh $mch "sudo rm -rf /etc/systemd/system/cloud-init.target.wants /lib/systemd/system/cloud*"
  echo "INFO: machine $name (machine: $mch) is ready $(date)"
}

function run_general_machine() {
  local prefix=$1
  local index=$2
  local mac_var_name="os_${prefix}_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating ${prefix} $index (mac suffix $mac_suffix) $(date)"
  local ip="$network_addr.$mac_suffix"
  run_cloud_machine ${prefix}-$index $mac_suffix 4096 $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing ${prefix} $index $(date)"
  juju-ssh $mch "sudo apt-get -fy install mc wget openvswitch-switch" &>>$log_dir/apt.log
  juju-scp "$my_dir/files/50-cloud-init-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
  juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  juju-ssh $mch "echo 'supersede routers $network_addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $mch juju-ssh
}

function run_controller() {
  local index=$1
  local mem=$2
  local prepare_for_openstack=$3
  local mac_var_name="os_cont_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating controller $index (mac suffix $mac_suffix) $(date)"
  local ip="$network_addr.$mac_suffix"
  run_cloud_machine cont-$index $mac_suffix $mem $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing controller $index $(date)"
  juju-ssh $mch "sudo apt-get -fy install mc wget bridge-utils" &>>$log_dir/apt.log
  if [[ "$prepare_for_openstack" == '1' ]]; then
    juju-ssh $mch "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $mch "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m' /etc/default/lxd-bridge" 2>/dev/null
  fi
  juju-scp "$my_dir/files/50-cloud-init-controller-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
  juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  juju-ssh $mch "echo 'supersede routers $network_addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $mch juju-ssh
}

run_controller 0 8192 1

run_general_machine comp 1
run_general_machine comp 2

run_general_machine net 1
run_general_machine net 2
run_general_machine net 3

run_general_machine bgp 1

wait_for_all_machines

echo "INFO: Environment created $(date)"

virsh net-dhcp-leases $network_name

trap - ERR EXIT
