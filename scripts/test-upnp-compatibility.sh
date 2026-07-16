#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/config"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c) shift 2 ;;
		-q) shift ;;
		*) break ;;
	esac
done
[ "${1:-}" = get ] || exit 1
key="${2:-}"
case "$key" in
	upnpd.config.enabled)
		printf '%s\n' "${TEST_UPNP_ENABLED:-0}"
		;;
	'upnpd.@perm_rule[0]')
		[ -n "${TEST_RULE0_PORTS:-}" ] && printf 'perm_rule\n'
		;;
	'upnpd.@perm_rule[0].action')
		printf '%s\n' "${TEST_RULE0_ACTION:-deny}"
		;;
	'upnpd.@perm_rule[0].ext_ports')
		printf '%s\n' "${TEST_RULE0_PORTS:-}"
		;;
	'upnpd.@perm_rule[1]')
		[ -n "${TEST_RULE1_PORTS:-}" ] && printf 'perm_rule\n'
		;;
	'upnpd.@perm_rule[1].action')
		printf '%s\n' "${TEST_RULE1_ACTION:-deny}"
		;;
	'upnpd.@perm_rule[1].ext_ports')
		printf '%s\n' "${TEST_RULE1_PORTS:-}"
		;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ "${TEST_UPNP_ACTIVE:-0}" = 1 ] || {
	printf 'table inet fw4 { chain upnp_prerouting { } }\n'
	exit 0
}
printf 'table inet fw4 { chain upnp_prerouting { udp dport 4500 dnat to 192.0.2.10:4500 } }\n'
EOF

chmod 755 "$tmp/bin/uci" "$tmp/bin/nft"

run_check() {
	PATH="$tmp/bin:$PATH" \
	IKEV2_UCI_CONFIG_DIR="$tmp/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" _upnp-check
}

TEST_UPNP_ENABLED=0
TEST_UPNP_ACTIVE=0
TEST_RULE0_ACTION=''
TEST_RULE0_PORTS=''
TEST_RULE1_ACTION=''
TEST_RULE1_PORTS=''
export TEST_UPNP_ENABLED TEST_UPNP_ACTIVE TEST_RULE0_ACTION TEST_RULE0_PORTS
export TEST_RULE1_ACTION TEST_RULE1_PORTS
run_check | grep -Fq 'upnp_ikev2_ports=ok:not-enabled'

TEST_UPNP_ENABLED=1
TEST_RULE0_ACTION=allow
TEST_RULE0_PORTS=1024-65535
export TEST_UPNP_ENABLED TEST_RULE0_ACTION TEST_RULE0_PORTS
run_check | grep -Fq 'upnp_ikev2_ports=warn:UDP-4500-available-to-UPnP'

TEST_RULE0_ACTION=deny
TEST_RULE0_PORTS=4500
TEST_RULE1_ACTION=allow
TEST_RULE1_PORTS=1024-65535
export TEST_RULE0_ACTION TEST_RULE0_PORTS TEST_RULE1_ACTION TEST_RULE1_PORTS
run_check | grep -Fq 'upnp_ikev2_ports=ok:UDP-500-and-4500-reserved'

TEST_UPNP_ACTIVE=1
export TEST_UPNP_ACTIVE
if output="$(run_check 2>&1)"; then
	printf '%s\n' 'active conflicting UPnP mapping was accepted' >&2
	exit 1
fi
printf '%s\n' "$output" | grep -Fq \
	'upnp_ikev2_ports=conflict:active-UDP-500-or-4500-mapping'

printf 'UPnP compatibility tests OK\n'
