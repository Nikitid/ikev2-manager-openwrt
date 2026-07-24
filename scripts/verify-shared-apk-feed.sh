#!/bin/sh

set -eu

fail() {
	printf 'verify-shared-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

feed="${1:-$root/dist/apk-feed}"
apk_tool="${OPENWRT_APK_TOOL:-}"
keys_dir="${OPENWRT_APK_VERIFY_KEYS:-$root/keys}"

[ -d "$feed" ] || fail "feed directory not found: $feed"
[ -n "$apk_tool" ] || fail 'OPENWRT_APK_TOOL is required'
[ -x "$apk_tool" ] || fail "APK tool is not executable: $apk_tool"

find_package() {
	wanted="$1"
	count=0
	found=''
	for candidate in "$feed/$wanted"-*.apk; do
		[ -f "$candidate" ] || continue
		count=$((count + 1))
		found="$candidate"
	done
	[ "$count" -eq 1 ] ||
		fail "expected one current $wanted APK, found $count"
	printf '%s\n' "$found"
}

ikev2_apk="$(find_package "$OPENWRT_IKEV2_PACKAGE")"
overview_apk="$(find_package "$OPENWRT_OVERVIEW_PACKAGE")"
index="$feed/packages.adb"
legacy_key="$feed/ikev2-manager-release.pem"
alias_key="$feed/nikitid-openwrt-release.pem"
checksums="$feed/SHA256SUMS.apk"

for required in "$index" "$legacy_key" "$alias_key" "$checksums"; do
	[ -r "$required" ] || fail "required feed file is missing: $required"
done

cmp -s "$legacy_key" "$alias_key" ||
	fail 'public-key aliases contain different key material'
for key in "$legacy_key" "$alias_key"; do
	actual="$(sha256sum "$key" | awk '{ print $1 }')"
	[ "$actual" = "$OPENWRT_APK_TRUST_SHA256" ] ||
		fail "public-key checksum mismatch: $(basename "$key")"
done

"$apk_tool" --keys-dir "$keys_dir" verify "$ikev2_apk"
"$apk_tool" --keys-dir "$keys_dir" verify "$overview_apk"
"$apk_tool" --keys-dir "$keys_dir" verify "$index"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

"$apk_tool" --keys-dir "$keys_dir" adbdump --format json \
	"$index" >"$tmp/index.json"
"$apk_tool" --keys-dir "$keys_dir" adbdump --format json \
	"$ikev2_apk" >"$tmp/ikev2.json"
"$apk_tool" --keys-dir "$keys_dir" adbdump --format json \
	"$overview_apk" >"$tmp/overview.json"

python3 - "$tmp/index.json" "$tmp/ikev2.json" "$tmp/overview.json" \
	"$OPENWRT_IKEV2_PACKAGE" "$OPENWRT_OVERVIEW_PACKAGE" \
	"$OPENWRT_APK_ARCH" <<'PY'
import json
import sys


def strings(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


index = set(strings(load(sys.argv[1])))
ikev2 = set(strings(load(sys.argv[2])))
overview = set(strings(load(sys.argv[3])))
ikev2_name, overview_name, architecture = sys.argv[4:7]

for package in (ikev2_name, overview_name):
    if package not in index:
        raise SystemExit(f"shared index does not contain {package}")

if ikev2_name not in ikev2 or architecture not in ikev2:
    raise SystemExit("IKEv2 Manager APK metadata does not match the feed")
if overview_name not in overview or architecture not in overview:
    raise SystemExit("Overview Manager APK metadata does not match the feed")
PY

for file in "$(basename "$ikev2_apk")" "$(basename "$overview_apk")" \
		packages.adb ikev2-manager-release.pem nikitid-openwrt-release.pem \
		install-openwrt25.sh; do
	grep -Fq "  $file" "$checksums" ||
		fail "checksum manifest does not contain $file"
done
(
	cd "$feed"
	sha256sum -c SHA256SUMS.apk
)

printf 'shared APK feed verification OK\n'
