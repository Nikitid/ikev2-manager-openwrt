#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"

expected="v${PKG_VERSION}-r${PKG_RELEASE}"
actual="${1:-${GITHUB_REF_NAME:-}}"

[ -n "$actual" ] || {
	printf 'Usage: %s TAG\n' "$0" >&2
	exit 1
}

[ "$actual" = "$expected" ] || {
	printf 'Release tag %s does not match package version %s\n' "$actual" "$expected" >&2
	exit 1
}

printf 'release tag OK: %s\n' "$actual"
