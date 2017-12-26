#!/bin/bash

SSH_KEY=/home/jenkins/.ssh/id_rsa.pub
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"ubuntu-xenial.qcow2"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"
# makepasswd --clearfrom=- --crypt-md5 <<< '123'
# $1$WFvHO1ym$CUv6A5XtyFXlIfS2ZZlIf0

apt-get install -y libvirt-clients qemu-utils openssl

cdir=$(mktemp -d)
rm -rf $cdir
mkdir -p $cdir
cd $cdir

wget -nv https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img -O ./$BASE_IMAGE_NAME

if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi
nbd_dev="/dev/nbd1"
qemu-nbd -d $nbd_dev || true
qemu-nbd -n -c $nbd_dev ./$BASE_IMAGE_NAME
sleep 5
ret=0
tmpdir=$(mktemp -d)
mount ${nbd_dev}p1 $tmpdir || ret=1
sleep 2
pushd $tmpdir
sed -i -e 's/^disable_root.*$/disable_root: false/' etc/cloud/cloud.cfg
echo 'datasource_list: [ None ]' > etc/cloud/cloud.cfg.d/90_dpkg.cfg
sed -i -e 's/^root:\*:/root:$1$WFvHO1ym$CUv6A5XtyFXlIfS2ZZlIf0:/' etc/shadow
mkdir -p root/.ssh
cat $SSH_KEY > root/.ssh/authorized_keys
cat $SSH_KEY > root/.ssh/authorized_keys2
popd

umount ${nbd_dev}p1 || ret=2
sleep 2
rm -rf $tmpdir || ret=3
qemu-nbd -d $nbd_dev || ret=4
sleep 2

truncate -s 60G temp.raw
virt-resize --expand /dev/vda1 $BASE_IMAGE_NAME temp.raw
qemu-img convert -O qcow2 temp.raw $BASE_IMAGE_NAME
rm temp.raw

cp $BASE_IMAGE_NAME /var/lib/libvirt/images/


#virt-install --name ttt --ram 1024 --vcpus 2 --virt-type kvm --os-type=linux --os-variant ubuntu16.04 --disk path=/var/lib/libvirt/images/ubuntu-xenial-new.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) --noautoconsole --network network=default --boot hd
