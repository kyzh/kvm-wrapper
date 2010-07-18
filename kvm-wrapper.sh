#!/bin/sh
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
	exit 1
}

# FS node testers
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

	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file "$VM_DESCRIPTOR" || fail_exit "Couldn't open VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"

	LVM_LV_NAME="${LVM_LV_NAME:-"vm.$VM_NAME"}"
	eval "$LVM_LVCREATE_BIN --name $LVM_LV_NAME --size $LVM_LV_SIZE $LVM_VG_NAME"
	desc_update_setting "KVM_HDA" "/dev/$LVM_VG_NAME/$LVM_LV_NAME"
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

	#sed -i "s/^$KEY.*/$KEY=$(escape_sed "\"$VALUE\"") ###AUTO/g" "$VM_DESCRIPTOR"
	sed -i "/^$KEY.*/d" "$VM_DESCRIPTOR"
	echo "$KEY=\"$VALUE\" ###AUTO" >> "$VM_DESCRIPTOR"
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
function kvm_status_vm ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	test_file "$PID_FILE" || fail_exit "Error : $VM_NAME doesn't seem to be running."
	status_from_pid_file "$PID_FILE"
}

function status_from_pid_file ()
{
	local VM_PID=`cat "$1"`
	ps wwp "$VM_PID"
}

function kvm_status ()
{
	if [[ ! "$1" == "all" ]];
	then
		kvm_status_vm "$1"
	else
		for file in "$PID_DIR"/*-vm.pid
		do
			VM_NAME=`basename ${file%"-vm.pid"}`
			echo $VM_NAME :
			status_from_pid_file "$file"
		done
	fi
}

# Main function : start a virtual machine
function kvm_start_vm ()
{
	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	MONITOR_FILE="$MONITOR_DIR/$VM_NAME.unix"
	SERIAL_FILE="$SERIAL_DIR/$VM_NAME.unix"

	check_create_dir "$PID_DIR"
	check_create_dir "$MONITOR_DIR"
	check_create_dir "$SERIAL_DIR"

	test_file "$VM_DESCRIPTOR" || fail_exit "Couldn't open VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"

	[[ -z "$KVM_BIN" ]] && KVM_BIN="/usr/bin/kvm"
	require_exec "$KVM_BIN"

	# Build KVM Drives (hdd, cdrom) parameters
	local KVM_DRIVES=""
	[[ -n "$KVM_HDA" ]] && KVM_DRIVES="$KVM_DRIVES -hda $KVM_HDA"
	[[ -n "$KVM_HDB" ]] && KVM_DRIVES="$KVM_DRIVES -hdb $KVM_HDB"
	[[ -n "$KVM_HDC" ]] && KVM_DRIVES="$KVM_DRIVES -hdc $KVM_HDC"
	[[ -n "$KVM_HDD" ]] && KVM_DRIVES="$KVM_DRIVES -hdd $KVM_HDD"
	[[ -n "$KVM_CDROM" ]] && KVM_DRIVES="$KVM_DRIVES -cdrom $KVM_CDROM"
	[[ "$KVM_DRIVES" == "" ]] && fail_exit "Your VM $VM_NAME should at least use one cdrom or harddisk drive !\nPlease check your conf file :\n$VM_DESCRIPTOR"
	local LINUXBOOT=""
	[[ -n "$KVM_KERNEL" ]] && LINUXBOOT="$LINUXBOOT -kernel $KVM_KERNEL"
	[[ -n "$KVM_INITRD" ]] && LINUXBOOT="$LINUXBOOT -initrd $KVM_INITRD"
	[[ -n "$KVM_APPEND" ]] && LINUXBOOT="$LINUXBOOT -append \"$KVM_APPEND\""

	# Network scripts
	[[ -z "$KVM_BRIDGE" ]] && KVM_BRIDGE="kvmnat"
	export KVM_BRIDGE
	KVM_NET_SCRIPT="$ROOTDIR/net/kvm"
	KVM_NET_TAP="tap,script=$KVM_NET_SCRIPT-ifup,downscript=$KVM_NET_SCRIPT-ifdown"

	# Monitor/serial devices
	KVM_MONITORDEV="-monitor unix:$MONITOR_FILE,server,nowait"
	KVM_SERIALDEV="-serial unix:$SERIAL_FILE,server,nowait"

	# Build kvm exec string
	local EXEC_STRING="$KVM_BIN -name $VM_NAME -m $KVM_MEM -smp $KVM_CPU_NUM -net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net $KVM_NET_TAP $KVM_DRIVES -boot $KVM_BOOTDEVICE -k $KVM_KEYMAP $KVM_OUTPUT $LINUXBOOT $KVM_MONITORDEV $KVM_SERIALDEV -pidfile $PID_FILE $KVM_ADDITIONNAL_PARAMS"

	# More sanity checks : VM running, monitor socket existing, etc.
	test_file "$PID_FILE" && fail_exit "VM $VM_NAME seems to be running already.\nPID file $PID_FILE exists"
	rm -rf "$MONITOR_FILE"
	rm -rf "$SERIAL_FILE"
	test_socket "$MONITOR_FILE" && fail_exit "Monitor socket $MONITOR_FILE already existing and couldn't be removed"
	test_socket "$SERIAL_FILE" && fail_exit "Serial socket $SERIAL_FILE already existing and couldn't be removed"


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
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	MONITOR_FILE="$MONITOR_DIR/$VM_NAME.unix"

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
	KVM_HDA="$1"
	test_file_rw "$KVM_HDA" || "Couldn't read/write image file :\n$KVM_HDA"

	# Build kvm exec string
	local EXEC_STRING="$KVM_BIN -net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net tap -hda $KVM_HDA -boot c -k $KVM_KEYMAP $KVM_OUTPUT $KVM_ADDITIONNAL_PARAMS"
	eval "$EXEC_STRING"

	return 0
}

function kvm_start_screen ()
{
	VM_NAME="$1"
	SCREEN_SESSION_NAME="kvm-$VM_NAME"
	screen -d -m -S "$SCREEN_SESSION_NAME" /bin/sh -c "\"$SCRIPT_PATH\" start \"$VM_NAME\""
	local EXITNUM="$?"
	return $EXITNUM
}

function kvm_attach_screen ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	SCREEN_SESSION_NAME="kvm-$VM_NAME"
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	screen -x "$SCREEN_SESSION_NAME"
}

function kvm_monitor ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	MONITOR_FILE="$MONITOR_DIR/$VM_NAME.unix"
	! test_socket_rw "$MONITOR_FILE" && fail_exit "Error : could not open monitor socket $MONITOR_FILE."
	echo "Attaching monitor unix socket (using socat). Press ^D (EOF) to exit"
	socat READLINE unix:"$MONITOR_FILE"
	echo "Monitor exited"
}

function kvm_serial ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	! test_file "$PID_FILE" && fail_exit "Error : $VM_NAME doesn't seem to be running."
	SERIAL_FILE="$SERIAL_DIR/$VM_NAME.unix"
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
		VM_NAME=`basename "${file%"-vm"}"`
		local VM_STATUS="Halted"
		PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
		test_file "$PID_FILE" && VM_STATUS="Running"
		echo -e "$VM_STATUS\t\t$VM_NAME"
	done
}

function kvm_edit_descriptor ()
{
	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
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
		local HDA_LINE="KVM_HDA=\"$KVM_IMG_DISKNAME\""
		sed -i "s,##KVM_HDA,$HDA_LINE,g" "$VM_DESCRIPTOR"
	fi
	local MAC_ADDR="`random_mac`"
	sed -i 's/`random_mac`/'"$MAC_ADDR/g" "$VM_DESCRIPTOR"
	sed -i 's/#KVM_MAC/KVM_MAC/g' "$VM_DESCRIPTOR"

	echo "VM $VM_NAME created. Descriptor : $VM_DESCRIPTOR"
}

function kvm_bootstrap_vm ()
{

	cleanup()
	{
		if [ ${#CLEANUP[*]} -gt 0 ]; then
			LAST_ELEMENT=$((${#CLEANUP[*]}-1))
			for i in `seq $LAST_ELEMENT -1 0`; do
				eval ${CLEANUP[$i]}
			done
		fi
	}

	local CLEANUP=( )

	set +e
	trap cleanup EXIT

	require_exec "kpartx"
	check_create_dir "$BOOT_IMAGES_DIR"
	check_create_dir "$CACHE_DIR"

	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file_rw "$VM_DESCRIPTOR" || fail_exit "Couldn't read/write VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"

	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	test_file "$PID_FILE" && fail_exit "Error : $VM_NAME seems to be running. Please stop it before trying to bootstrap it."

	if [[ -n "$2" ]]; then
		BOOTSTRAP_DISTRIB="$2"   # The variable is already set in the config file otherwise.
	fi
	BOOTSTRAP_SCRIPT="$BOOTSTRAP_DIR/$BOOTSTRAP_DISTRIB/bootstrap.sh"
	test_file "$BOOTSTRAP_SCRIPT" || fail_exit "Couldn't read $BOOTSTRAP_SCRIPT to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB"
	source "$BOOTSTRAP_SCRIPT"
	
	#test_blockdev "$BOOTSTRAP_DEVICE" || fail_exit "Sorry, kvm-wrapper can only bootstrap blockdevices yet."
	if ! test_blockdev "$KVM_HDA"
	then
		require_exec "$KVM_NBD_BIN"
		test_file "$KVM_HDA" || fail_exit ""$KVM_HDA" appears to be neither a blockdev nor a regular file."
		echo "Attempting to connect the disk image to an nbd device."
		kvm_nbd_connect "$KVM_HDA"
		local BOOTSTRAP_DEVICE=$(nbd_img_link "$KVM_HDA")
	else
		local BOOTSTRAP_DEVICE="$KVM_HDA"
	fi

	echo "Starting to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB on disk $KVM_HDA"
	bootstrap_fs "$BOOTSTRAP_DEVICE"
	sync
	test_blockdev "$KVM_HDA" || kvm_nbd_disconnect "$KVM_HDA"

	cleanup
	trap - EXIT
	set -e

	echo "Bootstrap ended."
	return 0
}

function kvm_build_vm ()
{

	local USER_OPTIONS=( )

	while [[ "$#" -gt 1 ]]; do
		case "$1" in
			"-s"|"--size")
				USER_OPTIONS+=("LVM_LV_SIZE")
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

	if [[ -n "$EDIT_CONF" ]]; then
		kvm_edit_descriptor "$VM_NAME"
	fi

	if [ ${#USER_OPTIONS[*]} -gt 0 ]; then
		LAST_ELEMENT=$((${#USER_OPTIONS[*]}-2))
		for i in `seq 0 2 $LAST_ELEMENT`; do
			desc_update_setting "${USER_OPTIONS[$i]}" "${USER_OPTIONS[$((i+1))]}"
		done
	fi

	lvm_create_disk "$VM_NAME"
	kvm_bootstrap_vm "$VM_NAME"

	echo "Will now start VM $VM_NAME"
	kvm_start_screen "$VM_NAME"
	sleep 1
	kvm_attach_screen "$VM_NAME"
}

function kvm_remove ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	test_file "$PID_FILE" && fail_exit "Error : $VM_NAME seems to be running. Please stop it before trying to remove it."

	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file_rw "$VM_DESCRIPTOR" || fail_exit "Couldn't read/write VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"

	local DRIVES_LIST=""
	[[ -n "$KVM_HDA" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDA\n"
	[[ -n "$KVM_HDB" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDB\n"
	[[ -n "$KVM_HDC" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDC\n"
	[[ -n "$KVM_HDD" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDD\n"
	if [[ -n "$DRIVES_LIST" ]]; then
		echo "The VM $VM_NAME used the following disks (NOT removed by $SCRIPT_NAME) :"
		echo -e "$DRIVES_LIST"
	fi
	rm -f "$VM_DESCRIPTOR"
	test_file "$VM_DESCRIPTOR" && fail_exit "Failed to remove descriptor $VM_DSCRIPTOR."
}

function print_help ()
{
	echo -e "Usage: $SCRIPT_NAME {start|screen|stop} virtual-machine"
	echo -e "       $SCRIPT_NAME {attach|monitor|serial} virtual-machine"
	echo -e "       $SCRIPT_NAME rundisk disk-image"
	echo -e ""
	echo -e "       $SCRIPT_NAME status [virtual-machine]"
	echo -e "       $SCRIPT_NAME list"
	echo
	echo -e "		$SCRIPT_NAME create	[-m mem] [-c cpu] [--edit] [-s disksize] virtual-machine"
	echo -e "       $SCRIPT_NAME create-disk virtual-machine [diskimage [size]]"
	echo -e "       $SCRIPT_NAME bootstrap   virtual-machine distribution"
	echo -e "       $SCRIPT_NAME remove virtual-machine"
	echo -e "       $SCRIPT_NAME edit  virtual-machine"
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

# Check VM descriptor directory
test_dir "$VM_DIR" || fail_exit "Couldn't open VM descriptor directory :\n$VM_DIR"

# Argument parsing
case "$1" in
	list)
		kvm_list
		;;
	start)
		if [[ $# -eq 2 ]]; then
		    kvm_start_vm "$2"
		else print_help; fi
		;;
	screen)
		if [[ $# -eq 2 ]]; then
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
	rundisk)
		if [[ $# -eq 2 ]]; then
		    kvm_run_disk "$2"
		else print_help; fi
		;;
	status)
        if [[ -n "$2" ]]; then 
            kvm_status "$2"
        else kvm_status "all"; fi
		;;
	edit)
		if [[ $# -eq 2 ]]; then
		    kvm_edit_descriptor "$2"
		else print_help; fi
		;;
	create-desc*)
		if [[ $# -ge 2 ]]; then
			kvm_create_descriptor "$2" "$3" "$4"
		else print_help; fi
		;;
	create|build)
		if [[ $# -ge 2 ]]; then
			shift
			kvm_build_vm $@
		else print_help; fi
		;;
	remove)
		if [[ $# -eq 2 ]]; then
		    kvm_remove "$2"
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
	*)
		print_help
		;;
esac


