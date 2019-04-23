#!/bin/bash -e

# main deployment script - it orchestrates deployment process
export WORKSPACE="${WORKSPACE:-$HOME}"

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

# check if environment is present
if virsh list --all | grep -q "${job_prefix}-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "${job_prefix}-"
  exit 1
fi

# check input params
if [[ $SERIES == 'bionic' && $VERSION == 'queens' ]]; then
  export OPENSTACK_ORIGIN='distro'
elif [[ $SERIES == 'bionic' && $VERSION != 'rocky' ]]; then
  echo "ERROR: bionic supports only queens and further versions"
  exit 1
elif [[ $VERSION == 'rocky' && $SERIES == 'xenial' ]]; then
  echo "ERROR: rocky is not available for xenial"
  exit 1
else
  export OPENSTACK_ORIGIN="cloud:$SERIES-$VERSION"
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

# deploy services and post configures
"$my_dir"/deploy_services.sh

# configure openstack
"$my_dir"/configure_openstack.sh

# check openstack
"$my_dir"/check_openstack.sh

# save logs
$my_dir/save-logs.sh

trap - ERR EXIT

if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  echo "INFO: cleaning environment $(date)"
  "$my_dir"/clean_env.sh
fi
