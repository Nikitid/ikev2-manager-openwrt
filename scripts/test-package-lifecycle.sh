#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
makefile="$root/Makefile"
prerm="$root/scripts/package-prerm.sh"

PKG_UPGRADE=1 sh "$prerm"
sh "$prerm" upgrade

grep -Fq '[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0' "$makefile"
grep -Fq "remove | '') ;;" "$makefile"
grep -Fq 'upgrade) exit 0 ;;' "$makefile"
grep -Fq 'rm -f /tmp/ikev2-manager-dhcp.before-deps' "$makefile"
grep -Fq 'rm -rf /tmp/ikev2-manager-dns-packages' "$makefile"

if grep -Fq 'case "$${1:-}" in' "$makefile" &&
   grep -Fq 'remove) ;;' "$makefile"; then
	printf '%s\n' 'APK pre-deinstall still skips cleanup when argv is empty' >&2
	exit 1
fi

grep -Fq '[ "${PKG_UPGRADE:-0}" = 1 ] && exit 0' "$prerm"
grep -Fq "remove | '') ;;" "$prerm"

if grep -R -F '/etc/init.d/rpcd restart' "$makefile" "$prerm" "$root/scripts/stage-package.sh"; then
	printf '%s\n' 'package lifecycle scripts must not restart rpcd during apk/opkg transactions' >&2
	exit 1
fi

printf '%s\n' 'package lifecycle tests OK'
