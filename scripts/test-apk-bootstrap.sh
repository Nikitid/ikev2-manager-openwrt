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
EOF
cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_APK_LOG"
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
