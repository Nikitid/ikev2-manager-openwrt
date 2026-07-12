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
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
[ "${MOCK_DNS_READY:-0}" = 1 ] || exit 1
cat <<'ANSWER'
Name: openwrt.org
Address: 64.226.122.113
ANSWER
EOF
chmod 755 "$tmp/bin/ip" "$tmp/bin/nslookup"

PATH="$tmp/bin:$PATH"
export PATH
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/routing.sh"
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/package-manager.sh"

MOCK_DNS_READY=1
export MOCK_DNS_READY
wait_for_router_dns 127.0.0.1 1 openwrt.org
MOCK_DNS_READY=0
if wait_for_router_dns 127.0.0.1 1 openwrt.org; then
	echo 'router DNS readiness check accepted a failed query' >&2
	exit 1
fi

failclosed_check
if MOCK_FAILCLOSED_MISSING=1 failclosed_check; then
	echo 'failclosed_check accepted a table without unreachable default' >&2
	exit 1
fi

pkg_cache="$tmp/packages"
mkdir -p "$pkg_cache"
printf x >"$pkg_cache/dnsmasq_2.93-r1_all.ipk"
printf x >"$pkg_cache/dnsmasq-full_2.93-r1_all.ipk"
printf x >"$pkg_cache/dnsmasq-2.93-r1.apk"
printf x >"$pkg_cache/dnsmasq-full-2.93-r1.apk"
cat >"$tmp/bin/opkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_OPKG_LOG"
case "$1" in
	remove | install) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/opkg"

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
TEST_OPKG_LOG="$tmp/opkg.log"
export TEST_OPKG_LOG
: >"$TEST_OPKG_LOG"
pkg_switch_dnsmasq_full "$pkg_cache" dnsmasq
pkg_restore_dnsmasq "$pkg_cache" dnsmasq
grep -qx 'remove --force-depends dnsmasq' "$TEST_OPKG_LOG"
grep -qx "install $pkg_cache/dnsmasq-full_2.93-r1_all.ipk" "$TEST_OPKG_LOG"
grep -qx "install $pkg_cache/dnsmasq_2.93-r1_all.ipk" "$TEST_OPKG_LOG"

cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TEST_APK_LOG:-/dev/null}"
case "$1 $2 $3 $4" in
	"list --installed --manifest pbr") echo 'pbr 1.2.2-r18' ;;
	"info -e pbr ") exit 0 ;;
	"info -e dnsmasq ") case " ${TEST_APK_INSTALLED:-} " in *' dnsmasq '*) exit 0;; *) exit 1;; esac ;;
	"info -e dnsmasq-full ") case " ${TEST_APK_INSTALLED:-} " in *' dnsmasq-full '*) exit 0;; *) exit 1;; esac ;;
	"info -e dnsmasq-dhcpv6 ") case " ${TEST_APK_INSTALLED:-} " in *' dnsmasq-dhcpv6 '*) exit 0;; *) exit 1;; esac ;;
	"add dnsmasq-full  ") exit 0 ;;
	"del dnsmasq-full  ") exit 0 ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/dnsmasq" <<'EOF'
#!/bin/sh
printf 'Compile time options: IPv6 UBus %s no-DNSSEC\n' "${TEST_DNSMASQ_OPTION:-no-nftset}"
EOF
chmod 755 "$tmp/bin/apk" "$tmp/bin/dnsmasq"

IKEV2_PACKAGE_MANAGER=apk
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq-full)")" = dnsmasq-full-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the .apk file' >&2
	exit 1
}
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq)")" = dnsmasq-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the base dnsmasq .apk file' >&2
	exit 1
}
[ "$(pkg_version pbr)" = 1.2.2-r18 ] || {
	echo 'apk package version parsing failed' >&2
	exit 1
}
pkg_installed pbr || {
	echo 'apk installed-package check failed' >&2
	exit 1
}
TEST_APK_INSTALLED=dnsmasq
export TEST_APK_INSTALLED
[ "$(pkg_dnsmasq_provider)" = dnsmasq ] || {
	echo 'apk dnsmasq provider detection failed' >&2
	exit 1
}
TEST_APK_LOG="$tmp/apk.log"
export TEST_APK_LOG
: >"$TEST_APK_LOG"
pkg_switch_dnsmasq_full "$pkg_cache" dnsmasq
grep -qx 'add dnsmasq-full' "$TEST_APK_LOG"
TEST_APK_INSTALLED='dnsmasq dnsmasq-full'
pkg_restore_dnsmasq "$pkg_cache" dnsmasq
grep -qx 'del dnsmasq-full' "$TEST_APK_LOG"
TEST_DNSMASQ_OPTION=nftset pkg_dnsmasq_has_nftset || {
	echo 'dnsmasq nftset capability was not detected' >&2
	exit 1
}
if TEST_DNSMASQ_OPTION=no-nftset pkg_dnsmasq_has_nftset; then
	echo 'dnsmasq no-nftset was accepted as nftset support' >&2
	exit 1
fi

printf 'runtime module tests OK\n'
