#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/check-version-sync.sh
./scripts/check-public-tree.sh

find luci-ikev2-domains luci-ikev2-manager ikev2-manager-runtime scripts \
	-type f -name '*.sh' -exec sh -n {} +

find luci-ikev2-domains luci-ikev2-manager \
	-type f -name '*.js' -exec node --check {} \;

PYTHONPYCACHEPREFIX="$root/build/pycache" \
	python3 -m py_compile scripts/pack-ipk.py

python3 - <<'PY'
import json
import subprocess
from pathlib import Path

tracked = subprocess.check_output(
    ["git", "ls-files", "*.json"], text=True
).splitlines()
for name in tracked:
    path = Path(name)
    if ".vscode" in path.parts:
        continue
    json.loads(path.read_text())
    print(f"json OK: {path}")
PY

./scripts/build-ipk.sh
first_hash="$(sha256sum dist/*.ipk | awk '{ print $1 }')"
./scripts/build-ipk.sh
second_hash="$(sha256sum dist/*.ipk | awk '{ print $1 }')"
[ "$first_hash" = "$second_hash" ] || {
	printf 'non-deterministic IPK build: %s != %s\n' "$first_hash" "$second_hash" >&2
	exit 1
}
git diff --check

printf 'ci-check OK\n'
