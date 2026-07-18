#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/bin"
cat >"$tmp/bin/wget" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -q ]
[ "$2" = -O ]
cp "$TEST_APK_KEY" "$3"
printf '%s\n' "$4" >>"${TEST_WGET_LOG:-/dev/null}"
EOF
cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_APK_LOG"
if [ "$1" = info ] && [ "$2" = --installed ]; then
	[ "${TEST_APK_INSTALLED:-0}" = 1 ]
fi
if [ "${TEST_APK_FAIL_UPDATE:-0}" = 1 ] && [ "$1" = update ]; then
	exit 1
fi
EOF
chmod 755 "$tmp/bin/wget" "$tmp/bin/apk"

new_root() {
	test_root="$1"
	mkdir -p "$test_root/etc"
	cat >"$test_root/etc/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
}

success_root="$tmp/success"
new_root "$success_root"
: >"$tmp/apk-success.log"
PATH="$tmp/bin:$PATH" \
TEST_APK_KEY="$root/$OPENWRT_APK_KEY_FILE" \
TEST_APK_LOG="$tmp/apk-success.log" \
IKEV2_INSTALL_ROOT="$success_root" \
	"$root/scripts/install-openwrt25.sh" >/dev/null

key="$success_root/etc/apk/keys/ikev2-manager-release.pem"
repo="$success_root/etc/apk/repositories.d/ikev2-manager.list"
[ "$(sha256sum "$key" | awk '{ print $1 }')" = "$OPENWRT_APK_TRUST_SHA256" ]
[ "$(cat "$repo")" = "$OPENWRT_APK_FEED_URL" ]
grep -qx 'update' "$tmp/apk-success.log"
grep -qx 'add --simulate luci-app-ikev2-manager' "$tmp/apk-success.log"
grep -qx 'add luci-app-ikev2-manager' "$tmp/apk-success.log"

upgrade_root="$tmp/upgrade"
new_root "$upgrade_root"
mkdir -p "$upgrade_root/etc/apk/keys" "$upgrade_root/etc/apk/repositories.d"
cp "$root/$OPENWRT_APK_KEY_FILE" \
	"$upgrade_root/etc/apk/keys/ikev2-manager-release.pem"
printf '%s\n' 'https://github.com/Nikitid/ikev2-manager-openwrt/releases/download/v1.1.5/packages.adb' \
	>"$upgrade_root/etc/apk/repositories.d/ikev2-manager.list"
printf '%s\n' 'luci-app-ikev2-manager><Q1p3AuNzlw8fR0ahxyjelaHyzNt6g=' \
	>"$upgrade_root/etc/apk/world"
: >"$tmp/apk-upgrade.log"
PATH="$tmp/bin:$PATH" \
TEST_APK_KEY="$root/$OPENWRT_APK_KEY_FILE" \
TEST_APK_LOG="$tmp/apk-upgrade.log" \
TEST_APK_INSTALLED=1 \
IKEV2_INSTALL_ROOT="$upgrade_root" \
	"$root/scripts/install-openwrt25.sh" >/dev/null
[ "$(cat "$upgrade_root/etc/apk/repositories.d/ikev2-manager.list")" = \
	"$OPENWRT_APK_FEED_URL" ]
[ "$(cat "$upgrade_root/etc/apk/world")" = 'luci-app-ikev2-manager' ]
grep -qx 'upgrade --simulate luci-app-ikev2-manager' "$tmp/apk-upgrade.log"
grep -qx 'upgrade luci-app-ikev2-manager' "$tmp/apk-upgrade.log"

upgrade_failure_root="$tmp/upgrade-failure"
new_root "$upgrade_failure_root"
mkdir -p "$upgrade_failure_root/etc/apk/keys" \
	"$upgrade_failure_root/etc/apk/repositories.d"
cp "$root/$OPENWRT_APK_KEY_FILE" \
	"$upgrade_failure_root/etc/apk/keys/ikev2-manager-release.pem"
old_repo='https://github.com/Nikitid/ikev2-manager-openwrt/releases/download/v1.1.5/packages.adb'
old_world='luci-app-ikev2-manager><Q1p3AuNzlw8fR0ahxyjelaHyzNt6g='
printf '%s\n' "$old_repo" \
	>"$upgrade_failure_root/etc/apk/repositories.d/ikev2-manager.list"
printf '%s\n' "$old_world" >"$upgrade_failure_root/etc/apk/world"
: >"$tmp/apk-upgrade-failure.log"
if PATH="$tmp/bin:$PATH" \
	TEST_APK_KEY="$root/$OPENWRT_APK_KEY_FILE" \
	TEST_APK_LOG="$tmp/apk-upgrade-failure.log" \
	TEST_APK_INSTALLED=1 \
	TEST_APK_FAIL_UPDATE=1 \
	IKEV2_INSTALL_ROOT="$upgrade_failure_root" \
	"$root/scripts/install-openwrt25.sh" >/dev/null 2>&1; then
	printf 'failed upgrade bootstrap unexpectedly succeeded\n' >&2
	exit 1
fi
[ "$(cat "$upgrade_failure_root/etc/apk/repositories.d/ikev2-manager.list")" = \
	"$old_repo" ]
[ "$(cat "$upgrade_failure_root/etc/apk/world")" = "$old_world" ]

candidate_root="$tmp/candidate"
candidate_base='https://github.com/Nikitid/ikev2-manager-openwrt/releases/download/v1.1.0_rc2'
new_root "$candidate_root"
: >"$tmp/apk-candidate.log"
: >"$tmp/wget-candidate.log"
PATH="$tmp/bin:$PATH" \
TEST_APK_KEY="$root/$OPENWRT_APK_KEY_FILE" \
TEST_APK_LOG="$tmp/apk-candidate.log" \
TEST_WGET_LOG="$tmp/wget-candidate.log" \
IKEV2_APK_RELEASE_BASE="$candidate_base" \
IKEV2_INSTALL_ROOT="$candidate_root" \
	"$root/scripts/install-openwrt25.sh" >/dev/null
[ "$(cat "$candidate_root/etc/apk/repositories.d/ikev2-manager.list")" = \
	"$OPENWRT_APK_FEED_URL" ]
grep -Fxq "$candidate_base/ikev2-manager-release.pem" "$tmp/wget-candidate.log"

failure_root="$tmp/failure"
new_root "$failure_root"
: >"$tmp/apk-failure.log"
if PATH="$tmp/bin:$PATH" \
	TEST_APK_KEY="$root/$OPENWRT_APK_KEY_FILE" \
	TEST_APK_LOG="$tmp/apk-failure.log" \
	TEST_APK_FAIL_UPDATE=1 \
	IKEV2_INSTALL_ROOT="$failure_root" \
	"$root/scripts/install-openwrt25.sh" >/dev/null 2>&1; then
	printf 'offline bootstrap unexpectedly succeeded\n' >&2
	exit 1
fi
[ ! -e "$failure_root/etc/apk/keys/ikev2-manager-release.pem" ]
[ ! -e "$failure_root/etc/apk/repositories.d/ikev2-manager.list" ]

printf 'test-apk-bootstrap OK\n'
