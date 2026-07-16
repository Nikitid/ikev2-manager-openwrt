#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
client="$root/luci-ikev2-manager/client.js"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
config="$root/openwrt/files/etc/config/ikev2-manager"

grep -Fq "configuredDnsValue(dnsValue, 'fallback', 'current_fallback', '')" "$client"
if grep -Fq "dnsValue.fallback || dnsValue.current_fallback" "$client"; then
	printf '%s\n' 'empty managed fallback can still inherit the dnsproxy package default' >&2
	exit 1
fi
grep -Eq "^[[:space:]]*option fallback ''$" "$config"

grep -Fq "throw new Error(_('Invalid DNS upstream for the selected protocol'))" "$client"
grep -Fq "throw new Error(_('Bootstrap DNS must contain IPv4:port entries'))" "$client"
grep -Fq "throw new Error(_('Invalid fallback DNS endpoint'))" "$client"
grep -Fq "dns_error_file=\"/tmp/ikev2-dns-action-\$id.error\"" "$system"
grep -Fq '[ "$managed" = 0 ] || valid_name "$provider"' "$system"
grep -Fq "_dns-apply-inner 0 '' '' '' '' '' ''" "$system"
grep -Fq '127.0.0.42 | 127.0.0.42#53) uses_fakeip=1' "$system"
grep -Fq 'repair_dns_original_snapshot ||' "$system"
grep -Fq "die 'Saved original DNS state is incomplete; managed DNS remains configured'" "$system"

grep -Fq "dot) prefix='tls://'" "$system"
if grep -Fq "prefix='tls:'" "$system"; then
	printf '%s\n' 'malformed DoT endpoints are accepted' >&2
	exit 1
fi

# The outbound IKEv2 path currently has only IPv4 traffic selectors. Keep DNS
# bootstrap transport on IPv4, suppress AAAA in Reliable mode, and retain the
# IPv6 PBR terminal route so selected AAAA cannot fall through to WAN.
grep -Fq '"strategy": "ipv4_only"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq "die 'Bootstrap DNS must contain IPv4:port entries'" "$system"
grep -Fq "uci set pbr.config.ipv6_enabled='1'" "$system"
grep -Fq 'ip -6 route replace unreachable default metric 32767' \
	"$root/ikev2-manager-runtime/pbr.user.ikev2out"

grep -Fq "field in engine service dnsmasq_upstream dnsmasq_cache nft rule healthy state message" "$system"
grep -Fq "Reliable-mode nftables rules are missing." \
	"$root/luci-ikev2-manager/setup.js"

printf '%s\n' 'DNS and reliable-mode regression checks OK'
