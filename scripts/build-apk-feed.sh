#!/bin/sh

set -eu

fail() {
	printf 'build-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"
output="$root/dist/apk-feed"

[ -n "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -d "$sdk" ] || fail "SDK directory not found: $sdk"
[ -n "$signing_key" ] || fail 'OPENWRT_APK_SIGNING_KEY is required'
[ -r "$signing_key" ] || fail "signing key not readable: $signing_key"
[ -r "$public_key" ] || fail "public key not found: $public_key"

case "$(basename "$sdk")" in
	"${OPENWRT_APK_SDK_ARCHIVE%.tar.zst}") ;;
	*) fail "unexpected SDK directory: $(basename "$sdk")" ;;
esac

for command in make openssl rsync sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

actual_key_hash="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual_key_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual_key_hash"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

openssl ec -in "$signing_key" -pubout -out "$tmp/derived-public.pem" >/dev/null 2>&1 ||
	fail 'invalid EC signing key'
cmp -s "$tmp/derived-public.pem" "$public_key" ||
	fail 'signing key does not match the tracked public release key'

sdk_package="$sdk/package/luci-app-ikev2-manager"
rm -rf "$sdk_package"
mkdir -p "$sdk_package"
rsync -a --delete \
	--exclude .git \
	--exclude build \
	--exclude dist \
	--exclude .DS_Store \
	"$root/" "$sdk_package/"

"$root/scripts/check-version-sync.sh"
make -C "$sdk" defconfig
make -C "$sdk" package/luci-app-ikev2-manager/clean V=s
make -C "$sdk" \
	BUILD_KEY_APK_SEC="$signing_key" \
	BUILD_KEY_APK_PUB="$public_key" \
	package/luci-app-ikev2-manager/compile V=s

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail "SDK apk tool not found: $apk_tool"

package_path="$(find "$sdk/bin/packages" -type f \
	-name "${PKG_NAME}-${PKG_VERSION}.apk" -print -quit)"
[ -n "$package_path" ] || fail 'built APK was not found'

rm -rf "$output"
mkdir -p "$output"
package_name="${PKG_NAME}-${PKG_VERSION}.apk"
cp "$package_path" "$output/$package_name"

"$apk_tool" --allow-untrusted adbsign \
	--sign-key "$signing_key" "$output/$package_name"
"$apk_tool" --keys-dir "$root/keys" verify "$output/$package_name"

(
	cd "$output"
	"$apk_tool" mkndx \
		--keys-dir "$root/keys" \
		--sign-key "$signing_key" \
		--description 'IKEv2 Manager for OpenWrt 25.12' \
		--output packages.adb \
		"$package_name"
)
"$apk_tool" --keys-dir "$root/keys" verify "$output/packages.adb"
"$apk_tool" --keys-dir "$root/keys" adbdump --format json \
	"$output/packages.adb" >"$tmp/packages.json"
grep -q "${PKG_NAME}" "$tmp/packages.json" ||
	fail 'generated index does not contain the package'

cp "$public_key" "$output/ikev2-manager-release.pem"
cp "$root/scripts/install-openwrt25.sh" "$output/install-openwrt25.sh"
(
	cd "$output"
	sha256sum "$package_name" packages.adb ikev2-manager-release.pem \
		install-openwrt25.sh >SHA256SUMS.apk
	sha256sum -c SHA256SUMS.apk
)

printf 'APK feed built in %s\n' "$output"
