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
	24.10.*) ;;
	25.12.*) die 'OpenWrt 25.12 uses apk and is not supported by this release' ;;
	*) die "OpenWrt 24.10.x is required; found ${DISTRIB_RELEASE:-unknown}" ;;
esac

[ "$#" -eq 1 ] || die "Usage: $0 /tmp/luci-app-ikev2-manager_*.ipk"
package="$1"
[ -s "$package" ] || die "Package not found: $package"

backup="/tmp/ikev2-manager-install-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade -b "$backup"
printf 'Configuration backup: %s\n' "$backup"

opkg update
legacy=0
migration_dir="/tmp/ikev2-manager-migration-$$"
if opkg status luci-app-ikev2-pbr 2>/dev/null | grep -q '^Status: .* installed'; then
	legacy=1
	printf 'Migrating legacy package luci-app-ikev2-pbr...\n'
	mkdir -p "$migration_dir"
	for file in \
		/etc/config/ikev2-manager \
		/etc/pbr-ikev2-domains.txt \
		/etc/pbr-ikev2-domains.manual.txt \
		/etc/pbr-ikev2-community-selected.txt; do
		[ -e "$file" ] || continue
		mkdir -p "$migration_dir${file%/*}"
		cp -p "$file" "$migration_dir$file"
	done
	opkg remove luci-app-ikev2-pbr
elif ! opkg install --noaction "$package"; then
	die 'Package preflight failed; no packages were changed'
fi

if ! opkg install "$package"; then
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
