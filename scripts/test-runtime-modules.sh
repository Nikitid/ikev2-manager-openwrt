#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

action_status_file="$tmp/latest.status"
action_status_dir="$tmp/actions"
action_lock_dir="$tmp/action.lock"
action_lock_status="$tmp/action.lock.status"

# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/actions.sh"

action_status test-1 running 'Testing shared actions'
grep -q '^action_id=test-1$' "$action_status_file"
grep -q '^state=running$' "$action_status_file"
grep -q '^message=Testing shared actions$' "$action_status_file"
acquire_action_lock tests test-1
grep -q '^owner=tests$' "$action_lock_status"
rm -f "$action_lock_status"
rmdir "$action_lock_dir"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	"-4 route show table pbr_ikev2out")
		[ "${MOCK_FAILCLOSED_MISSING:-0}" = 1 ] || echo 'unreachable default metric 32767'
		;;
	"-4 route get "*)
		echo 'RTNETLINK answers: Network is unreachable' >&2
		exit 2
		;;
	*) ;;
esac
EOF
chmod 755 "$tmp/bin/ip"

PATH="$tmp/bin:$PATH"
export PATH
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/routing.sh"
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/package-manager.sh"

failclosed_check
if MOCK_FAILCLOSED_MISSING=1 failclosed_check; then
	echo 'failclosed_check accepted a table without unreachable default' >&2
	exit 1
fi

pkg_cache="$tmp/packages"
mkdir -p "$pkg_cache"
touch "$pkg_cache/dnsmasq_2.93-r1_all.ipk"
touch "$pkg_cache/dnsmasq-full_2.93-r1_all.ipk"
touch "$pkg_cache/dnsmasq-2.93-r1.apk"
touch "$pkg_cache/dnsmasq-full-2.93-r1.apk"

IKEV2_PACKAGE_MANAGER=opkg
export IKEV2_PACKAGE_MANAGER
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq-full)")" = dnsmasq-full_2.93-r1_all.ipk ] || {
	echo 'opkg package lookup did not select the .ipk file' >&2
	exit 1
}
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq)")" = dnsmasq_2.93-r1_all.ipk ] || {
	echo 'opkg package lookup did not select the base dnsmasq .ipk file' >&2
	exit 1
}

cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
	"info -v pbr") echo 'pbr-1.2.2-r14' ;;
	"info -e pbr") exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/apk"

IKEV2_PACKAGE_MANAGER=apk
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq-full)")" = dnsmasq-full-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the .apk file' >&2
	exit 1
}
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq)")" = dnsmasq-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the base dnsmasq .apk file' >&2
	exit 1
}
[ "$(pkg_version pbr)" = 1.2.2-r14 ] || {
	echo 'apk package version parsing failed' >&2
	exit 1
}
pkg_installed pbr || {
	echo 'apk installed-package check failed' >&2
	exit 1
}

printf 'runtime module tests OK\n'
