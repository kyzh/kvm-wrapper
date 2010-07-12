#!/bin/sh
# Bootstrap VM
#
# -- bencoh, 2010/07/11
#

### Configuration
REPOSITORY="http://ftp.fr.debian.org/debian/"
FLAVOR="lenny"
LINUX_IMAGE="linux-image-2.6-686"
EXTRA_PKGS="vim-nox,htop,screen,less,bzip2,bash-completion,locate,$LINUX_IMAGE"
### 

function bootstrap_fs()
{
	MNTDIR="`mktemp -d`"
	DISKDEV=$1

	mkfs.ext3 "$DISKDEV"
	
	#mkdir "$MNTDIR"
	mount "$DISKDEV" "$MNTDIR"
	
	# Now debootstrap, first stage (do not configure)
	debootstrap --foreign --include="$EXTRA_PKGS" "$FLAVOR" "$MNTDIR" "$REPOSITORY"
	
	# init script to be run on first VM boot
	BS_FILE="$MNTDIR/bootstrap-init.sh"
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
	#rmdir "$MNTDIR"
	
	# DEBUG
	#exit
	
	# Start VM to debootstrap, second stage
	desc_update_setting "KVM_NETWORK_MODEL" "virtio"
	desc_update_setting "KVM_KERNEL" "/home/bencoh/kvm-hdd/boot/vmlinuz-2.6.26-2-686"
	desc_update_setting "KVM_INITRD" "/home/bencoh/kvm-hdd/boot/initrd.img-2.6.26-2-686"
	desc_update_setting "KVM_APPEND" "root=/dev/hda ro init=/bootstrap-init.sh"
	kvm_start_vm "$VM_NAME"
	
	#mkdir "$MNTDIR"
	mount "$DISKDEV" "$MNTDIR"
	
	# Copy some files/configuration from host
	bs_copy_from_host /etc/hosts
	bs_copy_from_host /etc/resolv.conf
	bs_copy_from_host /etc/bash.bashrc
	bs_copy_from_host /etc/profile
	bs_copy_from_host /root/.bashrc
	bs_copy_from_host /etc/vim/vimrc
	bs_copy_from_host /etc/screenrc
	bs_copy_from_host /etc/apt/sources.list
	echo "$VM_NAME" > "$MNTDIR/etc/hostname"
	
	# fstab
	cat > "$MNTDIR/etc/fstab" << EOF
/dev/hda	/		ext3	errors=remount-ro	0	1
proc		/proc	proc	defaults			0	0
sysfs		/sys	sysfs	defaults			0	0
EOF

	# interfaces
	IF_FILE="$MNTDIR/etc/network/interfaces"
	cat > "$IF_FILE" << EOF
auto lo
iface lo inet loopback

auto eth0
EOF
	if [[ -n "$BOOTSTRAP_NET_ADDR" ]]; then
		cat >> "$IF_FILE" << EOF	
iface eth0 inet static
	address XXXADDRXXX
	netmask XXXNETMASKXXX
	network XXXNETWORKXXX
	gateway XXXGATEWAYXXX
EOF
	
		sed -i "s/XXXADDRXXX/$BOOTSTRAP_NET_ADDR/g" "$IF_FILE"
		sed -i "s/XXXNETMASKXXX/$BOOTSTRAP_NET_MASK/g" "$IF_FILE"
		sed -i "s/XXXGATEWAYXXX/$BOOTSTRAP_NET_GW/g" "$IF_FILE"
		sed -i "s/XXXNETWORKXXX/$BOOTSTRAP_NET_NW/g" "$IF_FILE"
	else
		cat >> "$IF_FILE" << EOF
iface eth0 inet dhcp
EOF
	fi
	unset IF_FILE
	
	sync
	umount "$MNTDIR"
	rmdir "$MNTDIR"
	unset MNTDIR DISKDEV

	desc_update_setting "KVM_APPEND" "root=/dev/hda ro"
}

