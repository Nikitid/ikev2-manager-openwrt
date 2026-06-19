#!/bin/sh

lock_dir='/var/run/ikev2-domains-pbr-restart.lock'
global_lock_dir='/var/run/ikev2-action.lock'
global_lock_status='/var/run/ikev2-action.lock.status'
log_file='/tmp/ikev2-domains-pbr-restart.log'

(
	sleep 1

	# Serialize this restart with Overview/server/client actions. Wait instead of
	# failing: the UI has already saved the requested policy change.
	tries=0
	while ! mkdir "$global_lock_dir" 2>/dev/null; do
		pid="$(sed -n 's/^pid=//p' "$global_lock_status" 2>/dev/null | tail -1)"
		if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$global_lock_status"
			rmdir "$global_lock_dir" 2>/dev/null || true
			continue
		fi
		tries=$((tries + 1))
		[ "$tries" -lt 180 ] || exit 1
		sleep 1
	done
	printf 'owner=pbr-restart\npid=%s\nupdated=%s\n' "$$" "$(date +%s)" >"$global_lock_status"

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
		# pbr restart empties the fw4 forward chain (drops all LAN->WAN) while
		# the kill-switch include is present; reload immediately to restore it.
		fw4 -q reload
		sleep 2
		/etc/init.d/ikev2-xfrm start
		/usr/libexec/ikev2-sync-vips
		/usr/share/pbr/pbr.user.ikev2out
	} >"$log_file" 2>&1
) </dev/null >/dev/null 2>&1 &

exit 0
