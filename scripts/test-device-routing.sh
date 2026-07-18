#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-device-routing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'show pbr')
		echo 'pbr.pbr_dev_fr_192_168_50_4=policy'
		echo 'pbr.pbr_dev_ex_192_168_50_9=policy'
		;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.name') echo 'VPN Full Route: 192.168.50.4' ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.src_addr') echo '192.168.50.4' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.name') echo 'VPN Exclude: 192.168.50.9' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.src_addr') echo '192.168.50.9' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = '-4 rule show' ] || exit 1
echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_wan'
echo '29999: from all fwmark 0x20000/0xff0000 lookup pbr_ikev2out'
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in 192.168.50.4/32 | 192.168.50.9/32) exit 0 ;; *) exit 1 ;; esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list table inet ikev2_device_policy_test'|'list chain inet ikev2_device_policy_test prerouting')
		[ -s "$TEST_NFT_STATE" ] || exit 1
		cat "$TEST_NFT_RULESET"
		;;
	'delete table inet ikev2_device_policy_test') rm -f "$TEST_NFT_STATE" ;;
	'-c -f '*) exit 0 ;;
	'-f '*)
		cp "$2" "$TEST_NFT_RULESET"
		printf x >"$TEST_NFT_STATE"
		printf 'apply\n' >>"$TEST_NFT_LOG"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ip" "$tmp/bin/ipcalc.sh" "$tmp/bin/nft"

: >"$tmp/nft.log"
export PATH="$tmp/bin:$PATH"
export TEST_NFT_STATE="$tmp/nft.state"
export TEST_NFT_RULESET="$tmp/rules.nft"
export TEST_NFT_LOG="$tmp/nft.log"
export IKEV2_NFT="$tmp/bin/nft"
export IKEV2_DEVICE_TABLE='ikev2_device_policy_test'
export IKEV2_DEVICE_SIGNATURE="$tmp/signature"

"$helper" sync
grep -Fq 'chain ikev2_manager_owned' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.4 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.9 }' "$tmp/rules.nft"
grep -Fq 'ip saddr @exclude_ipv4 meta mark set meta mark & 0xff00ffff | 0x00010000' "$tmp/rules.nft"
grep -Fq 'ip saddr @full_route_ipv4 meta mark set meta mark & 0xff00ffff | 0x00020000' "$tmp/rules.nft"
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 1 ]

printf '%s\n' 'device routing checks OK'
