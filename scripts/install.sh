#!/bin/sh

set -eu

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ -r /etc/openwrt_release ] || die 'This installer must run on OpenWrt'
. /etc/openwrt_release
[ "${DISTRIB_ID:-}" = OpenWrt ] ||
	die "Official OpenWrt is required; found ${DISTRIB_ID:-unknown vendor firmware}"
case "${DISTRIB_RELEASE:-}" in
	24.10.*) package_manager=opkg ;;
	25.12.*) package_manager=apk ;;
	*) die "OpenWrt 24.10.x or 25.12.x is required; found ${DISTRIB_RELEASE:-unknown}" ;;
esac
command -v "$package_manager" >/dev/null 2>&1 ||
	die "required package manager is missing: $package_manager"

[ "$#" -eq 1 ] || die "Usage: $0 /tmp/luci-app-ikev2-manager_*.ipk|*.apk"
package="$1"
[ -s "$package" ] || die "Package not found: $package"
case "$package_manager:$package" in
	opkg:*.ipk | apk:*.apk) ;;
	opkg:*) die 'OpenWrt 24.10 requires an .ipk package' ;;
	apk:*) die 'OpenWrt 25.12 requires an .apk package' ;;
esac

pkg_update() {
	case "$package_manager" in
		opkg) opkg update ;;
		apk) apk update ;;
		*) return 1 ;;
	esac
}

pkg_install_plan() {
	case "$package_manager" in
		opkg) opkg install --noaction "$1" ;;
		apk) apk add --simulate "$1" ;;
		*) return 1 ;;
	esac
}

pkg_install() {
	case "$package_manager" in
		opkg) opkg install "$1" ;;
		apk) apk add "$1" ;;
		*) return 1 ;;
	esac
}

backup="/tmp/ikev2-manager-install-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade -b "$backup"
printf 'Configuration backup: %s\n' "$backup"

pkg_update
if ! pkg_install_plan "$package"; then
	die 'Package preflight failed; no packages were changed'
fi

pkg_install "$package" || die "Package installation failed; restore configuration from $backup if needed"

/usr/libexec/ikev2-manager-system _install-deps-run

cat <<'EOF'

Installation complete. No VPN tunnel, PBR policy or firewall rule was enabled.
Open LuCI -> Services -> IKEv2 Manager for OpenWrt -> Overview.
EOF
