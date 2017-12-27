#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

comp1_ip="$network_addr.$os_comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip="$network_addr.$os_comp_2_idx"
comp2=`get_machine_by_ip $comp2_ip`
echo "INFO: compute 2: $comp2 / $comp2_ip"

cont0_ip="$network_addr.$os_cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller 0 (OpenStack): $cont0 / $cont0_ip"

net1_ip="$network_addr.$os_net_1_idx"
net1=`get_machine_by_ip $net1_ip`
echo "INFO: network 1: $net1 / $net1_ip"
net2_ip="$network_addr.$os_net_2_idx"
net2=`get_machine_by_ip $net2_ip`
echo "INFO: network 1: $net2 / $net2_ip"
net3_ip="$network_addr.$os_net_3_idx"
net3=`get_machine_by_ip $net3_ip`
echo "INFO: network 1: $net3 / $net3_ip"

bgp1_ip="$network_addr.$os_bgp_1_idx"
bgp1=`get_machine_by_ip $bgp1_ip`
echo "INFO: bgp 1: $bgp1 / $bgp1_ip"

# OpenStack base

echo "INFO: Deploy all $(date)"
juju-deploy cs:xenial/ntp

juju-deploy cs:xenial/rabbitmq-server --to lxd:$cont0
juju-deploy cs:xenial/percona-cluster mysql --to lxd:$cont0
juju-set mysql "root-password=$PASSWORD" "max-connections=1500"

juju-deploy cs:xenial/openstack-dashboard --to lxd:$cont0
juju-set openstack-dashboard "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose openstack-dashboard

juju-deploy cs:xenial/nova-cloud-controller --to lxd:$cont0
juju-set nova-cloud-controller "console-access-protocol=novnc" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:xenial/glance --to lxd:$cont0
juju-set glance "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

juju-deploy cs:xenial/keystone --to lxd:$cont0
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose keystone

juju-deploy cs:xenial/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=kvm" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

juju-deploy cs:xenial/neutron-api --to lxd:$cont0
juju-set neutron-api "openstack-origin=$OPENSTACK_ORIGIN" "enable-dvr=true" "overlay-network-type=vxlan" "enable-l3ha=True" "neutron-security-groups=True" "flat-network-providers=*" "max-l3-agents-per-router=3"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

juju-deploy neutron-openvswitch
juju-set neutron-openvswitch "bridge-mappings=external:$brex_iface" "data-port=$brex_iface:$brex_port"

juju-deploy neutron-gateway --to $net1
juju-set neutron-gateway "openstack-origin=$OPENSTACK_ORIGIN" "ha-bindiface=$IF1" "bridge-mappings=external:$brex_iface" "data-port=$brex_iface:$brex_port"
juju-add-unit neutron-gateway --to $net2
juju-add-unit neutron-gateway --to $net3

juju-deploy --series=xenial $my_dir/neutron-bgp

echo "INFO: Add relations $(date)"
juju-add-relation "nova-compute:shared-db" "mysql:shared-db"
juju-add-relation "keystone:shared-db" "mysql:shared-db"
juju-add-relation "glance:shared-db" "mysql:shared-db"
juju-add-relation "keystone:identity-service" "glance:identity-service"
juju-add-relation "nova-cloud-controller:image-service" "glance:image-service"
juju-add-relation "nova-cloud-controller:identity-service" "keystone:identity-service"
juju-add-relation "nova-cloud-controller:cloud-compute" "nova-compute:cloud-compute"
juju-add-relation "nova-compute:image-service" "glance:image-service"
juju-add-relation "nova-compute:amqp" "rabbitmq-server:amqp"
juju-add-relation "nova-cloud-controller:shared-db" "mysql:shared-db"
juju-add-relation "nova-cloud-controller:amqp" "rabbitmq-server:amqp"
juju-add-relation "openstack-dashboard" "keystone"

juju-add-relation "neutron-api:shared-db" "mysql:shared-db"
juju-add-relation "neutron-api:neutron-api" "nova-cloud-controller:neutron-api"
juju-add-relation "neutron-api:identity-service" "keystone:identity-service"
juju-add-relation "neutron-api:amqp" "rabbitmq-server:amqp"

juju-add-relation "neutron-api" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"
juju-add-relation "neutron-gateway" "ntp"

juju-add-relation "neutron-gateway:amqp" "rabbitmq-server:amqp"
juju-add-relation "neutron-gateway" "nova-cloud-controller"
juju-add-relation "neutron-gateway" "neutron-api"
juju-add-relation "neutron-api" "neutron-bgp"

juju-add-relation "neutron-openvswitch" "nova-compute"
juju-add-relation "neutron-openvswitch" "neutron-api"
juju-add-relation "neutron-openvswitch" "rabbitmq-server"

post_deploy

juju-scp $my_dir/__deploy_bgp_peer.sh $bgp1:deploy_bgp_peer.sh
juju-ssh $bgp1 sudo ./deploy_bgp_peer.sh $(get_machine_ip neutron-api)

# TODO: these settings are not permanent. it must be applied after reboot.
configure_l3_routing $comp1
configure_l3_routing $comp2
configure_l3_routing $net1
configure_l3_routing $net2
configure_l3_routing $net3

configure_bgp_neutron_api
# it needs connect to mysql that doesn't have now
#configure_bgp_agent $net1 $net1_ip
#configure_bgp_agent $net2 $net2_ip
#configure_bgp_agent $net3 $net3_ip

# add advertisiment ip for nodes
create_adv_ip comp-1 $comp1_ip
create_adv_ip comp-2 $comp2_ip
create_adv_ip net-1 $net1_ip
create_adv_ip net-2 $net2_ip
create_adv_ip net-3 $net3_ip

trap - ERR EXIT
