#!/bin/bash -e

neutron_bgp_speaker_ip=$1
local_ip=$(hostname -i)
iface=$(route | awk '/default/{print $NF}'|head -1)

apt-get install -y bird
systemctl stop bird
rm -rf /var/log/bird.log
touch /var/log/bird.log
chmod a+rw /var/log/bird.log

cat <<EOF > /etc/bird/bird.conf
log "/var/log/bird.log" all;
log syslog all;
define myas = 65432;
router id $local_ip;

protocol direct jovs {
  interface "$iface";
}

protocol device {
}

protocol kernel {
  #metric 64;
  import none;
  export all;
}

protocol bgp neutron {
  neighbor $neutron_bgp_speaker_ip as 65433;
  debug {events, routes};
  local $local_ip as myas;
  #source address $local_ip;
  #multihop;
  #next hop self;
  direct;
  passive;
  gateway recursive;
  bfd;
}
EOF

systemctl start bird
