#!/bin/sh

set -eu

fail() {
	printf 'check-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

public_key="$root/$OPENWRT_APK_KEY_FILE"
release_workflow="$root/.github/workflows/release.yml"
[ -r "$public_key" ] || fail "public key not found: $OPENWRT_APK_KEY_FILE"

actual="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual"

openssl pkey -pubin -in "$public_key" -noout >/dev/null 2>&1 ||
	fail 'release public key is not a valid PEM public key'

git -C "$root" ls-files --cached --others --exclude-standard |
	grep -Ei '(^|/)(private|signing)[^/]*\.(pem|key)$' &&
	fail 'private signing material is tracked'

grep -q "OPENWRT_APK_TRUST_SHA256=$OPENWRT_APK_TRUST_SHA256" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap public-key checksum is out of sync'
grep -q "OPENWRT_APK_RELEASE_BASE=$OPENWRT_APK_RELEASE_BASE" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap stable release base is out of sync'
grep -q "OPENWRT_APK_CHANNEL_BASE=$OPENWRT_APK_CHANNEL_BASE" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap stable feed channel is out of sync'
grep -Fq 'OPENWRT_APK_FEED_URL="$OPENWRT_APK_CHANNEL_BASE/packages.adb"' \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap feed URL is not derived from the release channel'
grep -Fq 'git -C "$channel_dir" push origin HEAD:apk-feed' "$release_workflow" ||
	fail 'release workflow does not publish the stable APK channel'
for prerelease in _rc _beta _alpha; do
	grep -Fq "contains(github.ref_name, '$prerelease')" "$release_workflow" ||
		fail "release workflow does not exclude $prerelease tags from the stable APK channel"
done

printf 'check-apk-feed OK\n'
