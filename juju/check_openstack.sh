#!/bin/bash -e

export WORKSPACE="${WORKSPACE:-$HOME}"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

cd $WORKSPACE
source $WORKSPACE/stackrc
source .venv/bin/activate

# just run 4 machines
export OS_PROJECT_NAME=demo
need_wait=0
if ! openstack server list | grep -q " vmp1-" ; then
  openstack server create --image cirros --flavor small --network private1 --min 2 --max 2 vmp1
  # wait for scheduler places VM-s to hosts
  sleep 5
  need_wait=1
fi
if ! openstack server list | grep -q " vmp2-" ; then
  openstack server create --image cirros --flavor small --network private2 --min 2 --max 2 vmp2
  # waiting for VM-s are fully up
  sleep 5
  need_wait=1
fi
[ $need_wait = 1 ] && sleep 60
openstack server list
if openstack server list | grep -q ERROR ; then
  echo "ERROR: VM-s were not up"
  exit 1
fi
export OS_PROJECT_NAME=admin

# and test ...
net1=`get_machine_by_ip $network_addr.$os_net_1_idx`
net2=`get_machine_by_ip $network_addr.$os_net_2_idx`
net3=`get_machine_by_ip $network_addr.$os_net_3_idx`
bgp1=`get_machine_by_ip $network_addr.$os_bgp_1_idx`

ssh_opts='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'
# router id -> for snat and qrouter namespaces
r_id=`openstack router show rt | awk '/ id /{print $4}'`
echo "INFO: snat/qrouter namespace id: $r_id"
# public network id -> for fip namespace
n_id=`openstack network show public | awk '/ id /{print $4}'`
echo "INFO: fip namespace id: $n_id"

master_snat=''
function detect_master_snat() {
  # non local variables - they are used in code
  master_snat=''
  master_snat_ip=''
  master_snat_name=''
  master_snat_guid=''
  echo "INFO: try to find where is master node for SNAT namespace   $(date)"
  for ((i=0; i<60; i++)); do
    for mch in $net1 $net2 $net3 ; do
      if juju-ssh $mch "grep -q master /var/lib/neutron/ha_confs/$r_id/state 2>/dev/null" 2>/dev/null ; then
        master_snat=$mch
        master_snat_ip=`get_machine_ip_by_machine $mch`
        master_snat_name=`virsh net-dhcp-leases $network_name | grep $master_snat_ip | awk '{print $6}'`
        master_snat_guid=`openstack network agent list --agent-type l3 | grep " $master_snat_name " | awk '{print $2}'`
        echo "INFO: master SNAT namespace has been found on machine $mch; ip $master_snat_ip; name $master_snat_name; guid $master_snat_guid   $(date)"
        return
      fi
    done
    echo "WARNING: There is no master SNAT namespace on network nodes...   $(date)"
    sleep 10
  done
}

# try to find where is master SNAT now...
detect_master_snat

echo "INFO: waiting for bgp announcement on router host   $(date)"
for ((i=0; i<180; i++)); do
  if juju-ssh $bgp1 tail -3 /var/log/bird.log 2>/dev/null | grep "neutron > added .* $master_snat_ip" ; then
    echo "INFO: bgp announcement was found   $(date)"
    break
  fi
  echo "WARNING: There is no announcement $i/180   $(date)"
  sleep 10
done

declare -A vms
# keys - "${!vms[@]}", values - "${vms[@]}"
vms["vmp1-1"]=`openstack server list --all-projects -c Name -c Networks | awk '/vmp1-1/{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp1-2"]=`openstack server list --all-projects -c Name -c Networks | awk '/vmp1-2/{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp2-1"]=`openstack server list --all-projects -c Name -c Networks | awk '/vmp2-1/{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp2-2"]=`openstack server list --all-projects -c Name -c Networks | awk '/vmp2-2/{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`

openstack server list --all-projects --long -c ID -c Name -c Host -c Networks

function get_compute_by_vm() {
  local vm_name=$1
  local compute=`openstack server list --all-projects --long -c Name -c Host | grep $vm_name | awk '{print $4}'`
  local compute_ip=`virsh net-dhcp-leases $network_name | grep $compute | awk '{print $5}' | cut -d '/' -f 1`
  get_machine_by_ip $compute_ip
}

function _ping() {
  juju-ssh $1 sudo ip netns exec qrouter-$r_id sshpass -p 'cubswin:\)' ssh $ssh_opts cirros@$2 ping -c $3 $4
}

function check_ping_from_vm() {
  local vm_name=$1
  local ping_addr=$2
  echo "INFO: check ping from $vm_name to $ping_addr"
  local compute=`get_compute_by_vm $vm_name`
  _ping $compute ${vms["$vm_name"]} 3 $ping_addr
}

# check east-west traffic by pinging from one vm to all other vm-s
check_ping_from_vm "vmp1-1" ${vms["vmp1-2"]}
check_ping_from_vm "vmp1-1" ${vms["vmp2-1"]}
check_ping_from_vm "vmp1-1" ${vms["vmp2-2"]}

# check north-south traffic by pinging external router (external world) from vm-s without floating ip
check_ping_from_vm "vmp1-1" $network_addr.$os_bgp_1_idx
check_ping_from_vm "vmp1-2" $network_addr.$os_bgp_1_idx
check_ping_from_vm "vmp2-1" $network_addr.$os_bgp_1_idx
check_ping_from_vm "vmp2-2" $network_addr.$os_bgp_1_idx

# check master SNAT namespace moving... do it for one any vm
echo "INFO: disable master SNAT and check moving to another network node   $(date)"
old_master_snat=$master_snat
old_master_snat_guid=$master_snat_guid
openstack network agent set --disable $master_snat_guid
vm_name="vmp1-1"
compute=`get_compute_by_vm $vm_name`
while _ping $compute ${vms["$vm_name"]} 1 $network_addr.$os_bgp_1_idx &>/dev/null ; do
  echo "INFO: ping to external world still work   $(date)"
  sleep 1
done
while ! _ping $compute ${vms["$vm_name"]} 1 $network_addr.$os_bgp_1_idx &>/dev/null ; do
  echo "INFO: ping to external world still doensn't work   $(date)"
  sleep 1
done
detect_master_snat
echo "INFO: master SNAT has been moved from machine $old_master_snat   $(date)"
openstack network agent set --enable $old_master_snat_guid
