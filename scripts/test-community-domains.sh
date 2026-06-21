#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/local" "$tmp/cache"

cat >"$tmp/bin/uclient-fetch" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-O)
			output="$2"
			shift 2
			;;
		-q|-T)
			[ "$1" = -T ] && shift
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done
case "$url" in
	*/remote.lst)
		printf '%s\n' remote.example >"$output"
		;;
	*)
		exit 1
		;;
esac
EOF
chmod 755 "$tmp/bin/uclient-fetch"
cat >"$tmp/bin/restart-helper" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$tmp/bin/restart-helper"

printf '%s\n' local.example >"$tmp/local/local.lst"
printf '%s\n' direct.example >"$tmp/local/direct.lst"
cat >"$tmp/local/direct.cidrs" <<'EOF'
# Direct protocol networks
91.108.4.0/22
149.154.160.0/20
EOF
printf '%s\n' direct local remote >"$tmp/selected"
: >"$tmp/manual"
printf '%s\n' 203.0.113.10 198.51.100.0/24 >"$tmp/manual-cidrs"

run_helper() {
	PATH="$tmp/bin:$PATH" \
	IKEV2_MANUAL_FILE="$tmp/manual" \
	IKEV2_MANUAL_CIDR_FILE="$tmp/manual-cidrs" \
	IKEV2_SELECTED_FILE="$tmp/selected" \
	IKEV2_FINAL_FILE="$tmp/domains" \
	IKEV2_CIDR_FILE="$tmp/cidrs" \
	IKEV2_CACHE_DIR="$tmp/cache" \
	IKEV2_STATUS_FILE="$tmp/status" \
	IKEV2_LOG_FILE="$tmp/log" \
	IKEV2_LOCK_DIR="$tmp/lock" \
	IKEV2_PENDING_FILE="$tmp/pending" \
	IKEV2_RESTART_HELPER="$tmp/bin/restart-helper" \
	IKEV2_LOCAL_SERVICES_DIR="$tmp/local" \
	IKEV2_RAW_BASE=https://lists.invalid \
		sh "$root/luci-ikev2-domains/community-domains.sh" "$@"
}

run_helper apply
printf '%s\n' direct.example local.example remote.example |
	cmp -s - "$tmp/domains"
printf '%s\n' 149.154.160.0/20 198.51.100.0/24 203.0.113.10/32 91.108.4.0/22 |
	cmp -s - "$tmp/cidrs"
grep -q '^services=3$' "$tmp/status"
grep -q '^domains=3$' "$tmp/status"
grep -q '^cidrs=4$' "$tmp/status"
grep -q '^custom_cidrs=2$' "$tmp/status"
grep -q '^selected=direct,local,remote$' "$tmp/status"
[ "$(run_helper ip-services)" = direct ]

cp "$tmp/domains" "$tmp/domains.before"
cp "$tmp/cidrs" "$tmp/cidrs.before"
printf '%s\n' '999.1.1.1/33' >"$tmp/local/direct.cidrs"
if run_helper apply >/dev/null 2>&1; then
	printf 'invalid CIDR unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/domains.before" "$tmp/domains"
cmp -s "$tmp/cidrs.before" "$tmp/cidrs"

printf 'community domain tests OK\n'
