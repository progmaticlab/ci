# this script is used to download and prepare Ubuntu Xenial image for later use in juju environment with kvm virtualization

# all commands must be run under root account

# ssh key for inject into VM image
SSH_KEY=/root/.ssh/id_rsa.pub

# utils that are used later
apt-get install -y libvirt-clients qemu-utils openssl wget

# download latest Ubuntu Xenial cloud image
wget -nv https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img -O ./ubuntu-xenial.qcow2

# check that ndb driver was loaded
lsmod | grep -q '^nbd ' || modprobe nbd max_part=8
# mount image. please note that you must unmount image later
qemu-nbd -d /dev/nbd1 || true
qemu-nbd -n -c /dev/nbd1 ./ubuntu-xenial.qcow2
sleep 2
tmpdir=$(mktemp -d)
mount /dev/nbd1p1 $tmpdir
sleep 2

# patch image
# cause cloud-init creates various objects we can't disable it at all now so we must patch it a bit
pushd $tmpdir
# disable metadata requests for cloud-init
echo 'datasource_list: [ None ]' > etc/cloud/cloud.cfg.d/90_dpkg.cfg
# enable root account for debug purposes via 'virsh console'
sed -i -e 's/^disable_root.*$/disable_root: false/' etc/cloud/cloud.cfg
# set simple password for root user
# makepasswd --clearfrom=- --crypt-md5 <<< '123'
sed -i -e 's/^root:\*:/root:$1$WFvHO1ym$CUv6A5XtyFXlIfS2ZZlIf0:/' etc/shadow
# store ssh keys for root user to be able to ssh into running VM later
mkdir -p root/.ssh
cp $SSH_KEY root/.ssh/authorized_keys
cp $SSH_KEY root/.ssh/authorized_keys2
popd

# unmount image
umount /dev/nbd1p1
sleep 2
rm -rf $tmpdir
qemu-nbd -d /dev/nbd1
sleep 2

# resize image's FS
truncate -s 40G temp.raw
virt-resize --expand /dev/vda1 ubuntu-xenial.qcow2 temp.raw
qemu-img convert -O qcow2 temp.raw ubuntu-xenial.qcow2
rm temp.raw

# move image to standard libvirt's location
mv ubuntu-xenial.qcow2 /var/lib/libvirt/images/
