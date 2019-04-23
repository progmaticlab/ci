#!/bin/bash -e

export WORKSPACE="${WORKSPACE:-$HOME}"
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

pushd $WORKSPACE
# clone own neutron-gateway charm due to inconsistent plugin list in it
#rm -rf charm-neutron-gateway
#git clone https://github.com/progmaticlab/charm-neutron-gateway.git
# clone own keystone charm due to updated policies for *_credential methods
#rm -rf charm-keystone
#git clone https://github.com/progmaticlab/charm-keystone.git
popd

cont0_ip="$network_addr.$os_cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller 0 (OpenStack): $cont0 / $cont0_ip"

comp1_ip="$network_addr.$os_comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip="$network_addr.$os_comp_2_idx"
comp2=`get_machine_by_ip $comp2_ip`
echo "INFO: compute 2: $comp2 / $comp2_ip"

net1_ip="$network_addr.$os_net_1_idx"
net1=`get_machine_by_ip $net1_ip`
echo "INFO: network 1: $net1 / $net1_ip"
net2_ip="$network_addr.$os_net_2_idx"
net2=`get_machine_by_ip $net2_ip`
echo "INFO: network 1: $net2 / $net2_ip"
net3_ip="$network_addr.$os_net_3_idx"
net3=`get_machine_by_ip $net3_ip`
echo "INFO: network 1: $net3 / $net3_ip"

# OpenStack base
juju-scp $HOME/files/s3.py $cont0:s3.py

echo "INFO: Deploy all $(date)"
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to lxd:$cont0
juju-deploy cs:$SERIES/percona-cluster mysql --to lxd:$cont0
juju-set mysql "root-password=${PASSWORD:-password}" "max-connections=1500"

if [[ "$SERIES" == 'xenial' ]]; then
  juju-deploy cs:$SERIES/openstack-dashboard --to lxd:$cont0
  juju-set openstack-dashboard "openstack-origin=$OPENSTACK_ORIGIN" "cinder-backup=True"
  juju-expose openstack-dashboard
fi

juju-deploy cs:$SERIES/nova-cloud-controller --to lxd:$cont0
juju-set nova-cloud-controller "console-access-protocol=novnc" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to lxd:$cont0
juju-set glance "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

cat >cinder.cfg <<END
cinder:
  block-device: "vdb"
  overwrite: "true"
END
juju-deploy cs:$SERIES/cinder --config=cinder.cfg --to $cont0
juju-set cinder "openstack-origin=$OPENSTACK_ORIGIN" "glance-api-version=2"
juju-expose cinder
juju-deploy --series=$SERIES $my_dir/cinder-backup-s3
juju-set cinder-backup-s3 "s3-url=http://ib.bizmrg.com"

#juju-deploy --series=$SERIES $WORKSPACE/charm-keystone --to lxd:$cont0
juju-deploy cs:$SERIES/keystone --to lxd:$cont0
juju-set keystone "admin-password=${PASSWORD:-password}" "admin-role=admin" "openstack-origin=$OPENSTACK_ORIGIN" "preferred-api-version=3"
juju-expose keystone

juju-deploy cs:$SERIES/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=kvm" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

juju-deploy cs:$SERIES/neutron-api --to lxd:$cont0
juju-set neutron-api "openstack-origin=$OPENSTACK_ORIGIN" "enable-dvr=true" "overlay-network-type=vxlan" "enable-l3ha=True" "neutron-security-groups=True" "flat-network-providers=*" "max-l3-agents-per-router=3"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

juju-deploy cs:$SERIES/neutron-openvswitch
juju-set neutron-openvswitch "bridge-mappings=external:$brex_iface" "data-port=$brex_iface:$brex_port"

#juju-deploy --series=$SERIES $WORKSPACE/charm-neutron-gateway --to $net1
juju-deploy cs:$SERIES/charm-neutron-gateway --to $net1
juju-set neutron-gateway "openstack-origin=$OPENSTACK_ORIGIN" "bridge-mappings=external:$brex_iface" "data-port=$brex_iface:$brex_port"
juju-add-unit neutron-gateway --to $net2
juju-add-unit neutron-gateway --to $net3

juju-deploy --series=$SERIES $my_dir/neutron-bgp

# wait for lxd containers
wait_for_all_machines_lite
# re-write resolv.conf for bionic lxd containers to allow names resolving inside lxd containers
if [[ "$SERIES" == 'bionic' ]]; then
  for mmch in `juju machines | awk '/lxd/{print $1}'` ; do
    echo "INFO: apply DNS config for $mmch"
    res=1
    for i in 0 1 2 3 4 5 ; do
      if juju-ssh $mmch "echo 'nameserver $network_addr.1' | sudo tee /usr/lib/systemd/resolv.conf ; sudo ln -sf /usr/lib/systemd/resolv.conf /etc/resolv.conf" ; then
        res=0
        break
      fi
      sleep 10
    done
    test $res -eq 0 || { echo "ERROR: Machine $mmch is not accessible"; exit 1; }
  done
fi

echo "INFO: Add relations $(date)"
juju-add-relation "keystone:shared-db" "mysql:shared-db"
juju-add-relation "glance:shared-db" "mysql:shared-db"
juju-add-relation "cinder:shared-db" "mysql:shared-db"
juju-add-relation "keystone:identity-service" "glance:identity-service"
juju-add-relation "nova-cloud-controller:image-service" "glance:image-service"
juju-add-relation "nova-cloud-controller:identity-service" "keystone:identity-service"
juju-add-relation "nova-cloud-controller:cloud-compute" "nova-compute:cloud-compute"
juju-add-relation "nova-compute:image-service" "glance:image-service"
juju-add-relation "nova-compute:amqp" "rabbitmq-server:amqp"
juju-add-relation "nova-cloud-controller:shared-db" "mysql:shared-db"
juju-add-relation "nova-cloud-controller:amqp" "rabbitmq-server:amqp"
juju-add-relation "nova-cloud-controller" "cinder"
if [[ "$SERIES" == 'xenial' ]]; then
  juju-add-relation "openstack-dashboard:identity-service" "keystone:identity-service"
fi
juju-add-relation "cinder:identity-service" "keystone:identity-service"
juju-add-relation "cinder:amqp" "rabbitmq-server:amqp"
juju-add-relation "cinder:image-service" "glance:image-service"
juju-add-relation "cinder" "cinder-backup-s3"

juju-add-relation "neutron-api:shared-db" "mysql:shared-db"
juju-add-relation "neutron-api:neutron-api" "nova-cloud-controller:neutron-api"
juju-add-relation "neutron-api:identity-service" "keystone:identity-service"
juju-add-relation "neutron-api:amqp" "rabbitmq-server:amqp"

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

if [[ "$SERIES" == 'xenial' ]]; then
  juju-scp $HOME/files/forms.py openstack-dashboard/0:forms.py
  juju-ssh openstack-dashboard/0 sudo cp -f ./forms.py /usr/share/openstack-dashboard/openstack_dashboard/dashboards/project/volumes/backups/
  juju-ssh openstack-dashboard/0 sudo systemctl restart apache2.service
fi

# looks like that charms do not restart neutron services after config files were written
restart_neutron $comp1
restart_neutron $comp2
restart_neutron $net1
restart_neutron $net2
restart_neutron $net3

juju-scp $my_dir/__deploy_bgp_peer.sh $cont0:deploy_bgp_peer.sh
juju-ssh $cont0 sudo ./deploy_bgp_peer.sh $(get_machine_ip neutron-api)

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
create_adv_ip ${job_prefix}-comp-1 $comp1_ip
create_adv_ip ${job_prefix}-comp-2 $comp2_ip
create_adv_ip ${job_prefix}-net-1 $net1_ip
create_adv_ip ${job_prefix}-net-2 $net2_ip
create_adv_ip ${job_prefix}-net-3 $net3_ip

trap - ERR EXIT
