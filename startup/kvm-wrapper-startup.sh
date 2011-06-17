#!/bin/bash
### BEGIN INIT INFO
# Provides:          kvm-wrapper
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: kcm-wrapper init script
# Description:       This script starts a list of VMs and stops the running
#                    ones when asked to
### END INIT INFO

# -- bencoh, 2009/08/11
# -- Asmadeus, 2011/06

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

stop_vm ()
{
	VM_NAME="$1"
	log_begin_msg "Stopping VM : $VM_NAME ..."
	"$KVM_WRAPPER" stop "$VM_NAME"
	log_end_msg 0
}

do_start()
{
if [[ ! -f /usr/share/kvm-wrapper/kvm-wrapper.sh ]]; then
	log_begin_msg "Mounting /usr/share/kvm-wrapper since it doesn't seem here"
	echo
	mount /usr/share/kvm-wrapper
	sleep 3
fi

echo cleaning old pid files for `hostname -s`
rm -vf /usr/share/kvm-wrapper/run/`hostname -s`*

grep -E -v '^#' "$KVM_VM_LIST" |
while read line
do
	pcregrep "^KVM_CLUSTER_NODE=\"?`hostname -s`" $KVM_WRAPPER_DIR/vm/$line-vm >&/dev/null && \
	start_vm "$line"
done
}

do_stop()
{
"$KVM_WRAPPER" list|pcregrep "Running\ton (`hostname -s`|local)"|awk '{print $1}'|
while read line
do
	stop_vm "$line"
done
}

case "$1" in
  start)
	log_begin_msg "Autostarting VMs (kvm-wrapper) ..."
	echo
	do_start
	case "$?" in
		0|1) log_end_msg 0 ;;
		2) log_end_msg 1 ;;
	esac
	;;
  stop)
	log_begin_msg "Shutting down autostarted VMs (kvm-wrapper) ..."
	echo
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

