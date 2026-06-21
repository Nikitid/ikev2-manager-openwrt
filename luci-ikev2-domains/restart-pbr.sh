#!/bin/sh

lock_dir='/var/run/ikev2-domains-pbr-restart.lock'
global_lock_dir='/var/run/ikev2-action.lock'
global_lock_status='/var/run/ikev2-action.lock.status'
log_file='/tmp/ikev2-domains-pbr-restart.log'
action_lock_dir="$global_lock_dir"
action_lock_status="$global_lock_status"

. /usr/libexec/ikev2-manager.d/actions.sh
. /usr/libexec/ikev2-manager.d/routing.sh

drop_reclassified_connections() {
	command -v conntrack >/dev/null 2>&1 || return 0
	set_name="$(nft list table inet fw4 2>/dev/null |
		sed -n 's/^[[:space:]]*set \(pbr_ikev2out_4_dst_ip_[^[:space:]]*\) {.*/\1/p' |
		grep -v '_user$' | head -n1)"
	if [ -n "$set_name" ]; then
		# Existing flow-offloaded sessions retain their old WAN route after a
		# domain is newly classified. Drop only sessions whose destination now
		# belongs to the managed PBR set so their next connection is re-evaluated.
		conntrack -L 2>/dev/null |
			awk '{
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^src=/) {
						for (j = i + 1; j <= NF; j++) {
							if ($j ~ /^dst=/) {
								sub(/^dst=/, "", $j)
								print $j
								next
							}
						}
					}
				}
			}' |
			sort -u |
			while IFS= read -r address; do
				[ -n "$address" ] || continue
				if nft get element inet fw4 "$set_name" "{ $address }" >/dev/null 2>&1; then
					conntrack -D -d "$address" >/dev/null 2>&1 || :
				fi
			done
	fi

	if [ -r /etc/pbr-ikev2-service-cidrs.txt ]; then
		while IFS= read -r cidr; do
			[ -n "$cidr" ] || continue
			conntrack -D -d "$cidr" >/dev/null 2>&1 || :
		done </etc/pbr-ikev2-service-cidrs.txt
	fi
}

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
		/usr/libexec/ikev2-manager-system _sync-pbr
		if [ "$(uci -q get ikev2-manager.domains.engine)" = fakeip ] &&
		   [ -x /usr/libexec/ikev2-domain-router ]; then
			/usr/libexec/ikev2-domain-router refresh
		fi
		/etc/init.d/ikev2-xfrm start
		/usr/libexec/ikev2-sync-vips
		/etc/init.d/pbr restart
		/etc/init.d/pbr running
		/usr/libexec/ikev2-manager-system failclosed-check
		ensure_forward_chain
		/etc/init.d/ikev2-xfrm start
		/usr/libexec/ikev2-sync-vips
		/usr/share/pbr/pbr.user.ikev2out
		drop_reclassified_connections
	} >"$log_file" 2>&1
) </dev/null >/dev/null 2>&1 &

exit 0
