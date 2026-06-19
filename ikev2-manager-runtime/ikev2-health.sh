#!/bin/sh

status_file='/var/run/ikev2-health.status'

has_proxy4() {
	printf '%s' "$1" | grep -q 'name=proxy4[^{}]* state=INSTALLED'
}

domain_set_name() {
	nft list table inet fw4 2>/dev/null |
		sed -n 's/^[[:space:]]*set \(pbr_ikev2out_4_dst_ip_[^[:space:]]*\) {.*/\1/p' |
		grep -v '_user$' | head -n1
}

# Persist the PBR domain set so pbr.user.ikev2out can restore it after a
# firewall/pbr restart. Without this, clients with warm DNS caches leak the
# selected domains straight to WAN until dnsmasq repopulates the set. IPv4
# only: the outbound tunnel is v4-only, the v6 set is never populated.
dump_pbr_sets() {
	set_name="$(domain_set_name)"
	[ -n "$set_name" ] || return 0
	dump="/var/run/pbr-ikev2-set4.dump"
	nft list set inet fw4 "$set_name" 2>/dev/null |
		sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
		sed 's/.*{//; s/}.*//' | tr ',' '\n' |
		tr -d ' ' | grep -v '^$' >"${dump}.new" || :
	if [ -s "${dump}.new" ]; then
		mv "${dump}.new" "$dump"
	else
		rm -f "${dump}.new"
	fi
}

while true; do
	if [ "$(uci -q get ikev2-manager.globals.configured)" != 1 ] &&
		! ip link show ipsec-out >/dev/null 2>&1; then
		printf 'state=disabled updated=%s\n' "$(date +%s)" >"$status_file"
		sleep 60
		continue
	fi

	/etc/init.d/ikev2-xfrm start

	client_enabled="$(uci -q get ikev2-manager.client.enabled || echo 0)"
	raw="$(swanctl --list-sas --raw 2>/dev/null || true)"
	if [ "$client_enabled" != 1 ]; then
		rm -f /var/run/ikev2-vip4
		/usr/share/pbr/pbr.user.ikev2out || :
		printf 'state=client-disabled updated=%s\n' "$(date +%s)" >"$status_file"
	fi

	# strongSwan owns reconnection through start_action, close_action,
	# dpd_action and retry_initiate_interval. The health watcher only observes
	# and repairs derived state, avoiding concurrent initiations.
	if [ "$client_enabled" = 1 ] && has_proxy4 "$raw"; then
		if /usr/libexec/ikev2-sync-vips &&
			/usr/share/pbr/pbr.user.ikev2out; then
			printf 'state=up updated=%s\n' "$(date +%s)" >"$status_file"
		else
			printf 'state=degraded updated=%s\n' "$(date +%s)" >"$status_file"
		fi
	elif [ "$client_enabled" = 1 ]; then
		rm -f /var/run/ikev2-vip4
		/usr/share/pbr/pbr.user.ikev2out || :
		printf 'state=down updated=%s\n' "$(date +%s)" >"$status_file"
	fi

	# Self-heal the inbound server if it drifted: enabled in config but the
	# ikev2-in connection is not loaded into charon (e.g. strongSwan reinstall
	# cleared /etc/swanctl, or a partial swanctl reload left the pool/cert
	# unloaded). server-ensure re-syncs the cert and reloads; it is a no-op when
	# already healthy, so this only acts when the server is actually broken.
	if [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ] &&
		! swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:'; then
		/usr/libexec/ikev2-manager server-ensure >/dev/null 2>&1 || :
	fi

	dump_pbr_sets
	sleep 30
done
