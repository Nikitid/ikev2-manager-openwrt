#!/bin/sh

set -eu

fail() {
	printf 'check-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

public_key="$root/$OPENWRT_APK_KEY_FILE"
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
grep -q "OPENWRT_APK_FEED_URL=$OPENWRT_APK_FEED_URL" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap feed URL is out of sync'

printf 'check-apk-feed OK\n'
