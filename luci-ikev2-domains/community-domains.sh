#!/bin/sh

set -u

manual_file="${IKEV2_MANUAL_FILE:-/etc/pbr-ikev2-domains.manual.txt}"
selected_file="${IKEV2_SELECTED_FILE:-/etc/pbr-ikev2-community-selected.txt}"
final_file="${IKEV2_FINAL_FILE:-/etc/pbr-ikev2-domains.txt}"
catalog_file="${IKEV2_CATALOG_FILE:-/usr/share/ikev2-domains/community-services}"
cache_dir="${IKEV2_CACHE_DIR:-/etc/pbr-ikev2-community-cache}"
status_file="${IKEV2_STATUS_FILE:-/tmp/ikev2-domains-community.status}"
log_file="${IKEV2_LOG_FILE:-/tmp/ikev2-domains-community.log}"
lock_dir="${IKEV2_LOCK_DIR:-/var/run/ikev2-domains-community.lock}"
pending_file="${IKEV2_PENDING_FILE:-/var/run/ikev2-domains-community.pending}"
restart_helper="${IKEV2_RESTART_HELPER:-/usr/libexec/ikev2-domains-restart}"
catalog_url="${IKEV2_CATALOG_URL:-https://api.github.com/repos/itdoginfo/allow-domains/contents/Services}"
raw_base="${IKEV2_RAW_BASE:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services}"
local_services_dir="${IKEV2_LOCAL_SERVICES_DIR:-/usr/share/ikev2-domains/local-services}"
max_catalog_bytes="${IKEV2_MAX_CATALOG_BYTES:-1048576}"
max_service_bytes="${IKEV2_MAX_SERVICE_BYTES:-1048576}"

normalize_domains() {
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "" || substr(line, 1, 1) == "#")
				next
			if (line !~ /^[a-z0-9._-]+$/ || line ~ /\.\./ ||
			    line ~ /^-/ || line ~ /-$/) {
				printf "invalid domain: %s\n", line > "/dev/stderr"
				exit 1
			}
			print line
		}
	' "$1"
}

normalize_services() {
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "")
				next
			if (line !~ /^[a-z0-9_]+$/) {
				printf "invalid service: %s\n", line > "/dev/stderr"
				exit 1
			}
			print line
		}
	' "$1" | sort -u
}

refresh_catalog() {
	local tmp_json tmp_catalog downloaded_size

	tmp_json="$(mktemp)"
	tmp_catalog="$(mktemp)"

	if uclient-fetch -q -T 15 -O "$tmp_json" "$catalog_url"; then
		downloaded_size="$(wc -c < "$tmp_json" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_catalog_bytes" ] &&
		jsonfilter -i "$tmp_json" -e '@[*].name' |
			sed -n 's/\.lst$//p' |
			awk '/^[a-z0-9_]+$/' |
			sort -u > "$tmp_catalog" &&
		[ -s "$tmp_catalog" ]; then
		mv "$tmp_catalog" "$catalog_file"
	else
		rm -f "$tmp_catalog"
		if [ "$downloaded_size" -gt "$max_catalog_bytes" ]; then
			echo 'downloaded service catalog exceeds size limit' >&2
		fi
	fi

	rm -f "$tmp_json"
}

download_service() {
	local service="$1" destination="$2" cached="$cache_dir/$service.lst"
	local downloaded normalized downloaded_size

	# Check local bundled services first — no download needed
	if [ -s "$local_services_dir/$service.lst" ]; then
		cp "$local_services_dir/$service.lst" "$destination"
		return 0
	fi

	downloaded="$(mktemp)"
	normalized="$(mktemp)"

	if uclient-fetch -q -T 20 -O "$downloaded" "$raw_base/$service.lst"; then
		downloaded_size="$(wc -c < "$downloaded" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_service_bytes" ] &&
		normalize_domains "$downloaded" | sort -u > "$normalized" &&
		[ -s "$normalized" ]; then
		mkdir -p "$cache_dir"
		cp "$normalized" "$cached.tmp"
		mv "$cached.tmp" "$cached"
		cp "$normalized" "$destination"
		rm -f "$downloaded" "$normalized"
		return 0
	fi

	if [ "$downloaded_size" -gt "$max_service_bytes" ]; then
		echo "downloaded service exceeds size limit: $service" >&2
	fi

	rm -f "$downloaded" "$normalized"
	if [ -s "$cached" ]; then
		cp "$cached" "$destination"
		echo "$service" >> "$destination.stale"
		return 0
	fi

	echo "unable to download service without cache: $service" >&2
	return 1
}

apply_once() {
	local work selected normalized_manual service failed stale
	local selected_count domain_count pids pid action_id
	action_id="${1:-}"

	work="$(mktemp -d)"
	selected="$work/selected"
	normalized_manual="$work/manual"
	failed=0
	pids=''

	[ -f "$manual_file" ] || cp "$final_file" "$manual_file"
	[ -f "$selected_file" ] || : > "$selected_file"

	if ! normalize_domains "$manual_file" | sort -u > "$normalized_manual"; then
		rm -rf "$work"
		return 1
	fi

	if ! normalize_services "$selected_file" > "$selected"; then
		rm -rf "$work"
		return 1
	fi

	while IFS= read -r service; do
		[ -n "$service" ] || continue
		download_service "$service" "$work/$service.lst" &
		pids="$pids $!"
	done < "$selected"

	for pid in $pids; do
		wait "$pid" || failed=1
	done

	if [ "$failed" -ne 0 ]; then
		rm -rf "$work"
		return 1
	fi

	{
		cat "$normalized_manual"
		for service in $(cat "$selected"); do
			cat "$work/$service.lst"
		done
	} | sort -u > "$work/final"

	# An empty result is only legitimate when the user intentionally cleared
	# everything (no manual domains AND no community services selected). If
	# services were selected we must have content here — an empty list then
	# means a download glitch, so we keep the previous list instead.
	if [ ! -s "$work/final" ] && [ -s "$selected" ]; then
		echo 'refusing to install an empty domain list (services selected but no domains resolved)' >&2
		rm -rf "$work"
		return 1
	fi

	cp "$work/final" "$final_file.tmp"
	chmod 600 "$final_file.tmp"
	mv "$final_file.tmp" "$final_file"

	selected_count="$(wc -l < "$selected" | tr -d ' ')"
	domain_count="$(wc -l < "$work/final" | tr -d ' ')"
	stale="$(cat "$work"/*.stale 2>/dev/null | sort -u | tr '\n' ' ')"

	{
		[ -z "$action_id" ] || echo "action_id=$action_id"
		echo "state=ok"
		echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
		echo "services=$selected_count"
		echo "domains=$domain_count"
		[ -z "$stale" ] || echo "cached_services=$stale"
	} > "$status_file"

	rm -rf "$work"
	"$restart_helper"
}

run_scheduled() {
	sleep 1
	mkdir "$lock_dir" 2>/dev/null || exit 0
	trap 'rmdir "$lock_dir"' EXIT INT TERM

	while [ -e "$pending_file" ]; do
		action_id="$(cat "$pending_file" 2>/dev/null || true)"
		rm -f "$pending_file"
		if ! apply_once "$action_id" >> "$log_file" 2>&1; then
			{
				[ -z "$action_id" ] || echo "action_id=$action_id"
				echo "state=error"
				echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
				echo "message=Community update failed; previous combined list preserved"
			} > "$status_file"
		fi
	done
}

case "${1:-}" in
	catalog)
		if [ ! -s "$catalog_file" ] ||
			find "$catalog_file" -mtime +0 -print | grep -q .; then
			refresh_catalog
		fi
		{
			cat "$catalog_file" 2>/dev/null
			ls -1 "$local_services_dir"/*.lst 2>/dev/null \
				| sed 's|.*/||;s/\.lst$//'
		} | sort -u
		;;
	schedule)
		action_id="$(date +%s)-$$"
		printf '%s\n' "$action_id" > "$pending_file"
		# rpcd's `file exec` reads the child's stdout until EOF, so a plain
		# background/setsid job keeps the pipe open and the caller blocks until
		# the ubus timeout (~30s). start-stop-daemon -b fully daemonizes —
		# closing every inherited descriptor — so rpcd gets EOF immediately and
		# the rebuild proceeds detached.
		if command -v start-stop-daemon >/dev/null 2>&1; then
			start-stop-daemon -b -q -S -x "$0" -- _run
		else
			setsid "$0" _run </dev/null >/dev/null 2>&1 &
		fi
		printf 'action_id=%s\n' "$action_id"
		;;
	_run)
		run_scheduled
		;;
	apply)
		apply_once
		;;
	*)
		echo "usage: $0 {catalog|schedule|apply}" >&2
		exit 2
		;;
esac
