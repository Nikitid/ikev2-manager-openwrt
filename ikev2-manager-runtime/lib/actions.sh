#!/bin/sh
# Shared detached-action primitives for IKEv2 Manager backends.
#
# Callers provide:
#   action_status_file, action_status_dir, action_lock_dir, action_lock_status
#   run_action(), die()

action_status() {
	mkdir -p "$action_status_dir"
	{
		printf 'action_id=%s\n' "$1"
		printf 'state=%s\n' "$2"
		printf 'updated=%s\n' "$(date +%s)"
		[ -z "${3:-}" ] || printf 'message=%s\n' "$3"
	} >"$action_status_dir/$1.status.new"
	mv "$action_status_dir/$1.status.new" "$action_status_dir/$1.status"
	cp "$action_status_dir/$1.status" "${action_status_file}.new"
	mv "${action_status_file}.new" "$action_status_file"
}

acquire_action_lock() {
	owner="$1"
	id="$2"
	tries=0
	while ! mkdir "$action_lock_dir" 2>/dev/null; do
		updated="$(sed -n 's/^updated=//p' "$action_lock_status" 2>/dev/null | tail -1)"
		pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
		now="$(date +%s)"
		if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null ||
		   { [ -n "$updated" ] && [ $((now - updated)) -gt 3600 ]; }; then
			rm -f "$action_lock_status"
			rmdir "$action_lock_dir" 2>/dev/null || :
			continue
		fi
		tries=$((tries + 1))
		[ "$tries" -lt 180 ] || return 1
		sleep 1
	done
	printf 'owner=%s\naction_id=%s\npid=%s\nupdated=%s\n' \
		"$owner" "$id" "$$" "$(date +%s)" >"$action_lock_status"
}

start_action() {
	kind="$1"
	shift
	id="$(date +%s)-$$"
	find "$action_status_dir" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || :
	action_status "$id" running 'Queued...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _action-run "$id" "$kind" "$@"; then
			action_status "$id" error 'Unable to start background action.'
			die 'Unable to start background action'
		fi
	else
		setsid "$0" _action-run "$id" "$kind" "$@" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$id"
}
