#!/bin/sh
# /usr/libexec/ikev2-devices
# Per-device PBR routing mode manager for ikev2out policies.
#
# Commands:
#   dump                         — list current state (domain/fullroute/exclude)
#   add-subnet    <addr>         — add addr to the base domain policy
#   remove-subnet <addr>         — remove addr from the base domain policy
#   add-override  <addr> <mode>  — mode: fullroute | exclude
#   remove-override <addr>       — remove fullroute/exclude policy for addr

set -u

BASE_RULE='ikev2pbr_domains'
DEST_FILES='file:///etc/pbr-ikev2-domains.txt file:///etc/pbr-ikev2-service-cidrs.txt'
RESTART_HELPER='/usr/libexec/ikev2-domains-restart'

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

# Commit, optionally reorder sec before BASE_RULE, then restart PBR.
commit_and_restart() {
    local sec="${1:-}"
    uci commit pbr
    if [ -n "$sec" ]; then
        local pos
        pos=$(base_pos)
        if [ -n "$pos" ]; then
            uci reorder "pbr.${sec}=${pos}"
            uci commit pbr
        fi
    fi
    "$RESTART_HELPER"
}

cmd_dump() {
    local src a sec name tmpfile

    # Domain-mode addresses live in base rule src_addr
    src=$(uci -q get "pbr.${BASE_RULE}.src_addr" 2>/dev/null || true)
    for a in $src; do
        case "$a" in @*) continue ;; esac
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
    local addr="${1:-}" src a
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

    src=$(uci -q get "pbr.${BASE_RULE}.src_addr" 2>/dev/null || true)
    for a in $src; do [ "$a" = "$addr" ] && return 0; done

    uci set "pbr.${BASE_RULE}.src_addr=${src:+$src }$addr"
    commit_and_restart
}

cmd_remove_subnet() {
    local addr="${1:-}" src a new=''
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

    src=$(uci -q get "pbr.${BASE_RULE}.src_addr" 2>/dev/null || true)
    for a in $src; do
        [ "$a" != "$addr" ] && new="${new:+$new }$a"
    done
    uci set "pbr.${BASE_RULE}.src_addr=$new"
    commit_and_restart
}

cmd_add_override() {
    local addr="${1:-}" mode="${2:-}" sec
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
    [ -n "$mode" ] || { printf 'mode required\n' >&2; exit 1; }

    # Remove any existing override for this addr before re-adding
    uci -q delete "pbr.$(fr_sec "$addr")" 2>/dev/null || true
    uci -q delete "pbr.$(ex_sec "$addr")" 2>/dev/null || true

    case "$mode" in
        fullroute)
            sec=$(fr_sec "$addr")
            uci set "pbr.${sec}=policy"
            uci set "pbr.${sec}.name=VPN Full Route: $addr"
            uci set "pbr.${sec}.interface=ikev2out"
            uci set "pbr.${sec}.src_addr=$addr"
            uci set "pbr.${sec}.proto=all"
            uci set "pbr.${sec}.enabled=1"
            ;;
        exclude)
            sec=$(ex_sec "$addr")
            uci set "pbr.${sec}=policy"
            uci set "pbr.${sec}.name=VPN Exclude: $addr"
            uci set "pbr.${sec}.interface=$(uci -q get ikev2-manager.globals.wan_interface || echo wan)"
            uci set "pbr.${sec}.src_addr=$addr"
            uci set "pbr.${sec}.dest_addr=$DEST_FILES"
            uci set "pbr.${sec}.proto=all"
            uci set "pbr.${sec}.enabled=1"
            ;;
        *)
            printf 'unknown mode: %s\n' "$mode" >&2
            exit 1 ;;
    esac
    # commit_and_restart with sec triggers uci reorder to place before BASE_RULE
    commit_and_restart "$sec"
}

cmd_remove_override() {
    local addr="${1:-}"
    valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

    uci -q delete "pbr.$(fr_sec "$addr")" 2>/dev/null || true
    uci -q delete "pbr.$(ex_sec "$addr")" 2>/dev/null || true
    commit_and_restart
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
        NETWORK=''; PREFIX=''
        eval "$(ipcalc.sh "$addr/$mask" 2>/dev/null)"
        [ -n "$NETWORK" ] || continue
        printf '%s=%s/%s\n' "$n" "$NETWORK" "${PREFIX:-$mask}"
    done
}

case "${1:-}" in
    dump)             cmd_dump ;;
    networks)         cmd_networks ;;
    add-subnet)       cmd_add_subnet "${2:-}" ;;
    remove-subnet)    cmd_remove_subnet "${2:-}" ;;
    add-override)     cmd_add_override "${2:-}" "${3:-}" ;;
    remove-override)  cmd_remove_override "${2:-}" ;;
    *)
        printf 'usage: %s {dump|networks|add-subnet <addr>|remove-subnet <addr>|add-override <addr> <mode>|remove-override <addr>}\n' "$0" >&2
        exit 1 ;;
esac
