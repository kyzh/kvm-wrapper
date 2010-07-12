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

# File/socket/directory tester
function test_dir ()
{
	DIR="$1"
	[[ -d "$DIR" && -r "$DIR" ]]
}

function test_dir_rw ()
{
	DIR="$1"
	[[ -d "$DIR" && -r "$DIR" && -w "$DIR" ]]
}

function test_file ()
{
	FILE="$1"
	[[ -f "$FILE" && -r "$FILE" ]]
}

function test_file_rw ()
{
	FILE="$1"
	[[ -f "$FILE" && -r "$FILE" && -w "$FILE" ]]
}

function test_socket ()
{
	FILE="$1"
	[[ -S "$FILE" && -r "$FILE" ]]
}

function test_socket_rw ()
{
	FILE="$1"
	[[ -S "$FILE" && -r "$FILE" && -w "$FILE" ]]
}

function check_create_dir ()
{
	DIR="$1"
	test_dir_rw "$DIR" || mkdir -p "$DIR"
	test_dir_rw "$DIR" || fail_exit "Couldn't read/write VM PID directory :\n$DIR"
}

function random_mac ()
{
# Macaddress : 52:54:00:ff:34:56
RANGE=99
STR=""
for blah in 0 1
do
	number=$RANDOM
	let "number %= $RANGE"
	STR="$STR"":""$number"
done
MACADDRESS="52:54:00:ff""$STR"
echo -ne $MACADDRESS
}

function bs_copy_from_host()
{
	FILE="$1"
	cp -rf "$FILE" "$MNTDIR/$FILE"
}

# Update (if exists) descriptor setting and keep a backup, create otherwise
function desc_update_backup_setting ()
{
	KEY="$1"
	VALUE="$2"
	IDENT=$RANDOM

	#sed -i "s/^$KEY.*/#\0 ###AUTO$IDENT\n$KEY=$(escape_sed "\"$VALUE\"") ###AUTO$IDENT/g" "$VM_DESCRIPTOR"
	sed -i "s/^$KEY.*/#\0 ###AUTO$IDENT/g" "$VM_DESCRIPTOR"
	echo "$KEY=\"$VALUE\" ###AUTO$IDENT" >> "$VM_DESCRIPTOR"

	echo $IDENT
}

# Overwrite (or create) descriptor setting
function desc_update_setting ()
{
	KEY="$1"
	VALUE="$2"

	#sed -i "s/^$KEY.*/$KEY=$(escape_sed "\"$VALUE\"") ###AUTO/g" "$VM_DESCRIPTOR"
	sed -i "/^$KEY.*/d" "$VM_DESCRIPTOR"
	echo "$KEY=\"$VALUE\" ###AUTO" >> "$VM_DESCRIPTOR"
}

# Revert descriptor setting modified by this script
function desc_revert_setting()
{
	IDENT=$1
	sed -i "/^[^#].*###AUTO$IDENT$/d" "$VM_DESCRIPTOR"
	sed -ie "s/^#\(.*\)###AUTO$IDENT$/\1/g" "$VM_DESCRIPTOR"
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
	VM_PID=`cat "$1"`
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

	# Build KVM Drives (hdd, cdrom) parameters
	KVM_DRIVES=""
	[[ -n "$KVM_HDA" ]] && KVM_DRIVES="$KVM_DRIVES -hda $KVM_HDA"
	[[ -n "$KVM_HDB" ]] && KVM_DRIVES="$KVM_DRIVES -hdb $KVM_HDB"
	[[ -n "$KVM_HDC" ]] && KVM_DRIVES="$KVM_DRIVES -hdc $KVM_HDC"
	[[ -n "$KVM_HDD" ]] && KVM_DRIVES="$KVM_DRIVES -hdd $KVM_HDD"
	[[ -n "$KVM_CDROM" ]] && KVM_DRIVES="$KVM_DRIVES -cdrom $KVM_CDROM"
	[[ "$KVM_DRIVES" == "" ]] && fail_exit "Your VM $VM_NAME should at least use one cdrom or harddisk drive !\nPlease check your conf file :\n$VM_DESCRIPTOR"
	LINUXBOOT=""
	[[ -n "$KVM_KERNEL" ]] && LINUXBOOT="$LINUXBOOT -kernel $KVM_KERNEL"
	[[ -n "$KVM_INITRD" ]] && LINUXBOOT="$LINUXBOOT -initrd $KVM_INITRD"
	[[ -n "$KVM_APPEND" ]] && LINUXBOOT="$LINUXBOOT -append \"$KVM_APPEND\""

	# Are we bridged or nated ? (default nated)
	KVM_NET_TAP="tap"
	KVM_NET_SCRIPT="$ROOTDIR/net/kvm"
	[[ "$KVM_BRIDGE" == "br0" ]] && KVM_NET_SCRIPT="$ROOTDIR/net/kvm-br0"
	KVM_NET_TAP="tap,script=$KVM_NET_SCRIPT-ifup,downscript=$KVM_NET_SCRIPT-ifdown"

	# Monitor/serial devices
	KVM_MONITORDEV="-monitor unix:$MONITOR_FILE,server,nowait"
	KVM_SERIALDEV="-serial unix:$SERIAL_FILE,server,nowait"

	# Build kvm exec string
	EXEC_STRING="$KVM_BIN -m $KVM_MEM -smp $KVM_CPU_NUM -net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net $KVM_NET_TAP $KVM_DRIVES -boot $KVM_BOOTDEVICE -k $KVM_KEYMAP $KVM_OUTPUT $LINUXBOOT $KVM_MONITORDEV $KVM_SERIALDEV -pidfile $PID_FILE $KVM_ADDITIONNAL_PARAMS"

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
#	test_file_rw "$MONITOR_FILE" || fail_exit "Monitor socket $MONITOR_FILE not existing or not writable"

	TIMELIMIT=30

	# Send monitor command through unix socket
	echo "Trying to powerdown the VM $VM_NAME first, might take some time (up to $TIMELIMIT sec)"
	echo "system_powerdown" | socat - unix:"$MONITOR_FILE"
	echo -n "Waiting ..."

	# Now wait for it
	ELAPSED=0
	while [[ $ELAPSED -le $TIMELIMIT ]]
	do
		ELAPSED=$(($ELAPSED+1))
		! test_file "$PID_FILE" && PROPER=1;
		[[ $PROPER -eq 1 ]] && break
		sleep 1
	done
	echo " elapsed time : $ELAPSED sec"

	if [[ $PROPER -eq 1 ]];
	then
		echo "VM powerdown properly :)"
	else
	
		# kill - SIGTERM
		KVM_PID="`cat $PID_FILE`"
		echo "Now trying to terminate (SIGTERM) $VM_NAME, pid $KVM_PID"
		kill "$KVM_PID"
	fi

	rm -rf "$PID_FILE" || fail_exit "Couldn't remove pid file"
	
	return 0
}

function kvm_run_disk ()
{
	KVM_HDA="$1"
	test_file_rw "$KVM_HDA" || "Couldn't read/write image file :\n$KVM_HDA"

	# Build kvm exec string
	EXEC_STRING="kvm -net nic,model=$KVM_NETWORK_MODEL,macaddr=$KVM_MACADDRESS -net tap -hda $KVM_HDA -boot c -k $KVM_KEYMAP $KVM_OUTPUT $KVM_ADDITIONNAL_PARAMS"
	$EXEC_STRING

	return 0
}

function kvm_start_screen ()
{
	VM_NAME="$1"
	SCREEN_SESSION_NAME="kvm-$VM_NAME"
	screen -d -m -S "$SCREEN_SESSION_NAME" /bin/sh -c "\"$SCRIPT_PATH\" start \"$VM_NAME\""
	EXITNUM="$?"
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
	socat - unix:"$MONITOR_FILE"
	echo "Monitor exited"
}

function kvm_serial ()
{
	VM_NAME="$1"
	PID_FILE="$PID_DIR/$VM_NAME-vm.pid"
	! [[ -f "$PID_FILE" ]] && fail_exit "Error : $VM_NAME doesn't seem to be running."
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
		VM_STATUS="Halted"
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
	if [[ $# -ge 2 ]]
	then
		[[ ! -x "$KVM_IMG_BIN" ]] && fail_exit "kvm-img not found or not executable"
		KVM_IMG_DISKNAME="`canonpath \"$2\"`"
	fi
	if [[ $# -eq 2 ]]
	then
		DISK_CREATED=1
	fi
	if [[ $# -eq 3 ]]
	then
		echo "Calling kvm-img to create disk image"
		KVM_IMG_DISKSIZE="$3"
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

	foo=`grep -n '#xxDEFAULTxx#' "$CONFFILE"`
	foo=${foo%:*}
	
	cat "$CONFFILE" | while read LINE
	do
		[[ $foo -lt 0 ]] && echo "#$LINE" >> "$VM_DESCRIPTOR"
		((foo--))
	done

	if [[ "xx$DISK_CREATED" == "xx1" ]]
	then
		HDA_LINE="KVM_HDA=\"$KVM_IMG_DISKNAME\""
		sed -i "s,##KVM_HDA,$HDA_LINE,g" "$VM_DESCRIPTOR"
	fi
	MAC_ADDR="`random_mac`"
	sed -i 's/`random_mac`/'"$MAC_ADDR/g" "$VM_DESCRIPTOR"
	sed -i 's/#KVM_MAC/KVM_MAC/g' "$VM_DESCRIPTOR"

	echo "VM $VM_NAME created. Descriptor : $VM_DESCRIPTOR"
}

function kvm_bootstrap_vm ()
{
	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file_rw "$VM_DESCRIPTOR" || fail_exit "Couldn't read/write VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"

	test_file "$PID_FILE" || fail_exit "Error : $VM_NAME seems to be running. Please stop it before trying to bootstrap it."

	BOOTSTRAP_DISTRIB="$2"
	BOOTSTRAP_SCRIPT="$BOOTSTRAP_DIR/$BOOTSTRAP_DISTRIB/bootstrap.sh"
	test_file "$BOOTSTRAP_SCRIPT" || fail_exit "Couldn't read $BOOTSTRAP_SCRIPT to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB"
	source "$BOOTSTRAP_SCRIPT"
	
	# Start bootstrap
	echo "Starting to bootstrap $VM_NAME as $BOOTSTRAP_DISTRIB on disk $KVM_HDA"
	bootstrap_fs "$KVM_HDA"
	echo "Bootstrap ended."
	return 0

}

function kvm_remove ()
{
	VM_NAME="$1"
	VM_DESCRIPTOR="$VM_DIR/$VM_NAME-vm"
	test_file_rw "$VM_DESCRIPTOR" || fail_exit "Couldn't read/write VM $VM_NAME descriptor :\n$VM_DESCRIPTOR"
	source "$VM_DESCRIPTOR"
	DRIVES_LIST=""
	[[ -n "$KVM_HDA" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDA\n"
	[[ -n "$KVM_HDB" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDB\n"
	[[ -n "$KVM_HDC" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDC\n"
	[[ -n "$KVM_HDD" ]] && DRIVES_LIST="$DRIVES_LIST$KVM_HDD\n"
	if [[ -n "$DRIVES_LIST" ]]; then
		echo "The VM $VM_NAME used the following disks (NOT removed by $SCRIPT_NAME :"
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
	echo -e ""
	echo -e "       $SCRIPT_NAME edit   virtual-machine"
	echo -e "       $SCRIPT_NAME create virtual-machine [diskimage] [size]"
	echo -e "       $SCRIPT_NAME remove virtual-machine"
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

# Check arguments number
if [[ $# -eq 1 ]]
then
	case "$1" in
		status)
		  kvm_status "all"
		  ;;
		list)
		  kvm_list
		  ;;
		*)
		  print_help
		  ;;
	esac
elif [[ $# -eq 2 ]]
then
	case "$1" in
		start)
		  kvm_start_vm "$2"
		  ;;
		screen)
		  kvm_start_screen "$2"
		  ;;
		attach)
		  kvm_attach_screen "$2"
		  ;;
		monitor)
		  kvm_monitor "$2"
		  ;;
		serial)
		  kvm_serial "$2"
		  ;;
		stop)
		  kvm_stop_vm "$2"
		  ;;
		rundisk)
		  kvm_run_disk "$2"
		  ;;
		status)
		  kvm_status "$2"
		  ;;
		edit)
		  kvm_edit_descriptor "$2"
		  ;;
		create)
		  kvm_create_descriptor "$2"
		  ;;
		remove)
		  kvm_remove "$2"
		  ;;
		*)
		  print_help
		  ;;
	esac
elif [[ $# -eq 3 ]]
then
	case "$1" in
		create)
		  kvm_create_descriptor "$2" "$3"
		  ;;
		bootstrap)
		  kvm_bootstrap_vm "$2" "$3"
		  ;;
		*)
		  print_help
		  ;;
	esac

elif [[ $# -eq 4 ]]
then
	case "$1" in
		create)
		  kvm_create_descriptor "$2" "$3" "$4"
		  ;;
		*)
		  print_help
		  ;;
	esac
else
	print_help
fi
