#!/bin/bash
#
# KVM Wrapper Script
# -- bencoh, 2009/06
#


#######################################################################
# Draft 
#######################################################################
#
# kvm -net nic,model=virtio,macaddr=00:11:22:33:44:55 -net tap
# 	  -hda /path/to/hda -hdb /path/to/hdb -cdrom /path/to/cdrom
#	  -boot a|c|d|n
#	  -k en-us
#	  -vnc :1 -nographics -curses
#	  -pidfile myfile.pid
#
#######################################################################

PATH=/usr/sbin:/usr/bin:/sbin:/bin

function canonpath ()
{
	echo $(cd $(dirname $1); pwd -P)/$(basename $1)
}

# Exit on fail and print a nice message
function fail_exit ()
{
	echo -e "$1"
	echo "Exiting."

	# Hang for a while - for screen
	sleep 100

	exit 1
}

# FS node testers
function test_exist ()
{
	local NODE="$1"
	[[ -e "$NODE" ]]
}

function test_dir ()
{
	local DIR="$1"
	[[ -d "$DIR" && -r "$DIR" ]]
}

function test_dir_rw ()
{
	local DIR="$1"
	[[ -d "$DIR" && -r "$DIR" && -w "$DIR" ]]
}

function test_file ()
{
	local FILE="$1"
	[[ -f "$FILE" && -r "$FILE" ]]
}

function test_file_rw ()
{
	local FILE="$1"
	[[ -f "$FILE" && -r "$FILE" && -w "$FILE" ]]
}

function test_pid ()
{
	local PID="$1"
	ps "$PID" >& /dev/null
}

function test_pid_from_file ()
{
	local PID_FILE="$1"
	test_file "$PID_FILE" && test_pid `cat "$PID_FILE"`
}

function test_socket ()
{
	local FILE="$1"
	[[ -S "$FILE" && -r "$FILE" ]]
}

function test_socket_rw ()
{
	local FILE="$1"
	[[ -S "$FILE" && -r "$FILE" && -w "$FILE" ]]
}

function test_blockdev ()
{
	local FILE="$1"
	[[ -b "$FILE" && -r "$FILE" ]]
}

function test_blockdev_rw ()
{
	local FILE="$1"
	[[ -b "$FILE" && -r "$FILE" && -w "$FILE" ]]
}

function test_exec ()
{
	local FILE="$1"
	[[ -x "$FILE" && -r "$FILE" ]]
}

function test_nodename ()
{
	local NODE="$1"
	[[ -n "$NODE" && "$NODE" != "`hostname -s`" && -n "`get_cluster_host $NODE`" ]]
}

function require_exec ()
{
	test_exec "$(which $1)" || fail_exit "$1 not found or not executable"
}

function check_create_dir ()
{
	local DIR="$1"
	test_dir_rw "$DIR" || mkdir -p "$DIR"
	test_dir_rw "$DIR" || fail_exit "Couldn't read/write VM PID directory :\n$DIR"
}

function wait_test_timelimit ()
{
	local PROPER=0
	local ELAPSED=0
	local TIMELIMIT=$1
	local EVAL_EXPR=$2
	while [[ $ELAPSED -le $TIMELIMIT ]]
	do
		ELAPSED=$(($ELAPSED+1))
		eval "$EVAL_EXPR" && PROPER=1;
		[[ $PROPER -eq 1 ]] && break
		sleep 1
	done
	echo $ELAPSED
	[[ $PROPER -eq 1 ]] && return 0
	return 1
}

function kvm_init_env ()
{
	VM_NAME="$1"
	KVM_CLUSTER_NODE=local
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	MONITOR_FILE="$MONITOR_DIR/$VM_NAME.unix"
	SERIAL_FILE="$SERIAL_DIR/$VM_NAME.unix"
	SCREENLOG="$LOGDIR/screenlog-$VM_NAME.log"

	local vmnamehash=$(echo $VM_NAME|md5sum)
	vmnamehash=${vmnamehash:0:5}
	SCREEN_SESSION_NAME="kvm-$VM_NAME-$vmnamehash"

	unset PID_FILE
	test_file "$VM_DESCRIPTOR" || fail_exit "Couldn't open VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"
	PID_FILE=${PID_FILE:-"$PID_DIR/${KVM_CLUSTER_NODE:-*}:$VM_NAME-vm.pid"}

}

function random_mac ()
{
# Macaddress : 52:54:00:ff:34:56
local RANGE=99
local STR=""
for blah in 0 1
do
	local number=$RANDOM
	let "number %= $RANGE"
	STR="$STR"":""$number"
done
local MACADDRESS="52:54:00:ff""$STR"
echo -ne $MACADDRESS
}

# cluster helpers
hash_string ()
{
	echo "$1"|md5sum|awk '{print $1}'
}

set_cluster_host ()
{
	eval KVM_CLUSTER_HOSTS_`hash_string $1`="$2"
}

get_cluster_host ()
{
	eval echo '${KVM_CLUSTER_HOSTS_'`hash_string "$1"`'}'
}

run_remote ()
{
	HOST="`get_cluster_host $1`"
	shift
	require_exec ssh
	SSH_OPTS=${SSH_OPTS:-"-t"}
	[[ -n "$KVM_CLUSTER_IDENT" ]] && SSH_OPTS+=" -i $KVM_CLUSTER_IDENT"
	echo ssh $SSH_OPTS "$HOST" $@
	ssh $SSH_OPTS "$HOST" $@
}
# NBD helpers
function nbd_img_link ()
{
	KVM_IMAGE="$1"
	echo "$NBD_IMG_LINK_DIR/$(basename $KVM_IMAGE)-$(echo $(canonpath "$KVM_IMAGE") | md5sum | awk '{print $1}')"
}

function kvm_nbd_connect ()
{
	require_exec "$KVM_NBD_BIN"
	check_create_dir $NBD_IMG_LINK_DIR
	local KVM_IMAGE="$1"

	local KVM_IMAGE_NBD_LINK=$(nbd_img_link "$KVM_IMAGE")
	[[ -h "$KVM_IMAGE_NBD_LINK" ]] && fail_exit "Image disk $KVM_IMAGE seems to be connected already."

	local i=0
	local SUCCESS=0
	for ((i=0; i <= 15; i++))
	do
		local NBD_BLOCKDEV="/dev/nbd$i"
		local NBD_SOCKET_LOCK="/var/lock/qemu-nbd-nbd$i"

		test_blockdev_rw "$NBD_BLOCKDEV" || continue
		test_socket "$NBD_SOCKET_LOCK" && continue

		$KVM_NBD_BIN -c "$NBD_BLOCKDEV" "$KVM_IMAGE"
		ln -s "$NBD_BLOCKDEV" "$KVM_IMAGE_NBD_LINK"

		echo "Connected: $KVM_IMAGE to $NBD_BLOCKDEV."
		SUCCESS=1
		break
	done
	[[ $SUCCESS -eq 1 ]] || fail_exit "Couldn't connect image disk for some reason."
}

function kvm_nbd_disconnect ()
{
	require_exec "$KVM_NBD_BIN"
	check_create_dir $NBD_IMG_LINK_DIR
	local KVM_IMAGE="$1"

	local KVM_IMAGE_NBD_LINK=$(nbd_img_link "$KVM_IMAGE")
	[[ -h "$KVM_IMAGE_NBD_LINK" ]] || fail_exit "Image disk $KVM_IMAGE does not seem to be connected."
	$KVM_NBD_BIN -d "$KVM_IMAGE_NBD_LINK"
	rm -f "$KVM_IMAGE_NBD_LINK"
}

# LVM helpers
function lvm_create_disk ()
{
	require_exec "$LVM_LVCREATE_BIN"

	LVM_LV_NAME="${LVM_LV_NAME:-"vm.$VM_NAME"}"
	local LVM_LV_SIZE=$(($ROOT_SIZE+${SWAP_SIZE:-0}))

	eval "$LVM_LVCREATE_BIN --name $LVM_LV_NAME --size $LVM_LV_SIZE $LVM_VG_NAME $LVM_PV_NAME"
	desc_update_setting "KVM_DISK1" "/dev/$LVM_VG_NAME/$LVM_LV_NAME"
}

function map_disk()
{
	local DISKDEV=$1
	kpartx -a -p- "$DISKDEV" > /dev/null
	echo /dev/mapper/`kpartx -l -p- $DISKDEV | grep -m 1 -- "-1.*$DISKDEV" | awk '{print $1}'`
}

function unmap_disk()
{
	local DISKDEV=$1
	kpartx -d -p- "$DISKDEV"
}

function lvm_mount_disk()
{
	set -e

	test_file "$PID_FILE" && fail_exit "VM $VM_NAME seems to be running! (PID file $PID_FILE exists)\nYou cannot mount disk on a running VM"

	echo "Attempting to mount first partition of $KVM_DISK1"
	PART=`map_disk "$KVM_DISK1"`
	mkdir -p "/mnt/$VM_NAME"
	mount "$PART" "/mnt/$VM_NAME"
	set +e
}

function lvm_umount_disk()
{
	set -e
	echo "unmounting $KVM_DISK1"
	umount "/mnt/$VM_NAME" 
	rmdir "/mnt/$VM_NAME"
	unmap_disk "$KVM_DISK1"
	set +e
}

# Change perms. Meant to run forked.
function serial_perms_forked()
{
	while [[ ! -e "$SERIAL_FILE" ]];
	do
		! ps "$$"  >& /dev/null && return
		sleep 1
	done
	if [[ -n "$SERIAL_USER" ]]; then
		chown "$SERIAL_USER" "$SERIAL_FILE"
		chmod 600 "$SERIAL_FILE"
	fi
	if [[ -n "$SERIAL_GROUP" ]]; then
		chgrp "$SERIAL_GROUP" "$SERIAL_FILE"
		chmod g+rw "$SERIAL_FILE"
	fi
}

# VM descriptor helpers
# Update (if exists) descriptor setting and keep a backup, create otherwise
function desc_update_backup_setting ()
{
	local KEY="$1"
	local VALUE="$2"
	local IDENT=$RANDOM

	#sed -i "s/^$KEY.*/#\0 ###AUTO$IDENT\n$KEY=$(escape_sed "\"$VALUE\"") ###AUTO$IDENT/g" "$VM_DESCRIPTOR"
	sed -i "s/^$KEY.*/#\0 ###AUTO$IDENT/g" "$VM_DESCRIPTOR"
	echo "$KEY=\"$VALUE\" ###AUTO$IDENT" >> "$VM_DESCRIPTOR"

	echo $IDENT
}

# Overwrite (or create) descriptor setting
function desc_update_setting ()
{
	local KEY="$1"
	local VALUE="$2"

	local MATCH="^#*$KEY"
	local NEW="$KEY=\"$VALUE\""
	sed -i -e "0,/$MATCH/ {
		s@$MATCH=\?\(.*\)@$NEW ## \1@g
		$ t
		$ a$NEW
		}" "$VM_DESCRIPTOR"
	#sed -i "/^$KEY.*/d" "$VM_DESCRIPTOR"
	#echo "$KEY=\"$VALUE\" ###AUTO" >> "$VM_DESCRIPTOR"
}

# Revert descriptor setting modified by this script
function desc_revert_setting()
{
	local IDENT="$1"
	sed -i "/^[^#].*###AUTO$IDENT$/d" "$VM_DESCRIPTOR"
	sed -ie "s/^#\(.*\)###AUTO$IDENT$/\1/g" "$VM_DESCRIPTOR"
}

function desc_remove_setting()
{
	local KEY="$1"
	sed -i "/^$KEY/d" "$VM_DESCRIPTOR"
}

function monitor_send_cmd ()
{
	echo "$1" | socat STDIN unix:"$MONITOR_FILE"
}

function monitor_send_sysrq ()
{
	local SYSRQ="$1"
	monitor_send_cmd "sendkey ctrl-alt-sysrq-$SYSRQ"
}

# VM Status
function kvm_status_from_pid
{
	local VM_PID=$@
	test_nodename "$NODE" && run_remote $NODE ps wwp "$VM_PID" || ps wwp "$VM_PID"
}

function kvm_status_vm ()
{
	kvm_init_env "$1"
	test_file "$PID_FILE" || fail_exit "Error : $VM_NAME doesn't seem to be running."

	kvm_status_from_pid `cat "$PID_FILE"`
}

function kvm_status ()
{
	if [[ ! "$1" == "all" ]];
	then
		kvm_status_vm "$1"
	else
		for NODE in `ls -1 $PID_DIR/*-vm.pid|cut -d: -f1|sed -e 's:.*/::'|uniq`
		do
			echo "servers on $NODE:"
			kvm_status_from_pid `cat $PID_DIR/$NODE\:*-vm.pid`
		done
	fi
}

# Main function : start a virtual machine
function kvm_start_vm ()
{
	check_create_dir "$PID_DIR"
	check_create_dir "$MONITOR_DIR"
	check_create_dir "$SERIAL_DIR"

	[[ -z "$KVM_BIN" ]] && KVM_BIN="/usr/bin/kvm"
	require_exec "$KVM_BIN"

	# Build KVM Drives (hdd, cdrom) parameters
	local KVM_DRIVES=""
	KVM_DRIVE_IF="${KVM_DRIVE_IF:-ide}"
	[[ -n "$KVM_DISK1" ]] && KVM_DRIVES="$KVM_DRIVES -drive file=\"$KVM_DISK1\",if=$KVM_DRIVE_IF,boot=on"
	[[ -n "$KVM_DISK2" ]] && KVM_DRIVES="$KVM_DRIVES -drive file=\"$KVM_DISK2\",if=$KVM_DRIVE_IF"
	[[ -n "$KVM_DISK3" ]] && KVM_DRIVES="$KVM_DRIVES -drive file=\"$KVM_DISK3\",if=$KVM_DRIVE_IF"
	[[ -n "$KVM_DISK4" ]] && KVM_DRIVES="$KVM_DRIVES -drive file=\"$KVM_DISK4\",if=$KVM_DRIVE_IF"
	
	[[ -n "$KVM_CDROM" ]] && KVM_DRIVES="$KVM_DRIVES -cdrom \"$KVM_CDROM\""
	[[ "$KVM_DRIVES" == "" ]] && [[ "$KVM_BOOTDEVICE" != "n" ]] && fail_exit "Your VM $VM_NAME should at least use one cdrom or harddisk drive !\nPlease check your conf file :\n$VM_DESCRIPTOR"
	local LINUXBOOT=""
	[[ -n "$KVM_KERNEL" ]] && LINUXBOOT="$LINUXBOOT -kernel \"$KVM_KERNEL\""
	[[ -n "$KVM_INITRD" ]] && LINUXBOOT="$LINUXBOOT -initrd \"$KVM_INITRD\""
	[[ -n "$KVM_APPEND" ]] && LINUXBOOT="$LINUXBOOT -append \"$KVM_APPEND\""

	# Network scripts
	[[ -z "$KVM_BRIDGE" ]] && KVM_BRIDGE="kvmnat"
	export KVM_BRIDGE
	KVM_NET_SCRIPT="$ROOTDIR/net/kvm"

	[[ "$KVM_NETWORK_MODEL" = "vhost_net" ]] \
		&& KVM_NET="-netdev type=tap,id=guest0,script=$KVM_NET_SCRIPT-ifup,downscript=$KVM_NET_SCRIPT-ifdown,vhost=on -device virtio-net-pci,netdev=guest0,mac=$KVM_MACADDRESS" \
		|| KVM_NET="-net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net tap,script=$KVM_NET_SCRIPT-ifup,downscript=$KVM_NET_SCRIPT-ifdown"

	# Monitor/serial devices
	KVM_MONITORDEV="-monitor unix:$MONITOR_FILE,server,nowait"
	KVM_SERIALDEV="-serial unix:$SERIAL_FILE,server,nowait"

	# Build kvm exec string
	local EXEC_STRING="$KVM_BIN -name $VM_NAME -m $KVM_MEM -smp $KVM_CPU_NUM $KVM_NET $KVM_DRIVES -boot $KVM_BOOTDEVICE $KVM_KEYMAP $KVM_OUTPUT $LINUXBOOT $KVM_MONITORDEV $KVM_SERIALDEV -pidfile $PID_FILE $KVM_ADDITIONNAL_PARAMS"

	# More sanity checks : VM running, monitor socket existing, etc.
	if [[ -z "$FORCE" ]]; then
		test_file "$PID_FILE" && fail_exit "VM $VM_NAME seems to be running already.\nPID file $PID_FILE exists"
		rm -rf "$MONITOR_FILE"
		rm -rf "$SERIAL_FILE"
		test_socket "$MONITOR_FILE" && fail_exit "Monitor socket $MONITOR_FILE already existing and couldn't be removed"	
		test_socket "$SERIAL_FILE" && fail_exit "Serial socket $SERIAL_FILE already existing and couldn't be removed"

		# Fork change_perms
		[[ -n "$SERIAL_USER" ]] || [[ -n "$SERIAL_GROUP" ]] && serial_perms_forked &
	fi

	# Now run kvm
	echo $EXEC_STRING
	echo ""
	echo ""
	eval $EXEC_STRING

	# Cleanup files
	rm -rf "$PID_FILE"
	rm -rf "$MONITOR_FILE"
	rm -rf "$SERIAL_FILE"

	# Exit
	return 0
}

function kvm_stop_vm ()
{
	test_file "$PID_FILE" || fail_exit "VM $VM_NAME doesn't seem to be running.\nPID file $PID_FILE not found"
#	test_socket_rw "$MONITOR_FILE" || fail_exit "Monitor socket $MONITOR_FILE not existing or not writable"

	local TIMELIMIT=20

	# Send monitor command through unix socket
	echo "Trying to powerdown the VM $VM_NAME first, might take some time (up to $TIMELIMIT sec)"
	monitor_send_cmd "system_powerdown"
	echo -n "Waiting ..."

	# Now wait for it
	local ELAPSED=0
	ELAPSED=$(wait_test_timelimit $TIMELIMIT "! test_file $PID_FILE")
	local PROPER=$?
	echo " elapsed time : $ELAPSED sec"

	if [[ $PROPER -eq 0 ]];
	then
		echo "VM powerdown properly :)"
	else

		echo "Trying with magic-sysrq ... (10sec)"
		monitor_send_sysrq r && sleep 2
		monitor_send_sysrq e && sleep 2
		monitor_send_sysrq i && sleep 2
		monitor_send_sysrq s && sleep 2
		monitor_send_sysrq u && sleep 2
		monitor_send_sysrq o && sleep 2

		if test_file "$PID_FILE"
		then
			echo "Trying to monitor-quit the qemu instance."
			monitor_send_cmd "quit" && sleep 2

			if test_file "$PID_FILE"
			then
				# kill - SIGTERM
				local KVM_PID="`cat $PID_FILE`"
				echo "Now trying to terminate (SIGTERM) $VM_NAME, pid $KVM_PID"
				kill "$KVM_PID"
			fi
		fi
	fi

	! test_file "PID_FILE" && echo "VM $VM_NAME is now down."
	
	return 0
}

function kvm_run_disk ()
{
	require_exec "$KVM_BIN"
	KVM_DISK1="$1"
	test_file_rw "$KVM_DISK1" || "Couldn't read/write image file :\n$KVM_DISK1"

	# Build kvm exec string
	local EXEC_STRING="$KVM_BIN -net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net tap -hda $KVM_DISK1 -boot c $KVM_KEYMAP $KVM_OUTPUT $KVM_ADDITIONNAL_PARAMS"
	eval "$EXEC_STRING"

	return 0
}

function kvm_start_screen ()
{
	screen $SCREEN_ARGS -S "$SCREEN_SESSION_NAME" "$SCRIPT_PATH" start-here "$VM_NAME"
	sleep 1
}

function kvm_start_here_screen ()
{
	check_create_dir "$LOGDIR"
	rm -f "$SCREENLOG"
	screen -x "$SCREEN_SESSION_NAME" -X logfile "$SCREENLOG"
	screen -x "$SCREEN_SESSION_NAME" -X log
	{
		grep -m 1 'kvm' <(tail -f "$SCREENLOG") >/dev/null
		screen -x "$SCREEN_SESSION_NAME" -X log
	}&
	sleep 1
	kvm_start_vm "$VM_NAME"
}

function kvm_attach_screen ()
{
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	screen -x "$SCREEN_SESSION_NAME"
}

function kvm_monitor ()
{
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	! test_socket_rw "$MONITOR_FILE" && fail_exit "Error : could not open monitor socket $MONITOR_FILE."
	echo "Attaching monitor unix socket (using socat). Press ^D (EOF) to exit"
	socat READLINE unix:"$MONITOR_FILE"
	echo "Monitor exited"
}

function kvm_serial ()
{
	! test_exist "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	! test_socket_rw "$SERIAL_FILE" && fail_exit "Error : could not open serial socket $SERIAL_FILE."
	echo "Attaching serial console unix socket (using socat). Press ^] to exit"
	socat -,IGNBRK=0,BRKINT=0,PARMRK=0,ISTRIP=0,INLCR=0,IGNCR=0,ICRNL=0,IXON=0,OPOST=1,ECHO=0,ECHONL=0,ICANON=0,ISIG=0,IEXTEN=0,CSIZE=0,PARENB=0,CS8,escape=0x1d unix:"$SERIAL_FILE"
	[[ "xx$?" != "xx0" ]] && fail_exit "socat must be of version > 1.7.0 to work"
	stty sane
	echo "Serial console exited"
}

function kvm_list ()
{
	echo "Available VM descriptors :"
	for file in "$VM_DIR"/*-vm
	do
		kvm_init_env `basename "${file%"-vm"}"`
		local VM_STATUS="Halted"
#		test_file "$PID_FILE" && VM_STATUS=$(test_pid `cat "$PID_FILE"` && echo "Running" || echo "Error!")
		test_file "$PID_FILE" && VM_STATUS="Running"
		printf "\t%-20s\t$VM_STATUS\ton ${KVM_CLUSTER_NODE:-local}\n" "$VM_NAME"
	done
}

function kvm_edit_descriptor ()
{
	kvm_init_env "$1"
	test_file "$VM_DESCRIPTOR" && "$EDITOR" "$VM_DESCRIPTOR"
}

function kvm_create_descriptor ()
{
	local DISK_CREATED=0
	if [[ -n $2 ]]
	then
		require_exec "$KVM_IMG_BIN"
		local KVM_IMG_DISKNAME="`canonpath \"$2\"`"
	fi
	if [[ -z $3 ]]
	then
		DISK_CREATED=1
	fi
	if [[ -n $3 ]]
	then
		echo "Calling kvm-img to create disk image"
		local KVM_IMG_DISKSIZE="$3"
		"$KVM_IMG_BIN" create -f "$KVM_IMG_FORMAT" "$KVM_IMG_DISKNAME" "$KVM_IMG_DISKSIZE"
		if [[ "xx$?" == "xx0" ]] 
		then
			DISK_CREATED=1
		else
			echo "Failed creating disk. Creating vm anyway"
		fi
	fi

	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file "$VM_DESCRIPTOR" && fail_exit "Error : $VM_NAME exists already ($VM_DESCRIPTOR found)"

	touch "$VM_DESCRIPTOR"
	echo "# VM $VM_NAME file descriptor" 			>> "$VM_DESCRIPTOR"
	echo "# Created : `date` on $HOSTNAME by $USER" >> "$VM_DESCRIPTOR"
	echo "" 										>> "$VM_DESCRIPTOR"


	awk '/#xxDEFAULTxx#/,0 { print "#" $0}' $CONFFILE|grep -v "#xxDEFAULTxx#" >> "$VM_DESCRIPTOR"

	if [[ "xx$DISK_CREATED" == "xx1" ]]
	then
		local HDA_LINE="KVM_DISK1=\"$KVM_IMG_DISKNAME\""
		sed -i "s,##KVM_DISK1,$HDA_LINE,g" "$VM_DESCRIPTOR"
	fi

	sed -i 's/#KVM_MACADDRESS="`random_mac`/KVM_MACADDRESS="'`random_mac`'/g' "$VM_DESCRIPTOR"
	sed -i 's/#KVM_CLUSTER_NODE="`hostname -s`/KVM_CLUSTER_NODE="'`hostname -s`'/g' "$VM_DESCRIPTOR"
	


	echo "VM $VM_NAME created. Descriptor : $VM_DESCRIPTOR"
}

function kvm_bootstrap_vm ()
{

	cleanup()
	{
		set +e
		echo "Cleaning up the mess"
		if [ ${#CLEANUP[*]} -gt 0 ]; then
			LAST_ELEMENT=$((${#CLEANUP[*]}-1))
			for i in `seq $LAST_ELEMENT -1 0`; do
				eval ${CLEANUP[$i]}
			done
		fi
	}

	local CLEANUP=( )

	set -e
	trap cleanup EXIT

	require_exec "kpartx"
	check_create_dir "$BOOT_IMAGES_DIR"
	check_create_dir "$CACHE_DIR"
	check_create_dir "$LOGDIR"

	kvm_init_env "$1"
	test_file "$PID_FILE" && fail_exit "Error : $VM_NAME seems to be running. Please stop it before trying to bootstrap it."

	if [[ -n "$2" ]]; then
		BOOTSTRAP_DISTRIB="$2"   # The variable is already set in the config file otherwise.
	fi
	BOOTSTRAP_SCRIPT="$BOOTSTRAP_DIR/$BOOTSTRAP_DISTRIB/bootstrap.sh"
	test_file "$BOOTSTRAP_SCRIPT" || fail_exit "Couldn't read $BOOTSTRAP_SCRIPT to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB"
	source "$BOOTSTRAP_SCRIPT"
	
	if ! test_blockdev "$KVM_DISK1"
	then
		require_exec "$KVM_NBD_BIN"
		test_file "$KVM_DISK1" || fail_exit ""$KVM_DISK1" appears to be neither a blockdev nor a regular file."
		echo "Attempting to connect the disk image to an nbd device."
		kvm_nbd_connect "$KVM_DISK1"
		local BOOTSTRAP_DEVICE=$(nbd_img_link "$KVM_DISK1")
	else
		local BOOTSTRAP_DEVICE="$KVM_DISK1"
	fi

	echo "Starting to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB on disk $KVM_DISK1"
	bootstrap_fs "$BOOTSTRAP_DEVICE"
	sync
	test_blockdev "$KVM_DISK1" || kvm_nbd_disconnect "$KVM_DISK1"

	cleanup
	trap - EXIT
	set +e

	echo "Bootstrap ended."
	return 0
}

function kvm_build_vm ()
{
	local USER_OPTIONS=( )

	while [[ "$#" -gt 1 ]]; do
		case "$1" in
			"-s"|"--size")
				USER_OPTIONS+=("ROOT_SIZE")
				USER_OPTIONS+=("$2")
				shift; shift
				;;
			"-m"|"--mem"|"--memory")
				USER_OPTIONS+=("KVM_MEM")
				USER_OPTIONS+=("$2")
				shift; shift
				;;
			"-c"|"--cpu"|"--smp")
				USER_OPTIONS+=("KVM_CPU_NUM")
				USER_OPTIONS+=("$2")
				shift; shift
				;;
			"--swap")
				USER_OPTIONS+=("SWAP_SIZE")
				USER_OPTIONS+=("$2")
				shift; shift
				;;
			"-e"|"--edit"|"--edit-conf")
				EDIT_CONF="yes"
				shift
				;;
		esac
	done
	if [[ ! "$#" -eq 1 ]]; then print_help; exit 1; fi

	VM_NAME="$1"

	test_file "$AUTOCONF_SCRIPT" || fail_exit "Couldn't read autoconfiguration script $AUTOCONF_SCRIPT\n"

	kvm_create_descriptor "$VM_NAME"
	
	source "$AUTOCONF_SCRIPT"

	if [ ${#USER_OPTIONS[*]} -gt 0 ]; then
		LAST_ELEMENT=$((${#USER_OPTIONS[*]}-2))
		for i in `seq 0 2 $LAST_ELEMENT`; do
			desc_update_setting "${USER_OPTIONS[$i]}" "${USER_OPTIONS[$((i+1))]}"
		done
	fi

	if [[ -n "$EDIT_CONF" ]]; then
		kvm_edit_descriptor "$VM_NAME"
	fi

	kvm_init_env "$VM_NAME"

	lvm_create_disk "$VM_NAME"
	kvm_bootstrap_vm "$VM_NAME"

	echo "$VM_NAME" >> "$STARTUP_LIST"

	echo "Will now start VM $VM_NAME"
	kvm_start_screen "$VM_NAME"
	sleep 1
	kvm_attach_screen "$VM_NAME"
}

function kvm_balloon_vm ()
{
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	! test_socket_rw "$MONITOR_FILE" && fail_exit "Error : could not open monitor socket $MONITOR_FILE."
	monitor_send_cmd "balloon $1"
}

function kvm_remove ()
{

	test_file "$PID_FILE" && fail_exit "Error : $VM_NAME seems to be running. Please stop it before trying to remove it."

	local DRIVES_LIST=( )
	[[ -n "$KVM_DISK1" ]] && DRIVES_LIST+=("$DRIVES_LIST$KVM_DISK1")
	[[ -n "$KVM_DISK2" ]] && DRIVES_LIST+=("$DRIVES_LIST$KVM_DISK2")
	[[ -n "$KVM_DISK3" ]] && DRIVES_LIST+=("$DRIVES_LIST$KVM_DISK3")
	[[ -n "$KVM_DISK4" ]] && DRIVES_LIST+=("$DRIVES_LIST$KVM_DISK4")
	if [ ${#DRIVES_LIST[*]} -gt 0 ]; then
		LAST_ELEMENT=$((${#DRIVES_LIST[*]}-1))
		for i in `seq $LAST_ELEMENT -1 0`; do
			if lvdisplay "${DRIVES_LIST[$i]}" >&/dev/null; then
				if lvremove "${DRIVES_LIST[$i]}"; then
					unset DRIVES_LIST[$i]
				fi
			fi
		done
	fi
			
	if [ ${#DRIVES_LIST[*]} -gt 0 ]; then
		echo "The VM $VM_NAME used the following disks (NOT removed by $SCRIPT_NAME) :"
		for DRIVE in ${DRIVES_LIST[*]}; do
			echo $DRIVE
		done
	fi
	rm -f "$VM_DESCRIPTOR"
	test_file "$VM_DESCRIPTOR" && fail_exit "Failed to remove descriptor $VM_DSCRIPTOR."
}

function print_help ()
{
	case "$1" in
		"create")
	echo -e "Usage $SCRIPT_NAME create [flags] virtual-machine"
	echo
	echo -e "Flags are :"
	echo -e "   -m size, --mem size:    Specify how much RAM you want the system to have"
	echo -e "   -s size, --size size:   Specify how big the disk should be in MB"
	echo -e "   -e, --edit:             If you want to edit the descriptor after autoconfiguration"
	echo -e "   -c num, --cpu num:      Number of cpu the system should have"
	echo -e "   --swap size:            Size of the swap in MB"
	echo
	echo -e " More to come ?"
	;;
		*)
	echo -e "Usage: $SCRIPT_NAME {start|screen|stop} virtual-machine"
	echo -e "       $SCRIPT_NAME {attach|monitor|serial} virtual-machine"
	echo -e "       $SCRIPT_NAME {save-state|load-state} virtual-machine"
	echo -e "       $SCRIPT_NAME migrate dest-node virtual-machine"
	echo -e ""
	echo -e "       $SCRIPT_NAME status [virtual-machine]"
	echo -e "       $SCRIPT_NAME list"
	echo
	echo -e "       $SCRIPT_NAME balloon target_RAM virtual-machine"
	echo -e "       $SCRIPT_NAME create [flags] virtual-machine #for flag list, try $SCRIPT_NAME help create"
	echo -e "       $SCRIPT_NAME create-desc virtual-machine [diskimage [size]]"
	echo -e "       $SCRIPT_NAME bootstrap virtual-machine"
	echo -e "       $SCRIPT_NAME edit virtual-machine"
	echo -e "       $SCRIPT_NAME remove virtual-machine"
	;;
	esac
	exit 2
}

SCRIPT_PATH="$0"
SCRIPT_NAME="`basename $SCRIPT_PATH`"
ROOTDIR="/usr/share/kvm-wrapper"
CONFFILE="$ROOTDIR/kvm-wrapper.conf"

test_dir "$ROOTDIR" || fail_exit "Couldn't open kvm-wrapper's root directory :\n$ROOTDIR"
test_file "$CONFFILE" || fail_exit "Couldn't open kvm-wrapper's configuration file :\n$CONFFILE"

# Load default configuration file
source "$CONFFILE"

test_file "$CLUSTER_CONF" && source "$CLUSTER_CONF"

# Check VM descriptor directory
test_dir "$VM_DIR" || fail_exit "Couldn't open VM descriptor directory :\n$VM_DIR"


case "$1" in
	list)
		kvm_list
		exit 0
		;;
	rundisk)
		if [[ $# -eq 2 ]]; then
			kvm_run_disk "$2"
		else print_help; fi
		exit 0
		;;
	edit)
		if [[ $# -eq 2 ]]; then
			kvm_edit_descriptor "$2"
		else print_help; fi
		exit 0
		;;
	create-desc*)
		if [[ $# -ge 2 ]]; then
			kvm_create_descriptor "$2" "$3" "$4"
		else print_help; fi
		exit 0
		;;
	create|build)
		if [[ $# -ge 2 ]]; then
			shift
			kvm_build_vm $@
		else print_help; fi
		exit 0
		;;
	help)
		shift
		print_help $@
		exit 0
		;;
esac

kvm_init_env "${!#}"

test_nodename "$KVM_CLUSTER_NODE" && { run_remote $KVM_CLUSTER_NODE $ROOTDIR/kvm-wrapper.sh $@; exit $?; }

# Argument parsing
case "$1" in
	remove)
		if [[ $# -eq 2 ]]; then
			kvm_remove "$2"
		else print_help; fi
		;;
	migrate)
		if [[ $# -eq 3 ]]; then
			! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
			! test_socket_rw "$MONITOR_FILE" && fail_exit "Error : could not open monitor socket $MONITOR_FILE."
			desc_update_setting "KVM_CLUSTER_NODE" "$2"
			PORT=$((RANDOM%1000+4000))
			"$SCRIPT_PATH" receive-migrate-screen $PORT "$3"
			sleep 1
			monitor_send_cmd "migrate_set_speed 1024m"
#			monitor_send_cmd "migrate \"exec: ssh `get_cluster_host $2` socat - unix:$RUN_DIR/migrate-$3.sock\""
			monitor_send_cmd "migrate tcp:`get_cluster_host $2`:$PORT"
			monitor_send_cmd "quit"
		else print_help; fi
		;;
	receive-migrate)
		if [[ $# -eq 3 ]]; then
#			KVM_ADDITIONNAL_PARAMS+=" -incoming unix:$RUN_DIR/migrate-$VM_NAME.sock"  
			KVM_ADDITIONNAL_PARAMS+=" -incoming tcp:`get_cluster_host $(hostname -s)`:$2"  
			FORCE="yes"
			kvm_start_vm "$VM_NAME"
		else print_help; fi
		;;
	receive-migrate-screen)
		if [[ $# -eq 3 ]]; then
			screen -d -m -S "$SCREEN_SESSION_NAME" "$SCRIPT_PATH" receive-migrate "$2" "$VM_NAME"
			sleep 1
		else print_help; fi
		;;
	save-state)
		if [[ $# -eq 2 ]]; then
			! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
			! test_socket_rw "$MONITOR_FILE" && fail_exit "Error : could not open monitor socket $MONITOR_FILE."
#			monitor_send_cmd "stop"
			monitor_send_cmd "migrate_set_speed 4095m"
			monitor_send_cmd "migrate \"exec:gzip -c > /var/cache/kvm-wrapper/$2-state.gz\""
			monitor_send_cmd "cont"
		else print_help; fi
		;;
	load-state)
		if [[ $# -eq 2 ]]; then
			KVM_ADDITIONNAL_PARAMS+=" -incoming \"exec: gzip -c -d /var/cache/kvm-wrapper/$2-state.gz\""  
			FORCE="yes"
			kvm_start_vm "$2"
		else print_help; fi
		;;
	balloon)
		if [[ $# -eq 3 ]]; then
			kvm_balloon_vm "$2"
		else print_help; fi
		;;
	restart)
		if [[ $# -eq 2 ]]; then
			kvm_stop_vm "$2"
			SCREEN_ARGS="-m"
			kvm_start_screen "$2"
		else print_help; fi
		;;
	start)
		if [[ $# -eq 2 ]]; then
			SCREEN_ARGS="-m"
			kvm_start_screen "$2"
		else print_help; fi
		;;
	start-here)
		if [[ $# -eq 2 ]]; then
			kvm_start_vm "$2"
		else print_help; fi
		;;
	start-here-screen)
		if [[ $# -eq 2 ]]; then
			kvm_start_here_screen "$2"
		else print_help; fi
		;;
	screen)
		if [[ $# -eq 2 ]]; then
			SCREEN_ARGS="-d -m"
			kvm_start_screen "$2"
		else print_help; fi
		;;
	attach)
		if [[ $# -eq 2 ]]; then
			kvm_attach_screen "$2"
		else print_help; fi
		;;
	monitor)
		if [[ $# -eq 2 ]]; then
			kvm_monitor "$2"
		else print_help; fi
		;;
	status)
		if [[ -n "$2" ]]; then 
			kvm_status "$2"
		else kvm_status "all"; fi
		exit 0
		;;
	serial)
		if [[ $# -eq 2 ]]; then
			kvm_serial "$2"
		else print_help; fi
		;;
	stop)
		if [[ $# -eq 2 ]]; then
			kvm_stop_vm "$2"
		else print_help; fi
		;;
	bootstrap)
		if [[ $# -ge 2 ]]; then
			kvm_bootstrap_vm "$2" "$3"
		else print_help; fi
		;;
	create-disk)
		lvm_create_disk "$2"
		;;
	mount-disk)
		lvm_mount_disk "$2"
		;;
	umount-disk)
		lvm_umount_disk "$2"
		;;
	*)
		print_help
		;;
esac

