#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

action_status_file="$tmp/latest.status"
action_status_dir="$tmp/actions"
action_lock_dir="$tmp/action.lock"
action_lock_status="$tmp/action.lock.status"

# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/actions.sh"

action_status test-1 running 'Testing shared actions'
grep -q '^action_id=test-1$' "$action_status_file"
grep -q '^state=running$' "$action_status_file"
grep -q '^message=Testing shared actions$' "$action_status_file"
acquire_action_lock tests test-1
grep -q '^owner=tests$' "$action_lock_status"
rm -f "$action_lock_status"
rmdir "$action_lock_dir"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	"-4 route show table pbr_ikev2out")
		[ "${MOCK_FAILCLOSED_MISSING:-0}" = 1 ] || echo 'unreachable default metric 32767'
		;;
	"-4 route get "*)
		echo 'RTNETLINK answers: Network is unreachable' >&2
		exit 2
		;;
	*) ;;
esac
EOF
chmod 755 "$tmp/bin/ip"

PATH="$tmp/bin:$PATH"
export PATH
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/routing.sh"

failclosed_check
if MOCK_FAILCLOSED_MISSING=1 failclosed_check; then
	echo 'failclosed_check accepted a table without unreachable default' >&2
	exit 1
fi

printf 'runtime module tests OK\n'
