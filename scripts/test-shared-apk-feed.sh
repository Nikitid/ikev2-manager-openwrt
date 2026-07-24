#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

feed="$tmp/feed"
mkdir -p "$feed" "$tmp/bin" "$tmp/keys"
ikev2="$feed/$OPENWRT_IKEV2_PACKAGE-1.2.1.apk"
overview="$feed/$OPENWRT_OVERVIEW_PACKAGE-0.1.0.apk"
: >"$ikev2"
: >"$overview"
: >"$feed/packages.adb"
: >"$feed/install-openwrt25.sh"
cp "$root/$OPENWRT_APK_KEY_FILE" "$feed/ikev2-manager-release.pem"
cp "$root/$OPENWRT_APK_KEY_ALIAS" "$feed/nikitid-openwrt-release.pem"
cp "$root/$OPENWRT_APK_KEY_FILE" "$tmp/keys/ikev2-manager-release.pem"

cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_APK_LOG"
last=''
for argument in "$@"; do last="$argument"; done
case " $* " in
	*" verify "*)
		[ "${TEST_FAIL_BASENAME:-}" != "$(basename "$last")" ]
		;;
	*" adbdump "*)
		case "$(basename "$last")" in
			packages.adb)
				if [ "${TEST_INDEX_MISSING_OVERVIEW:-0}" = 1 ]; then
					printf '%s\n' '{"packages":[{"name":"luci-app-ikev2-manager"}]}'
				else
					printf '%s\n' '{"packages":[{"name":"luci-app-ikev2-manager"},{"name":"luci-app-overview-manager"}]}'
				fi
				;;
			luci-app-ikev2-manager-*.apk)
				printf '%s\n' '{"name":"luci-app-ikev2-manager","architecture":"aarch64_cortex-a53"}'
				;;
			luci-app-overview-manager-*.apk)
				printf '%s\n' '{"name":"luci-app-overview-manager","architecture":"aarch64_cortex-a53"}'
				;;
			*) exit 1 ;;
		esac
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/apk"

(
	cd "$feed"
	sha256sum "$(basename "$ikev2")" "$(basename "$overview")" \
		packages.adb ikev2-manager-release.pem nikitid-openwrt-release.pem \
		install-openwrt25.sh >SHA256SUMS.apk
)

: >"$tmp/apk.log"
TEST_APK_LOG="$tmp/apk.log" \
OPENWRT_APK_TOOL="$tmp/bin/apk" \
OPENWRT_APK_VERIFY_KEYS="$tmp/keys" \
	"$root/scripts/verify-shared-apk-feed.sh" "$feed" >/dev/null

for signed in "$(basename "$ikev2")" "$(basename "$overview")" packages.adb; do
	grep -F " verify $feed/$signed" "$tmp/apk.log" >/dev/null || {
		printf 'signature verification was not required for %s\n' "$signed" >&2
		exit 1
	}
done

if TEST_INDEX_MISSING_OVERVIEW=1 \
	TEST_APK_LOG="$tmp/apk.log" \
	OPENWRT_APK_TOOL="$tmp/bin/apk" \
	OPENWRT_APK_VERIFY_KEYS="$tmp/keys" \
		"$root/scripts/verify-shared-apk-feed.sh" "$feed" >/dev/null 2>&1; then
	printf 'shared feed without Overview Manager passed verification\n' >&2
	exit 1
fi

for unsigned in "$(basename "$ikev2")" "$(basename "$overview")"; do
	if TEST_FAIL_BASENAME="$unsigned" \
		TEST_APK_LOG="$tmp/apk.log" \
		OPENWRT_APK_TOOL="$tmp/bin/apk" \
		OPENWRT_APK_VERIFY_KEYS="$tmp/keys" \
			"$root/scripts/verify-shared-apk-feed.sh" "$feed" >/dev/null 2>&1; then
		printf 'invalid signature was accepted for %s\n' "$unsigned" >&2
		exit 1
	fi
done

printf 'shared APK feed tests OK\n'
