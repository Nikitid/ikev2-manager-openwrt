#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
stage="${BUILD_DIR:-$root/build/manual-ipk}/stage"

# Fail fast if the SDK Makefile identity drifted from release.env (B3).
"$root/scripts/check-version-sync.sh"

mkdir -p "$root/dist"
"$root/scripts/stage-package.sh" "$stage"
rm -f "$root/dist"/*.ipk "$root/dist/SHA256SUMS"
python3 "$root/scripts/pack-ipk.py" "$stage" "$root/dist"
(
	cd "$root/dist"
	sha256sum luci-app-ikev2-manager_*.ipk > SHA256SUMS
	sha256sum -c SHA256SUMS
)
