#!/bin/sh

set -eu

fail() {
	printf 'download-release-apk: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] ||
	fail 'usage: download-release-apk.sh REPOSITORY PACKAGE TAG [OUTPUT_DIR]'

repository="$1"
package="$2"
tag="$3"
output="${4:-$(pwd)}"

case "$repository" in
	*/*)
		owner="${repository%%/*}"
		name="${repository#*/}"
		case "$name" in
			*/*) fail 'invalid GitHub repository name' ;;
		esac
		case "$owner" in
			'' | *[!A-Za-z0-9_.-]*) fail 'invalid GitHub repository name' ;;
		esac
		case "$name" in
			'' | *[!A-Za-z0-9_.-]*) fail 'invalid GitHub repository name' ;;
		esac
		;;
	*) fail 'invalid GitHub repository name' ;;
esac
case "$package" in
	'' | *[!A-Za-z0-9+_.-]*) fail 'invalid package name' ;;
esac
case "$tag" in
	latest) ;;
	'' | *[!A-Za-z0-9._-]*) fail 'invalid release tag' ;;
esac

command -v gh >/dev/null 2>&1 || fail 'gh is required'
mkdir -p "$output"
for old in "$output/$package"-*.apk; do
	[ ! -e "$old" ] || rm -f "$old"
done

if [ "$tag" = latest ]; then
	gh release download --repo "$repository" \
		--pattern "$package-*.apk" --dir "$output"
else
	gh release download "$tag" --repo "$repository" \
		--pattern "$package-*.apk" --dir "$output"
fi

count=0
found=''
for candidate in "$output/$package"-*.apk; do
	[ -f "$candidate" ] || continue
	count=$((count + 1))
	found="$candidate"
done
[ "$count" -eq 1 ] ||
	fail "expected one $package APK in release $tag, found $count"

printf '%s\n' "$found"
