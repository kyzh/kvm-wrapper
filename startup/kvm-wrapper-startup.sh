#!/bin/sh

# kvm-wrapper startup init script
# This scripts starts/stops a list a VMs using the kvm-wrapper script
# -- bencoh, 2009/08/11

SCRIPTNAME=/etc/init.d/kvm-wrapper

. /lib/lsb/init-functions

KVM_WRAPPER_DIR=/usr/share/kvm-wrapper
KVM_WRAPPER="$KVM_WRAPPER_DIR"/kvm-wrapper.sh
KVM_VM_LIST="$KVM_WRAPPER_DIR"/startup/startup-list

start_vm()
{
	VM_NAME="$1"
	log_begin_msg "Starting up VM : $VM_NAME ..."
	$KVM_WRAPPER screen "$VM_NAME"
	EXITNUM="$?"
	echo $EXITNUM
	case "$EXITNUM" in 
		0) log_end_msg 0 ;;
		*) log_end_msg 1 ;;
	esac
	return 0
}

do_start()
{
grep -E -v '^#' "$KVM_VM_LIST" |
while read line
do
	start_vm "$line"
done
}

do_stop()
{
grep -E -v '^#' "$KVM_VM_LIST" |
while read line
do
	VM_NAME="$line"
	log_begin_msg "Stopping VM : $VM_NAME ..."
	"$KVM_WRAPPER" stop "$VM_NAME"
	log_end_msg 0
done
}

case "$1" in
  start)
	log_begin_msg "Autostarting VMs (kvm-wrapper) ..."
	do_start
	case "$?" in
		0|1) log_end_msg 0 ;;
		2) log_end_msg 1 ;;
	esac
	;;
  stop)
	log_begin_msg "Shutting down autostarted VMs (kvm-wrapper) ..."
	do_stop
	case "$?" in
		0|1) log_end_msg 0 ;;
		2) log_end_msg 1 ;;
	esac
	;;
  restart|force-reload)
	;;
  start-vm)
  	start_vm "$2"
	;;
  *)
	echo "Usage: $SCRIPTNAME {start|stop}" >&2
	echo "       $SCRIPTNAME start-vm xxxxx" >&2
	exit 3
	;;
esac

