#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/state"
: >"$tmp/state/app"
printf '%s\n' '@br-lan 192.168.1.50' >"$tmp/state/pbr-src"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
set -eu
while [ "${1:-}" = -q ]; do shift; done
command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$command" in
	get)
		case "${1:-}" in
			ikev2-manager.domains.device_source) [ -s "$TEST_STATE/app" ] && cat "$TEST_STATE/app" ;;
			pbr.ikev2pbr_domains.src_addr) cat "$TEST_STATE/pbr-src" ;;
			firewall.@zone\[0\].name) printf '%s\n' lan ;;
			firewall.@zone\[0\].network) printf '%s\n' 'lan iot' ;;
			firewall.@zone\[1\].name) printf '%s\n' wan ;;
			firewall.@zone\[1\].network) printf '%s\n' wan ;;
			*) exit 1 ;;
		esac
		;;
	export)
		case "${1:-}" in
			pbr) cat "$TEST_STATE/pbr-src" ;;
			ikev2-manager) cat "$TEST_STATE/app" ;;
			*) exit 1 ;;
		esac
		;;
	import)
		case "${1:-}" in
			pbr) cat >"$TEST_STATE/pbr-src" ;;
			ikev2-manager) cat >"$TEST_STATE/app" ;;
			*) exit 1 ;;
		esac
		;;
	delete)
		[ "${1:-}" = ikev2-manager.domains.device_source ] && : >"$TEST_STATE/app"
		;;
	add_list)
		value="${1#ikev2-manager.domains.device_source=}"
		current="$(cat "$TEST_STATE/app")"
		printf '%s\n' "${current:+$current }$value" >"$TEST_STATE/app"
		;;
	commit | reorder | set) ;;
	show)
		[ "${1:-}" = firewall ] && printf '%s\n' \
			'firewall.@zone[0]=zone' 'firewall.@zone[1]=zone'
		;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in
	192.168.1.* | 192.168.1.*/32) exit 0 ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/restart" <<'EOF'
#!/bin/sh
[ "${TEST_RESTART_FAIL:-0}" != 1 ]
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 route show default') printf '%s\n' 'default via 198.51.100.1 dev eth1' ;;
	'-4 neigh show')
		printf '%s\n' \
			'198.51.100.1 dev eth1 lladdr 00:00:5e:00:01:01 REACHABLE' \
			'192.168.1.50 dev br-lan lladdr 02:00:00:00:00:50 REACHABLE' \
			'192.168.1.51 dev br-lan FAILED'
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ipcalc.sh" "$tmp/bin/restart"
chmod 755 "$tmp/bin/ip"
printf '%s\n' '0 02:00:00:00:00:50 192.168.1.50 laptop *' >"$tmp/state/dhcp.leases"

run_device() {
	PATH="$tmp/bin:$PATH" TEST_STATE="$tmp/state" \
	IKEV2_RESTART_HELPER="$tmp/bin/restart" \
	IKEV2_DEVICE_RUNTIME_HELPER="$tmp/bin/restart" \
	IKEV2_DHCP_LEASES="$tmp/state/dhcp.leases" \
		sh "$root/luci-ikev2-domains/ikev2-devices.sh" "$@"
}

run_device dump | grep -Fxq 'addr=192.168.1.50 mode=domain'
run_device clients | grep -Fxq "192.168.1.50	laptop	02:00:00:00:00:50"
run_device zones | grep -Fxq 'lan=lan iot'
run_device zones | grep -Fxq 'wan=wan'
run_device add-subnet 192.168.1.60
[ "$(cat "$tmp/state/app")" = '192.168.1.50 192.168.1.60' ]
run_device remove-subnet 192.168.1.50
[ "$(cat "$tmp/state/app")" = '192.168.1.60' ]

if TEST_RESTART_FAIL=1 run_device add-subnet 192.168.1.70 >/dev/null 2>&1; then
	printf '%s\n' 'device update unexpectedly survived a failed PBR restart' >&2
	exit 1
fi
[ "$(cat "$tmp/state/app")" = '192.168.1.60' ]

printf '%s\n' 'device state tests OK'
