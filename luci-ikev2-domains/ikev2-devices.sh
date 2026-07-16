#!/bin/sh
# /usr/libexec/ikev2-devices
# Per-device PBR routing mode manager for ikev2out policies.
#
# Commands:
#   dump                         — list current state (domain/fullroute/exclude)
#   zones                        — list firewall zones and their logical networks
#   add-subnet    <addr>         — add addr to the base domain policy
#   remove-subnet <addr>         — remove addr from the base domain policy
#   add-override  <addr> <mode>  — mode: fullroute | exclude
#   remove-override <addr>       — remove fullroute/exclude policy for addr

set -u

BASE_RULE='ikev2pbr_domains'
APP_CONFIG='ikev2-manager'
APP_SECTION='domains'
DEST_FILES='file:///etc/pbr-ikev2-domains.txt file:///etc/pbr-ikev2-service-cidrs.txt'
RESTART_HELPER="${IKEV2_RESTART_HELPER:-/usr/libexec/ikev2-domains-restart}"

valid_addr() {
    [ -n "$1" ] || return 1
    printf '%s' "$1" | grep -Eq '^[0-9.]+(/[0-9]{1,2})?$' || return 1
    # ipcalc.sh needs a prefix; treat a bare IP as /32 for validation.
    case "$1" in
        */*) ipcalc.sh "$1" >/dev/null 2>&1 ;;
        *)   ipcalc.sh "$1/32" >/dev/null 2>&1 ;;
    esac
}

sanitize() { printf '%s' "$1" | tr './:-' '____'; }
fr_sec()   { printf 'pbr_dev_fr_%s' "$(sanitize "$1")"; }
ex_sec()   { printf 'pbr_dev_ex_%s' "$(sanitize "$1")"; }

# Return 0-based position of BASE_RULE among all named sections in pbr config.
base_pos() {
    uci show pbr 2>/dev/null \
        | grep -E '^pbr\.[^.=]+=[a-z_]+$' \
        | sed 's/^pbr\.\([^=]*\)=.*/\1/' \
        | awk -v t="$BASE_RULE" '{ if ($0 == t) { print NR-1; exit } }'
}

# Commit, optionally reorder sec before BASE_RULE, then synchronously verify
# PBR. On any failure put the exact previous UCI package back and re-apply it.
restore_pbr() {
	local backup="$1"
	uci import pbr <"$backup/pbr" >/dev/null 2>&1 || true
	uci import "$APP_CONFIG" <"$backup/app" >/dev/null 2>&1 || true
	uci commit pbr >/dev/null 2>&1 || true
	uci commit "$APP_CONFIG" >/dev/null 2>&1 || true
	if [ "${IKEV2_ACTION_LOCK_HELD:-0}" = 1 ]; then
		"$RESTART_HELPER" --wait --lock-held >/dev/null 2>&1 || true
	else
		"$RESTART_HELPER" --wait >/dev/null 2>&1 || true
	fi
	rm -rf "$backup"
}

commit_and_restart() {
	local backup="$1" sec="${2:-}" pos result=0
	uci commit pbr || result=1
	uci commit "$APP_CONFIG" || result=1
	if [ -n "$sec" ]; then
		pos=$(base_pos)
		if [ -n "$pos" ]; then
			uci reorder "pbr.${sec}=${pos}" || result=1
			uci commit pbr || result=1
		else
			result=1
		fi
    fi
    if [ "$result" = 0 ]; then
        if [ "${IKEV2_ACTION_LOCK_HELD:-0}" = 1 ]; then
            "$RESTART_HELPER" --wait --lock-held || result=1
        else
            "$RESTART_HELPER" --wait || result=1
        fi
	fi
	if [ "$result" != 0 ]; then
		restore_pbr "$backup"
		return 1
    fi
	rm -rf "$backup"
}

backup_pbr() {
	local backup
	backup="$(mktemp -d)" || return 1
	if ! uci export pbr >"$backup/pbr" ||
	   ! uci export "$APP_CONFIG" >"$backup/app"; then
		rm -rf "$backup"
		return 1
    fi
    printf '%s\n' "$backup"
}

device_sources() {
	local src item result=''
	src="$(uci -q get "${APP_CONFIG}.${APP_SECTION}.device_source" 2>/dev/null || true)"
	if [ -z "$src" ]; then
		src="$(uci -q get "pbr.${BASE_RULE}.src_addr" 2>/dev/null || true)"
	fi
	for item in $src; do
		case "$item" in @*) continue ;; esac
		result="${result:+$result }$item"
	done
	printf '%s\n' "$result"
}

set_device_sources() {
	local item
	uci -q delete "${APP_CONFIG}.${APP_SECTION}.device_source" || true
	for item in $1; do
		uci add_list "${APP_CONFIG}.${APP_SECTION}.device_source=$item" || return 1
	done
}

cmd_dump() {
    local src a sec name tmpfile

	# Domain-mode addresses are persisted in the app config and rendered to PBR.
	src="$(device_sources)"
	for a in $src; do
		printf 'addr=%s mode=domain\n' "$a"
    done

    # Override policies: recognised by name prefix set by this tool
    tmpfile=$(mktemp)
    uci show pbr 2>/dev/null \
        | grep -E '^pbr\.[^.=]+=[a-z_]+$' \
        | sed 's/^pbr\.\([^=]*\)=.*/\1/' > "$tmpfile"

    while IFS= read -r sec; do
        name=$(uci -q get "pbr.${sec}.name" 2>/dev/null || true)
        case "$name" in
            'VPN Full Route: '*)
                printf 'addr=%s mode=fullroute section=%s\n' \
                    "${name#VPN Full Route: }" "$sec"
                ;;
            'VPN Exclude: '*)
                printf 'addr=%s mode=exclude section=%s\n' \
                    "${name#VPN Exclude: }" "$sec"
                ;;
        esac
    done < "$tmpfile"
    rm -f "$tmpfile"
}

cmd_add_subnet() {
    local addr="${1:-}" src a backup
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

	src="$(device_sources)"
    for a in $src; do [ "$a" = "$addr" ] && return 0; done

	backup="$(backup_pbr)" || return 1
	set_device_sources "${src:+$src }$addr" || {
		restore_pbr "$backup"
		return 1
	}
    commit_and_restart "$backup"
}

cmd_remove_subnet() {
    local addr="${1:-}" src a new='' backup
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

	src="$(device_sources)"
    for a in $src; do
        [ "$a" != "$addr" ] && new="${new:+$new }$a"
    done
	backup="$(backup_pbr)" || return 1
	set_device_sources "$new" || {
		restore_pbr "$backup"
		return 1
	}
    commit_and_restart "$backup"
}

cmd_add_override() {
    local addr="${1:-}" mode="${2:-}" sec backup
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	case "$mode" in
		fullroute | exclude) ;;
		*) printf 'unknown mode: %s\n' "$mode" >&2; return 1 ;;
	esac

    backup="$(backup_pbr)" || return 1

    # Remove any existing override for this addr before re-adding
    uci -q delete "pbr.$(fr_sec "$addr")" 2>/dev/null || true
    uci -q delete "pbr.$(ex_sec "$addr")" 2>/dev/null || true

	case "$mode" in
		fullroute)
			sec=$(fr_sec "$addr")
			if ! uci set "pbr.${sec}=policy" ||
			   ! uci set "pbr.${sec}.name=VPN Full Route: $addr" ||
			   ! uci set "pbr.${sec}.interface=ikev2out" ||
			   ! uci set "pbr.${sec}.src_addr=$addr" ||
			   ! uci set "pbr.${sec}.proto=all" ||
			   ! uci set "pbr.${sec}.enabled=1"; then
				restore_pbr "$backup"
				return 1
			fi
			;;
		exclude)
			sec=$(ex_sec "$addr")
			if ! uci set "pbr.${sec}=policy" ||
			   ! uci set "pbr.${sec}.name=VPN Exclude: $addr" ||
			   ! uci set "pbr.${sec}.interface=$(uci -q get ikev2-manager.globals.wan_interface || echo wan)" ||
			   ! uci set "pbr.${sec}.src_addr=$addr" ||
			   ! uci set "pbr.${sec}.dest_addr=$DEST_FILES" ||
			   ! uci set "pbr.${sec}.proto=all" ||
			   ! uci set "pbr.${sec}.enabled=1"; then
				restore_pbr "$backup"
				return 1
			fi
			;;
	esac
    # commit_and_restart with sec triggers uci reorder to place before BASE_RULE
    commit_and_restart "$backup" "$sec"
}

cmd_remove_override() {
    local addr="${1:-}" backup
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

    backup="$(backup_pbr)" || return 1
    uci -q delete "pbr.$(fr_sec "$addr")" 2>/dev/null || true
    uci -q delete "pbr.$(ex_sec "$addr")" 2>/dev/null || true
    commit_and_restart "$backup"
}

# List logical OpenWrt networks that have an IPv4 subnet, as name=CIDR lines.
# Used by the UI to offer a pick-list instead of free-text subnet entry.
cmd_networks() {
    local names n st addr mask
    names=$(ubus call network.interface dump 2>/dev/null \
        | jsonfilter -e '@.interface[*].interface' 2>/dev/null)
    for n in $names; do
        case "$n" in loopback|lo|ikev2out|'') continue ;; esac
        st=$(ubus call network.interface."$n" status 2>/dev/null) || continue
        addr=$(printf '%s' "$st" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        mask=$(printf '%s' "$st" | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null)
        [ -n "$addr" ] && [ -n "$mask" ] || continue
        calc="$(ipcalc.sh "$addr/$mask" 2>/dev/null || true)"
        NETWORK="$(printf '%s\n' "$calc" | sed -n 's/^NETWORK=//p' | head -n1)"
        PREFIX="$(printf '%s\n' "$calc" | sed -n 's/^PREFIX=//p' | head -n1)"
        [ -n "$NETWORK" ] || continue
        printf '%s=%s/%s\n' "$n" "$NETWORK" "${PREFIX:-$mask}"
    done
}

# List firewall zones as name=network1 network2 lines. Keeping this beside the
# logical-network enumerator gives LuCI one authoritative source for pickers and
# avoids asking users to type UCI zone names.
cmd_zones() {
	local sections section name networks
	sections="$(uci show firewall 2>/dev/null \
		| sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p')"
	for section in $sections; do
		name="$(uci -q get "firewall.$section.name" 2>/dev/null || true)"
		[ -n "$name" ] || continue
		networks="$(uci -q get "firewall.$section.network" 2>/dev/null || true)"
		printf '%s=%s\n' "$name" "$networks"
	done
}

case "${1:-}" in
    dump)             cmd_dump ;;
    networks)         cmd_networks ;;
	zones)            cmd_zones ;;
    add-subnet)       cmd_add_subnet "${2:-}" ;;
    remove-subnet)    cmd_remove_subnet "${2:-}" ;;
    add-override)     cmd_add_override "${2:-}" "${3:-}" ;;
    remove-override)  cmd_remove_override "${2:-}" ;;
    *)
        printf 'usage: %s {dump|networks|zones|add-subnet <addr>|remove-subnet <addr>|add-override <addr> <mode>|remove-override <addr>}\n' "$0" >&2
        exit 1 ;;
esac
