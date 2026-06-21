#!/bin/sh

status_file='/var/run/ikev2-health.status'
volatile_set_dump='/var/run/pbr-ikev2-set4.dump'
persistent_set_dump='/etc/ikev2-manager/pbr-set4.dump'
probe_state='/var/run/ikev2-health-probe.state'
recovery_stamp='/var/run/ikev2-health-recovery.last'
probe_interval=60
probe_fail_limit=2

has_proxy4() {
	printf '%s' "$1" | grep -q 'name=proxy4[^{}]* state=INSTALLED'
}

tunnel_probe() {
	curl -4fsS --interface ipsec-out \
		--connect-timeout 4 --max-time 8 \
		https://1.1.1.1/cdn-cgi/trace 2>/dev/null |
		grep -q '^ip=[0-9]'
}

probe_due() {
	now="$1"
	last="$(sed -n 's/^last=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$probe_interval" ]
}

probe_failures() {
	value="$(sed -n 's/^failures=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

save_probe() {
	{
		printf 'last=%s\n' "$1"
		printf 'failures=%s\n' "$2"
	} >"${probe_state}.new"
	mv "${probe_state}.new" "$probe_state"
}

recover_stale_tunnel() {
	now="$1"
	cooldown="$(uci -q get ikev2-manager.client.reconnect_cooldown || echo 15)"
	case "$cooldown" in '' | *[!0-9]*) cooldown=15 ;; esac
	last="$(cat "$recovery_stamp" 2>/dev/null || echo 0)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$cooldown" ] || return 0
	[ ! -d /var/run/ikev2-action.lock ] || return 0
	printf '%s\n' "$now" >"$recovery_stamp"
	/usr/libexec/ikev2-manager reconnect-client >/dev/null 2>&1 || :
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
	dump="$volatile_set_dump"
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

persist_pbr_sets() {
	dump_pbr_sets
	[ -s "$volatile_set_dump" ] || return 0
	mkdir -p "${persistent_set_dump%/*}"
	cp "$volatile_set_dump" "${persistent_set_dump}.new"
	chmod 600 "${persistent_set_dump}.new"
	mv "${persistent_set_dump}.new" "$persistent_set_dump"
}

# Persist once during an orderly reboot/service stop. Keeping the hot runtime
# dump in /var/run avoids flash writes every 15 seconds, while the shutdown
# snapshot lets warm client DNS caches survive the next boot without leaking.
trap 'persist_pbr_sets; exit 0' INT TERM

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

	# strongSwan normally owns reconnects. Its boot-time start_action can run
	# before WAN is usable, however, and that initial failure is not reliably
	# retried. ensure-client is idempotent, locked and rate-limited, so the
	# watcher safely fills that gap without racing manual actions or hotplug.
	if [ "$client_enabled" = 1 ] && ! has_proxy4 "$raw"; then
		/usr/libexec/ikev2-manager ensure-client >/dev/null 2>&1 || :
		raw="$(swanctl --list-sas --raw 2>/dev/null || true)"
	fi

	if [ "$client_enabled" = 1 ] && has_proxy4 "$raw"; then
		if /usr/libexec/ikev2-sync-vips &&
			/usr/share/pbr/pbr.user.ikev2out; then
			now="$(date +%s)"
			failures="$(probe_failures)"
			if probe_due "$now"; then
				if tunnel_probe; then
					failures=0
				else
					failures=$((failures + 1))
				fi
				save_probe "$now" "$failures"
			fi
			if [ "$failures" -ge "$probe_fail_limit" ]; then
				printf 'state=degraded updated=%s probe_failures=%s\n' \
					"$now" "$failures" >"$status_file"
				recover_stale_tunnel "$now"
				save_probe "$now" 0
			else
				printf 'state=up updated=%s probe_failures=%s\n' \
					"$now" "$failures" >"$status_file"
			fi
		else
			printf 'state=degraded updated=%s\n' "$(date +%s)" >"$status_file"
		fi
	elif [ "$client_enabled" = 1 ]; then
		rm -f "$probe_state"
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
	sleep 15
done
