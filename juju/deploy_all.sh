#!/bin/bash -e

# main deployment script - it orchestrates deployment process

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

# script can clean previous environment if needed
if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  "$my_dir"/clean_env.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

# set up log directory
export log_dir="$WORKSPACE/logs"
if [ -d $log_dir ] ; then
  chmod -R u+w "$log_dir"
  rm -rf "$log_dir"
fi
mkdir "$log_dir"

# next step tested only with xenial/ocata
export OPENSTACK_ORIGIN="cloud:xenial-ocata"
# common password for all services
export PASSWORD=${PASSWORD:-'password'}
# interfaces for ubuntu. it's used for provision neutron's public network. treated as host network interface 
export IF1='ens3'

# check if environment is present
if virsh list --all | grep -q "${job_prefix}-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "${job_prefix}-"
  exit 1
fi

# set up trap to clean up environment
trap 'catch_errors $LINENO' ERR EXIT
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT

  juju-status-tabular || /bin/true
  $my_dir/save-logs.sh

  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    echo "INFO: cleaning environment $(date)"
    "$my_dir"/clean_env.sh
  fi

  exit $exit_code
}

# start deployment...
echo "INFO: Date: $(date)"
echo "INFO: Starting deployment process with vars:"
env|sort

# create kvm machines for deployment
echo "INFO: creating environment $(date)"
"$my_dir"/create_env.sh
juju-status-tabular

# deploy services and post configures
"$my_dir"/deploy_services.sh

# configure openstack
"$my_dir"/configure_openstack.sh

# save logs
$my_dir/save-logs.sh

trap - ERR EXIT

if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  echo "INFO: cleaning environment $(date)"
  "$my_dir"/clean_env.sh
fi
