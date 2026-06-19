#!/bin/sh

lock_dir='/var/run/ikev2-domains-pbr-restart.lock'
global_lock_dir='/var/run/ikev2-action.lock'
global_lock_status='/var/run/ikev2-action.lock.status'
log_file='/tmp/ikev2-domains-pbr-restart.log'
action_lock_dir="$global_lock_dir"
action_lock_status="$global_lock_status"

. /usr/libexec/ikev2-manager.d/actions.sh
. /usr/libexec/ikev2-manager.d/routing.sh

(
	sleep 1

	# Serialize this restart with Overview/server/client actions. Wait instead of
	# failing: the UI has already saved the requested policy change.
	acquire_action_lock pbr-restart domains || exit 1

	if ! mkdir "$lock_dir" 2>/dev/null; then
		rm -f "$global_lock_status"
		rmdir "$global_lock_dir" 2>/dev/null || true
		exit 0
	fi

	trap 'rmdir "$lock_dir"; rm -f "$global_lock_status"; rmdir "$global_lock_dir" 2>/dev/null || true' EXIT
	{
		/etc/init.d/ikev2-xfrm start
		/usr/libexec/ikev2-sync-vips
		/etc/init.d/pbr restart
		/etc/init.d/pbr running
		/usr/libexec/ikev2-manager-system failclosed-check
		ensure_forward_chain
		/etc/init.d/ikev2-xfrm start
		/usr/libexec/ikev2-sync-vips
		/usr/share/pbr/pbr.user.ikev2out
	} >"$log_file" 2>&1
) </dev/null >/dev/null 2>&1 &

exit 0
