#!/bin/bash -ex

main_net_prefix=$1

function do_xenial() {
  IF1=ens3
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# This file is generated from information provided by
# the datasource.  Changes to it will not persist across an instance.
# To disable cloud-init's network configuration capabilities, write a file
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:
# network: {config: disabled}
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet manual

auto br-ens3
iface br-ens3 inet dhcp
    bridge_ports ens3
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF
}

function do_bionic() {
  IF1=ens3
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
  apt-get install ifupdown &>>apt.log
  echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
  do_xenial
  mv /etc/netplan/50-cloud-init.yaml /etc/netplan/__50-cloud-init.yaml.save
}

echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

series=`lsb_release -cs`
do_$series
if [ -f /etc/default/lxd-bridge ]; then
  sed -i -e "s/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m" /etc/default/lxd-bridge
  sed -i -e "s/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m" /etc/default/lxd-bridge
else
  echo "USE_LXD_BRIDGE=\"false\"" > /etc/default/lxd-bridge
  echo "LXD_BRIDGE=\"br-$IF1\"/m" >> /etc/default/lxd-bridge
fi

echo "supersede routers $main_net_prefix.1;" >> /etc/dhcp/dhclient.conf
