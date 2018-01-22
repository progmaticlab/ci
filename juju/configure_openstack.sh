#!/bin/bash -e

export WORKSPACE="${WORKSPACE:-$HOME}"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

# prepare environment for common openstack functions
cd $WORKSPACE
create_stackrc
source $WORKSPACE/stackrc

rm -rf .venv
virtualenv .venv
source .venv/bin/activate
pip install python-openstackclient python-neutronclient

openstack catalog list

openstack project create --domain default demo
openstack user create --project demo --domain default --password ${PASSWORD:-password} demo
openstack role add --project demo --user demo --user-domain default --project-domain default Member

sleep 30

openstack address scope create --share --ip-version 4 bgp
openstack subnet pool create --pool-prefix $public_network_addr.0/24 --address-scope bgp public
openstack subnet pool create --pool-prefix 192.168.1.0/24 --pool-prefix 192.168.2.0/24 --address-scope bgp --share private

openstack network create --share --external --provider-network-type flat --provider-physical-network external public
openstack subnet create --network public --subnet-range $public_network_addr.0/24 --no-dhcp --gateway $public_network_addr.1 public

openstack flavor create --ram 256 --vcpus 1 --public small

rm cirros-0.3.5-x86_64-disk.img
wget -nv http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img
openstack image create --public --file cirros-0.3.5-x86_64-disk.img cirros

# BGP
openstack bgp speaker create --local-as 65433 --no-advertise-tenant-networks bgpspeaker
openstack bgp speaker add network bgpspeaker public
openstack bgp peer create --remote-as 65432 --peer-ip $network_addr.$os_cont_0_idx kvm
openstack bgp speaker add peer bgpspeaker kvm
for iii in `openstack network agent list | grep BGP | awk '{print $2}'` ; do openstack bgp dragent add speaker $iii bgpspeaker ; done

export OS_USERNAME=demo
export OS_PROJECT_NAME=demo
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default

openstack network create private1
openstack subnet create --network private1 --subnet-range 192.168.1.0/24 --gateway 192.168.1.1 private1

openstack network create private2
openstack subnet create --network private2 --subnet-range 192.168.2.0/24 --gateway 192.168.2.1 private2

openstack router create rt
openstack router set --external-gateway public rt
openstack router add subnet rt private1
openstack router add subnet rt private2

openstack security group rule create default --protocol icmp
openstack security group rule create default --protocol tcp --dst-port 22:22

source $WORKSPACE/stackrc

for iii in `openstack network agent list | grep BGP | awk '{print $2}'` ; do openstack network agent show $iii ; done
