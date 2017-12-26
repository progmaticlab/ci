#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source $my_dir/common/functions

echo "--------------------------------------------------- Save LOGS ---"

log_dir=$WORKSPACE/logs

# save status to file
juju-status > $log_dir/juju_status.log
juju-status-tabular > $log_dir/juju_status_tabular.log

truncate -s 0 $log_dir/juju_unit_statuses.log
for unit in `timeout -s 9 30 juju status $juju_model_arg --format oneline | awk '{print $2}' | sed 's/://g'` ; do
  if [[ -z "$unit" || "$unit" =~ "ubuntu/" || "$unit" =~ "ntp/" ]] ; then
    continue
  fi
  echo "--------------------------------- $unit statuses log" >> $log_dir/juju_unit_statuses.log
  juju show-status-log $juju_model_arg --days 1 $unit >> $log_dir/juju_unit_statuses.log
done

slf=$(mktemp)
cat <<EOS >$slf
rm -f logs.*
tar -cf logs.tar /var/log/juju 2>/dev/null
for ldir in '/etc/apache2' '/etc/apt' '/etc/neutron' '/etc/nova' '/etc/haproxy' '/var/log/upstart' '/var/log/neutron' '/var/log/nova' '/etc/keystone' '/var/log/keystone' ; do
  if [ -d "$ldir" ] ; then
    tar -rf logs.tar "$ldir" 2>/dev/null
  fi
done
ps ax -H &> ps.log
netstat -lpn &> netstat.log
free -h &> mem.log
tar -rf logs.tar ps.log netstat.log mem.log 2>/dev/null
gzip logs.tar
EOS

for mch in $(juju-machines-tabular | awk '/started/{print $1}') ; do
  mkdir -p "$log_dir/$mch"
  juju-ssh $mch "df -hT" &>"$log_dir/$mch/df.log"
  juju-scp "$slf" $mch:save_logs.sh 2>/dev/null
  juju-ssh $mch "sudo bash ./save_logs.sh" 2>/dev/null
  rm -f logs.tar.gz
  juju-scp $mch:logs.tar.gz logs.tar.gz 2>/dev/null
  cdir=`pwd`
  pushd "$log_dir/$mch"
  tar -xf "$cdir/logs.tar.gz"
  for drr in upstart keystone ; do
    for fff in `find ./var/log/$drr -name "*.log"` ; do
      echo "Gzip $fff"
      gzip "$fff"
    done
  done
  popd
  rm -f logs.tar.gz
done
