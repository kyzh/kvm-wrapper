#!/bin/sh
# Bootstrap VM
#
# -- bencoh, 2010/07/11
# -- asmadeus, 2010/07

### Configuration
BOOTSTRAP_REPOSITORY="http://ftp.fr.debian.org/debian/"
BOOTSTRAP_FLAVOR="lenny"
if [[ "`uname -m`" == "x86_64" ]]; then
	BOOTSTRAP_LINUX_IMAGE="linux-image-amd64"
else
	BOOTSTRAP_LINUX_IMAGE="linux-image-686"
fi
BOOTSTRAP_EXTRA_PKGSS="vim-nox,htop,screen,less,bzip2,bash-completion,locate,acpid,$BOOTSTRAP_LINUX_IMAGE"
BOOTSTRAP_PARTITION_TYPE="msdos"
BOOTSTRAP_CONF_DIR="$BOOTSTRAP_DIR/$BOOTSTRAP_DISTRIB/conf"
### 

function map_disk()
{
	local DISKDEV=$1
	kpartx -a -p- $DISKDEV > /dev/null
	echo /dev/mapper/`kpartx -l -p- $DISKDEV | grep -m 1 -- "-1.*$DISKDEV" | awk '{print $1}'`
}

function unmap_disk()
{
	local DISKDEV=$1
	kpartx -d -p- $DISKDEV
}

function bs_copy_from_host()
{
	local FILE="$1"
	cp -rf "$FILE" "$MNTDIR/$FILE"
}

function bs_copy_conf_dir()
{
   cp -rf "$BOOTSTRAP_CONF_DIR/"* "$MNTDIR/"
}

function bootstrap_fs()
{
	MNTDIR="`mktemp -d`"
	CLEANUP+=("rmdir $MNTDIR")
	local DISKDEV=$1
	local PARTDEV=$1

	local rootdev="/dev/hda"

	if [[ "$BOOTSTRAP_PARTITION_TYPE" == "msdos" ]]; then
		sfdisk -H 255 -S 63 -uS --quiet --Linux "$DISKDEV" <<EOF
63,,L,*
EOF
		PARTDEV=`map_disk $DISKDEV`
		rootdev="/dev/hda1"
		CLEANUP+=("unmap_disk $DISKDEV")
	fi

	mkfs.ext3 "$PARTDEV"
	
	mount "$PARTDEV" "$MNTDIR"
	
	CLEANUP+=("umount $MNTDIR")	
	CLEANUP+=("sync")

	# Now debootstrap, first stage (do not configure)
	debootstrap --foreign --include="$BOOTSTRAP_EXTRA_PKGSS" "$BOOTSTRAP_FLAVOR" "$MNTDIR" "$BOOTSTRAP_REPOSITORY"
	
	# init script to be run on first VM boot
	local BS_FILE="$MNTDIR/bootstrap-init.sh"
	cat > "$BS_FILE" << EOF
#!/bin/sh
mount -no remount,rw /
cat /proc/mounts
/debootstrap/debootstrap --second-stage
mount -nt proc proc /proc
dpkg -i /var/cache/apt/archives/linux-image-2.6*

echo "Bootstrap ended, halting"
exec /sbin/init 0

EOF
	chmod +x "$BS_FILE"
	
	sed -ie "s/linux-image-[^ ]\+//g" "$MNTDIR/debootstrap/base"
	
	# umount
	sync
	umount "$MNTDIR"

	# Start VM to debootstrap, second stage
	desc_update_setting "KVM_NETWORK_MODEL" "virtio"
	desc_update_setting "KVM_KERNEL" "/boot/vmlinuz-SV"
	desc_update_setting "KVM_INITRD" "/boot/initrd.img-SV"
	desc_update_setting "KVM_APPEND" "root=$rootdev ro init=/bootstrap-init.sh"
	kvm_start_vm "$VM_NAME"
	
	mount "$PARTDEV" "$MNTDIR"
	

	# Copy some files/configuration from host
	bs_copy_from_host /etc/hosts
	bs_copy_from_host /etc/resolv.conf
	bs_copy_from_host /etc/timezone
	bs_copy_from_host /etc/localtime

	echo "$VM_NAME" > "$MNTDIR/etc/hostname"
	# Custom files
	bs_copy_conf_dir
	
	# fstab
	cat > "$MNTDIR/etc/fstab" << EOF
# <file system>	<mount point>	<type>	<options>	<dump>	<pass>
$rootdev	/		ext3	errors=remount-ro	0	1
proc		/proc	proc	defaults			0	0
sysfs		/sys	sysfs	defaults			0	0
EOF


	# interfaces
	local IF_FILE="$MNTDIR/etc/network/interfaces"
	cat > "$IF_FILE" << EOF
auto lo
iface lo inet loopback

auto eth0
EOF
	if [[ -n "$BOOTSTRAP_NET_ADDR" ]]; then
		cat >> "$IF_FILE" << EOF	
iface eth0 inet static
	address $BOOTSTRAP_NET_ADDR
	netmask $BOOTSTRAP_NET_MASK
	network $BOOTSTRAP_NET_NW
	gateway $BOOTSTRAP_NET_GW
EOF
	else
		cat >> "$IF_FILE" << EOF
iface eth0 inet dhcp
EOF
	fi
	
	sync

	desc_update_setting "KVM_APPEND" "root=$rootdev ro"
}

