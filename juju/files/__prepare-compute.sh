#!/bin/bash -ex

main_net_prefix=$1

function do_xenial() {
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# This file is generated from information provided by
# the datasource.  Changes to it will not persist across an instance.
# To disable cloud-init's network configuration capabilities, write a file
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:
# network: {config: disabled}
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet dhcp

auto dummy0
iface dummy0 inet manual
    hwaddress random
    pre-up modprobe dummy
    pre-up sleep 2
    pre-up ip link add \${IFACE} type dummy
    up ip link set up dev \${IFACE}
    down ip link set down dev \${IFACE}
    post-down ip link del \${IFACE}
EOF
}

function do_bionic() {
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

# this should be done for first interface!
echo "supersede routers $main_net_prefix.1;" >> /etc/dhcp/dhclient.conf
