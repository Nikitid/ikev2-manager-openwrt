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

grep -Fq "dot:tls://*)" "$system"
if grep -Fq "dot:tls:*)" "$system"; then
	printf '%s\n' 'malformed DoT endpoints are accepted' >&2
	exit 1
fi

grep -Fq "field in engine service dnsmasq_upstream dnsmasq_cache nft rule healthy state message" "$system"
grep -Fq "Reliable-mode nftables rules are missing." \
	"$root/luci-ikev2-manager/setup.js"

printf '%s\n' 'DNS and reliable-mode regression checks OK'
