#!/bin/sh

set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

fail() {
	printf 'IKEv2 Manager for OpenWrt: %s\n' "$*" >&2
	exit 1
}

[ -r /etc/openwrt_release ] || fail 'this package can only be installed on OpenWrt'
. /etc/openwrt_release

[ "${DISTRIB_ID:-}" = OpenWrt ] ||
	fail "official OpenWrt is required; found ${DISTRIB_ID:-unknown vendor firmware}"

case "${DISTRIB_RELEASE:-}" in
	24.10.*) ;;
	25.12.*)
		fail 'OpenWrt 25.12 uses apk and is not supported by this opkg release'
		;;
	*)
		fail "OpenWrt 24.10.x is required; found ${DISTRIB_RELEASE:-unknown}"
		;;
esac

for command in opkg uci ubus fw4; do
	command -v "$command" >/dev/null 2>&1 ||
		fail "required base command is missing: $command"
done

grep -qE 'downloads\.openwrt\.org/releases/24\.10\.' \
	/etc/opkg/distfeeds.conf 2>/dev/null ||
	fail 'official OpenWrt 24.10 release package feeds are required'

if opkg status luci-app-ikev2-pbr 2>/dev/null |
	grep -q '^Status: .* installed'; then
	fail 'legacy package luci-app-ikev2-pbr is installed; use scripts/install.sh for the one-time migration'
fi

free_kib="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
[ -n "$free_kib" ] || free_kib="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
case "${free_kib:-0}" in *[!0-9]*) free_kib=0 ;; esac
[ "$free_kib" -ge 1024 ] ||
	fail "insufficient persistent storage to install the bootstrap package (${free_kib} KiB free)"

exit 0
