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
	24.10.*) package_manager=opkg ;;
	25.12.*) package_manager=apk ;;
	*)
		fail "OpenWrt 24.10.x or 25.12.x is required; found ${DISTRIB_RELEASE:-unknown}"
		;;
esac

for command in "$package_manager" uci ubus fw4; do
	command -v "$command" >/dev/null 2>&1 ||
		fail "required base command is missing: $command"
done

feed_file_matches() {
	pattern="$1"
	shift
	for file in "$@"; do
		[ -r "$file" ] || continue
		grep -qE "$pattern" "$file" && return 0
	done
	return 1
}

case "$package_manager:${DISTRIB_RELEASE:-}" in
	opkg:24.10.*)
		feed_file_matches 'downloads\.openwrt\.org/releases/24\.10\.' \
			/etc/opkg/distfeeds.conf ||
			fail 'official OpenWrt 24.10 release package feeds are required'
		;;
	apk:25.12.*)
		feed_file_matches \
			'downloads\.openwrt\.org/releases/(25\.12\.|packages-25\.12)' \
			/etc/apk/repositories /etc/apk/repositories.d/* ||
			fail 'official OpenWrt 25.12 release package feeds are required'
		;;
	*)
		fail "unsupported package manager $package_manager for OpenWrt ${DISTRIB_RELEASE:-unknown}"
		;;
esac

free_kib="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
[ -n "$free_kib" ] || free_kib="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
case "${free_kib:-0}" in *[!0-9]*) free_kib=0 ;; esac
[ "$free_kib" -ge 1024 ] ||
	fail "insufficient persistent storage to install the bootstrap package (${free_kib} KiB free)"

exit 0
