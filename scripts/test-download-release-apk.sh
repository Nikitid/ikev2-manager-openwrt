#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/output"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
set -eu
directory=''
pattern=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dir) directory="$2"; shift 2 ;;
		--pattern) pattern="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ -n "$directory" ] && [ -n "$pattern" ]
package="${pattern%-*.apk}"
mkdir -p "$directory"
: >"$directory/$package-0.1.0.apk"
if [ "${TEST_GH_MULTIPLE:-0}" = 1 ]; then
	: >"$directory/$package-0.2.0.apk"
fi
EOF
chmod 755 "$tmp/bin/gh"

downloaded="$(
	PATH="$tmp/bin:$PATH" "$root/scripts/download-release-apk.sh" \
		"$OPENWRT_OVERVIEW_REPOSITORY" "$OPENWRT_OVERVIEW_PACKAGE" \
		latest "$tmp/output"
)"
[ "$(basename "$downloaded")" = "$OPENWRT_OVERVIEW_PACKAGE-0.1.0.apk" ]

if PATH="$tmp/bin:$PATH" "$root/scripts/download-release-apk.sh" \
	'invalid/repository/name' "$OPENWRT_OVERVIEW_PACKAGE" latest \
	"$tmp/output" >/dev/null 2>&1; then
	printf 'invalid GitHub repository name was accepted\n' >&2
	exit 1
fi

if TEST_GH_MULTIPLE=1 PATH="$tmp/bin:$PATH" \
	"$root/scripts/download-release-apk.sh" \
	"$OPENWRT_OVERVIEW_REPOSITORY" "$OPENWRT_OVERVIEW_PACKAGE" latest \
	"$tmp/output" >/dev/null 2>&1; then
	printf 'release with multiple matching APKs was accepted\n' >&2
	exit 1
fi

printf 'release APK download tests OK\n'
