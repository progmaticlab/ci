#!/bin/bash -ex

export WORKSPACE="${WORKSPACE:-$HOME}"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

cd $WORKSPACE
source $WORKSPACE/stackrc
source .venv/bin/activate

ssh_opts='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'
# router id -> for snat and qrouter namespaces
r_id=`openstack router show rt | awk '/ id /{print $4}'`
# public network id -> for fip namespace
n_id=`openstack network show public | awk '/ id /{print $4}'`

export OS_PROJECT_NAME=demo

openstack server create --image cirros --flavor small --network private1 --min 2 --max 2 vmp1
# wait for scheduler places VM-s to hosts
sleep 5
openstack server create --image cirros --flavor small --network private2 --min 2 --max 2 vmp2
# waiting for VM-s are fully up
sleep 60
openstack server list
if openstack server list | grep -q ERROR ; then
  echo "ERROR: VM-s were not up"
  exit 1
fi

declare -A vms
# keys - "${!vms[@]}", values - "${vms[@]}"
vms["vmp1-1"]=`openstack server list -c Name -c Networks | grep vmp1-1 | awk '{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp1-2"]=`openstack server list -c Name -c Networks | grep vmp1-2 | awk '{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp2-1"]=`openstack server list -c Name -c Networks | grep vmp2-1 | awk '{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`
vms["vmp2-2"]=`openstack server list -c Name -c Networks | grep vmp2-2 | awk '{print $4}' | cut -d '=' -f 2 | cut -d ',' -f 1`

export OS_PROJECT_NAME=admin
openstack server list --all-projects --long -c ID -c Name -c Host

function get_compute_by_vm() {
  local vm_name=$1
  local compute=`openstack server list --all-projects --long -c Name -c Host | grep $vm_name | awk '{print $4}'`
  compute_ip=`virsh net-dhcp-leases $network_name | grep $compute | awk '{print $5}' | cut -d '/' -f 1`
  get_machine_by_ip $compute_ip
}

function check_ping_from_vm() {
  local vm_name=$1
  local ping_addr=$2
  compute=`get_compute_by_vm $vm_name`
  juju-ssh $compute sudo ip netns exec qrouter-$r_id sshpass -p 'cubswin:\)' ssh $ssh_opts cirros@${vms["$vm_name"]} ping -c 3 $ping_addr
}

# check east-west traffic by pinging from one vm to all other vm-s
check_ping_from_vm "vmp1-1" ${vms["vmp1-2"]}
check_ping_from_vm "vmp1-1" ${vms["vmp2-1"]}
check_ping_from_vm "vmp1-1" ${vms["vmp2-2"]}

# check north-south traffic by pinging external router (external world) from vm-s without floating ip
check_ping_from_vm "vmp1-1" $network_address.$os_bgp_1_idx
check_ping_from_vm "vmp1-2" $network_address.$os_bgp_1_idx
check_ping_from_vm "vmp2-1" $network_address.$os_bgp_1_idx
check_ping_from_vm "vmp2-2" $network_address.$os_bgp_1_idx

