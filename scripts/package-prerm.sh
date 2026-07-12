#!/bin/sh

set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0
[ -r /etc/openwrt_release ] || exit 0

# Upgrades must not tear down live routing. On explicit package removal,
# disable only the managed runtime state while preserving user configuration,
# credentials, certificates and custom destination lists.
[ "${PKG_UPGRADE:-0}" = 1 ] && exit 0
case "${1:-}" in
	remove | '') ;;
	upgrade) exit 0 ;;
	*) exit 0 ;;
esac

fail() {
	printf 'IKEv2 Manager for OpenWrt: %s\n' "$*" >&2
	exit 1
}

configured="$(uci -q get ikev2-manager.globals.configured 2>/dev/null || echo 0)"
if [ "$configured" = 1 ]; then
	[ -x /usr/libexec/ikev2-manager-system ] ||
		fail 'managed mode is enabled but the cleanup helper is missing; disable the app before removing it'
	/usr/libexec/ikev2-manager-system disable >/dev/null 2>&1 ||
		fail 'unable to disable managed mode; package removal stopped before changing files'
elif [ -x /usr/libexec/ikev2-manager-system ]; then
	/usr/libexec/ikev2-manager-system disable >/dev/null 2>&1 || true
fi

swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
swanctl --terminate --ike ikev2-in --timeout 3 >/dev/null 2>&1 || true
rm -f /etc/swanctl/conf.d/20-proxy-out.conf
rm -f /etc/swanctl/conf.d/30-inbound.conf
rm -f /etc/swanctl/conf.d/90-proxy-out-secret.conf
rm -f /etc/swanctl/conf.d/91-inbound-secrets.conf
rm -f /etc/swanctl/x509/ikev2.pem
rm -f /etc/swanctl/private/ikev2.key
rm -f /etc/swanctl/x509ca/ikev2-le-isrg-root-*.pem
rm -f /etc/swanctl/x509ca/ikev2-server-chain-*.pem

for service in ikev2-health ikev2-xfrm ikev2-domain-router; do
	[ -x "/etc/init.d/$service" ] || continue
	"/etc/init.d/$service" stop >/dev/null 2>&1 || true
	"/etc/init.d/$service" disable >/dev/null 2>&1 || true
done

rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-pbr-killswitch.nft
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
rm -f /tmp/ikev2-manager-action.log /tmp/ikev2-system-action.log
rm -f /tmp/ikev2-manager-deps.log /tmp/ikev2-manager-deps.status
rm -f /tmp/ikev2-manager-doctor.last /tmp/ikev2-manager-preflight.last
rm -f /tmp/ikev2-manager-dhcp.before-deps
rm -rf /tmp/ikev2-manager-dns-packages
rm -f /tmp/ikev2-domains-community.log /tmp/ikev2-domains-pbr-restart.log
rm -f /tmp/ikev2-acme.log /tmp/ikev2-acme.status
rm -f /var/run/ikev2-vip4 /var/run/ikev2-manager-action.status
rm -f /var/run/ikev2-system-action.status /var/run/ikev2-action.lock.status
rm -rf /var/run/ikev2-manager-actions /var/run/ikev2-system-actions
rmdir /var/run/ikev2-action.lock 2>/dev/null || true

fw4 -q reload >/dev/null 2>&1 || true

exit 0
