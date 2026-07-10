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

legacy_installed() {
	case "$package_manager" in
		opkg) opkg status luci-app-ikev2-pbr 2>/dev/null | grep -q '^Status: .* installed' ;;
		apk) apk info -e luci-app-ikev2-pbr >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

legacy_remove() {
	case "$package_manager" in
		opkg) opkg remove luci-app-ikev2-pbr ;;
		apk) apk del luci-app-ikev2-pbr ;;
		*) return 1 ;;
	esac
}

backup="/tmp/ikev2-manager-install-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade -b "$backup"
printf 'Configuration backup: %s\n' "$backup"

pkg_update
legacy=0
migration_dir="/tmp/ikev2-manager-migration-$$"
if legacy_installed; then
	legacy=1
	printf 'Migrating legacy package luci-app-ikev2-pbr...\n'
	mkdir -p "$migration_dir"
	for file in \
		/etc/config/ikev2-manager \
		/etc/pbr-ikev2-domains.txt \
		/etc/pbr-ikev2-domains.manual.txt \
		/etc/pbr-ikev2-addresses.manual.txt \
		/etc/pbr-ikev2-community-selected.txt; do
		[ -e "$file" ] || continue
		mkdir -p "$migration_dir${file%/*}"
		cp -p "$file" "$migration_dir$file"
	done
	legacy_remove
elif ! pkg_install_plan "$package"; then
	die 'Package preflight failed; no packages were changed'
fi

if ! pkg_install "$package"; then
	if [ "$legacy" = 1 ]; then
		printf 'Legacy package files were removed. Configuration is preserved in place.\n' >&2
		printf 'Reinstall the previous IPK or restore: %s\n' "$backup" >&2
	fi
	die 'Package installation failed'
fi

if [ "$legacy" = 1 ]; then
	for file in \
		/etc/config/ikev2-manager \
		/etc/pbr-ikev2-domains.txt \
		/etc/pbr-ikev2-domains.manual.txt \
		/etc/pbr-ikev2-addresses.manual.txt \
		/etc/pbr-ikev2-community-selected.txt; do
		[ -e "$migration_dir$file" ] || continue
		cp -p "$migration_dir$file" "$file"
		rm -f "$file-opkg"
	done
	rmdir /www/luci-static/resources/view/ikev2-manager-v2 2>/dev/null || true
	rmdir /www/luci-static/resources/ikev2-manager-v2 2>/dev/null || true
	rm -rf "$migration_dir"
fi

/usr/libexec/ikev2-manager-system _install-deps-run

cat <<'EOF'

Installation complete. No VPN tunnel, PBR policy or firewall rule was enabled.
Open LuCI -> Services -> IKEv2 Manager for OpenWrt -> Overview.
EOF
