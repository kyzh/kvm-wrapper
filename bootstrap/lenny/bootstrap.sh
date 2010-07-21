#!/bin/bash
# Bootstrap VM
#
# -- bencoh, 2010/07/11
# -- asmadeus, 2010/07

if [[ "`uname -m`" == "x86_64" ]]; then
	ARCH_SUFFIX="amd64"
else
	ARCH_SUFFIX="686"
fi

### Configuration
BOOTSTRAP_LINUX_IMAGE="linux-image-$ARCH_SUFFIX"
BOOTSTRAP_REPOSITORY="http://ftp.fr.debian.org/debian/"
BOOTSTRAP_FLAVOR="lenny"
BOOTSTRAP_EXTRA_PKGSS="vim-nox,htop,screen,less,bzip2,bash-completion,locate,acpid,bind9-host,openssh-server,$BOOTSTRAP_LINUX_IMAGE"
if [[ "$BOOTSTRAP_PARTITION_TYPE" == "msdos" ]]; then
	BOOTSTRAP_EXTRA_PKGSS+=",grub"
fi
BOOTSTRAP_CONF_DIR="$BOOTSTRAP_DIR/$BOOTSTRAP_DISTRIB/conf"
BOOTSTRAP_KERNEL="$BOOT_IMAGES_DIR/vmlinuz-$ARCH_SUFFIX"
BOOTSTRAP_INITRD="$BOOT_IMAGES_DIR/initrd.img-$ARCH_SUFFIX"
BOOTSTRAP_CACHE="$CACHE_DIR/$BOOTSTRAP_DISTRIB-debootstrap.tar"
### 

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

	check_create_dir "$LOGDIR"
	local LOGFILE="$LOGDIR/$VM_NAME-boostrap-`date +%Y-%m-%d-%H:%M:%S`"

#    npipe="/tmp/$$-pipe.tmp"
#    CLEANUP+=("rm -f $npipe")
#    mknod $npipe p
#    tee <$npipe "$LOGFILE" &
#    exec 1>&-
#    exec 1>$npipe

# well - this or { ... } |tee -a "$LOGFILE" - but you loose environment there, so this sucks. gotta cut it in about five pieces and it's ugly :P

	test_file "$BOOTSTRAP_KERNEL" || fail_exit "Couldn't find bootstrap kernel : $BOOTSTRAP_KERNEL"
	test_file "$BOOTSTRAP_INITRD" || fail_exit "Couldn't find bootstrap initrd : $BOOTSTRAP_INITRD"

	MNTDIR="`mktemp -d`"
	CLEANUP+=("rmdir $MNTDIR")
	local DISKDEV=$1
	local PARTDEV=$1

	local rootdev="LABEL=rootdev"
	local swapdev
	local swapuuid

	if [[ "$BOOTSTRAP_PARTITION_TYPE" == "msdos" ]]; then
		if [[ -n "$SWAP_SIZE" ]]; then
	   		sfdisk -D -H 255 -S 63 -uM --Linux "$DISKDEV" <<EOF
,$ROOT_SIZE,L,*
,,S
EOF
		else
			sfdisk -D -H 255 -S 63 -uM --Linux "$DISKDEV" <<EOF
,,L,*
EOF
		fi
		PARTDEV=`map_disk $DISKDEV`

		if [[ -n "$SWAP_SIZE" ]]; then
			swapdev="${PARTDEV:0:$((${#PARTDEV}-1))}2"
			swap_uuid=`mkswap $swapdev|grep -o -e 'UUID=.*'`
		fi

		CLEANUP+=("unmap_disk $DISKDEV")
	fi

	mkfs.ext3 -L rootdev "$PARTDEV"
	
	mount "$PARTDEV" "$MNTDIR"
	
	CLEANUP+=("umount $MNTDIR")	
	CLEANUP+=("sync")

	echo
	echo

#	FIXME: should be removed anytime soon
#	# Now debootstrap, first stage (do not configure), or decompress cache for this.
#	# First we check if the cache is too old.
#	if [[ -n "$BOOTSTRAP_CACHE" && -f "$BOOTSTRAP_CACHE" ]]; then
#		find "$BOOTSTRAP_CACHE" -mtime +15 -exec rm {} \;
#	    if [[ ! -f "$BOOTSTRAP_CACHE" ]]; then
#			echo "Debootstrap cache $BOOTSTRAP_CACHE is too old and has been removed."
#			echo "Generating a new one instead"
#		fi
#	fi
#
#	if [[ -f "$BOOTSTRAP_CACHE" ]]; then
#		echo "Decompressing $BOOTSTRAP_CACHE - if you changed anything to debootstrap arguments, please remove this file"
#		echo "It is automatically removed if it is more than two weeks old."
#		cd "$MNTDIR"
#		tar xf "$BOOTSTRAP_CACHE"
#		cd - > /dev/null
#	else
#		debootstrap --foreign --include="$BOOTSTRAP_EXTRA_PKGSS" "$BOOTSTRAP_FLAVOR" "$MNTDIR" "$BOOTSTRAP_REPOSITORY"
#		if [[ -n "$BOOTSTRAP_CACHE" ]]; then
#			echo "Building cache file $BOOTSTRAP_CACHE."
#			cd "$MNTDIR"
#			tar cf "$BOOTSTRAP_CACHE" .
#			cd - > /dev/null
#		fi
#	fi
#

	# Debootstrap cache
	local DEBOOTSTRAP_CACHE_OPTION=""
	if [[ -n "$BOOTSTRAP_CACHE" ]]; then
		find "$BOOTSTRAP_CACHE" -mtime +15 -exec rm {} \;
		if ! test_file_rw "$BOOTSTRAP_CACHE"; then
			echo "Debootstrap cache either absent or to old : building a new one ..."
			eval debootstrap --arch i386 --make-tarball "$BOOTSTRAP_CACHE" --include="$BOOTSTRAP_EXTRA_PKGSS" "$BOOTSTRAP_FLAVOR" "$MNTDIR" "$BOOTSTRAP_REPOSITORY"
		fi
		if test_file "$BOOTSTRAP_CACHE"; then
			echo "Using debootstrap cache : $BOOTSTRAP_CACHE"
			DEBOOTSTRAP_CACHE_OPTION="--unpack-tarball \"$BOOTSTRAP_CACHE\""
		else
			echo "Building debootstrap cache failed."
		fi
	fi

	# Now build our destination
	eval debootstrap --arch i386 "$DEBOOTSTRAP_CACHE_OPTION" --foreign --include="$BOOTSTRAP_EXTRA_PKGSS" "$BOOTSTRAP_FLAVOR" "$MNTDIR" "$BOOTSTRAP_REPOSITORY"

	# init script to be run on first VM boot
	local BS_FILE="$MNTDIR/bootstrap-init.sh"
	cat > "$BS_FILE" << EOF
#!/bin/sh
mount -no remount,rw /
cat /proc/mounts

# Fix for linux-image module which isn't handled correctly by debootstrap
touch /vmlinuz /initrd.img
echo "do_initrd = Yes" >> /etc/kernel-img.conf

/debootstrap/debootstrap --second-stage
mount -nt proc proc /proc

echo -e '\n\n\n'

{
EOF

	if [[ "$BOOTSTRAP_PARTITION_TYPE" == "msdos" ]]; then
		cat >> "$BS_FILE" << EOF
/usr/sbin/grub-install /dev/[vh]da
/usr/sbin/update-grub
EOF
	fi

	if [[ -n "$BOOTSTRAP_FIRSTRUN_COMMAND" ]]; then
		echo eval "$BOOTSTRAP_FIRSTRUN_COMMAND" >> "$BS_FILE"
	fi

	cat >> "$BS_FILE" << EOF

echo "Bootstrap ended, halting"
} | /usr/bin/tee -a /var/log/bootstrap.log
exec /sbin/init 0
EOF

	chmod +x "$BS_FILE"

	if [[ -n "$BOOTSTRAP_PRERUN_COMMAND" ]]; then
		eval "$BOOTSTRAP_PRERUN_COMMAND"
	fi

	# umount
	sync
	umount "$MNTDIR"

	# Start VM to debootstrap, second stage
	desc_update_setting "KVM_NETWORK_MODEL" "virtio"
	desc_update_setting "KVM_DRIVE_IF" "virtio"
	desc_update_setting "KVM_KERNEL" "$BOOTSTRAP_KERNEL"
	desc_update_setting "KVM_INITRD" "$BOOTSTRAP_INITRD"
	desc_update_setting "KVM_APPEND" "root=$rootdev ro init=/bootstrap-init.sh"
	

	kvm_start_vm "$VM_NAME"

	sync	
	mount "$PARTDEV" "$MNTDIR"
	sync

	cat "$MNTDIR/var/log/bootstrap.log" >> "$LOGFILE"

{
	rm "$BS_FILE"
	
	# Copy some files/configuration from host
	bs_copy_from_host /etc/hosts
	bs_copy_from_host /etc/resolv.conf
  echo "Europe/Paris" > "$MNTDIR/etc/hostname"
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
	
	if [[ -n "$swap_uuid" ]]; then
		echo "$swap_uuid		none	swap	sw	0	0" >> "$MNTDIR/etc/fstab"
	fi


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
	
	if [[ -n "$BOOTSTRAP_FINALIZE_COMMAND" ]]; then
		eval "$BOOTSTRAP_FINALIZE_COMMAND"
	fi
	
	sync

	desc_update_setting "KVM_APPEND" "root=$rootdev ro"

	if [[ "$BOOTSTRAP_PARTITION_TYPE" == "msdos" ]]; then
		desc_remove_setting "KVM_KERNEL"
		desc_remove_setting "KVM_INITRD"
		desc_remove_setting "KVM_APPEND"
	fi
} | tee -a "$LOGFILE"
}

