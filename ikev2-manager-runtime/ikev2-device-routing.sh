#!/bin/sh

set -u

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_DEVICE_TABLE:-ikev2_device_policy}"
signature_file="${IKEV2_DEVICE_SIGNATURE:-/var/run/ikev2-device-routing.signature}"

runtime_exists() {
	"$nft_bin" list table inet "$table" >/dev/null 2>&1
}

runtime_owned() {
	"$nft_bin" list table inet "$table" 2>/dev/null |
		grep -Fq 'chain ikev2_manager_owned'
}

stop_runtime() {
	if runtime_exists; then
		runtime_owned || {
			printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
			return 1
		}
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	rm -f "$signature_file"
}

pbr_mark_rule() {
	lookup="$1"
	ip -4 rule show 2>/dev/null |
		awk -v table="$lookup" '
			$0 ~ ("lookup " table "([[:space:]]|$)") {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		'
}

mark_values() {
	rule="$1"
	case "$rule" in
		0x[0-9A-Fa-f]*/0x[0-9A-Fa-f]*) ;;
		*) return 1 ;;
	esac
	mark="${rule%%/*}"
	mask="${rule#*/}"
	mark_value=$((mark))
	mask_value=$((mask))
	clear_value=$((0xffffffff ^ mask_value))
	printf '%s %s\n' "$(printf '0x%08x' "$clear_value")" \
		"$(printf '0x%08x' "$mark_value")"
}

valid_ipv4_source() {
	case "$1" in '' | *[!0-9./]*) return 1 ;; esac
	case "$1" in
		*/*) ipcalc.sh "$1" >/dev/null 2>&1 ;;
		*) ipcalc.sh "$1/32" >/dev/null 2>&1 ;;
	esac
}

collect_sources() {
	full="$1"
	excluded="$2"
	: >"$full"
	: >"$excluded"
	for section in $(uci show pbr 2>/dev/null |
		sed -n 's/^pbr\.\([^.=]*\)=policy$/\1/p'); do
		name="$(uci -q get "pbr.$section.name" 2>/dev/null || true)"
		case "$name" in
			'VPN Full Route: '*) target="$full" ;;
			'VPN Exclude: '*) target="$excluded" ;;
			*) continue ;;
		esac
		[ "$(uci -q get "pbr.$section.enabled" 2>/dev/null || echo 1)" = 1 ] || continue
		for source in $(uci -q get "pbr.$section.src_addr" 2>/dev/null || true); do
			case "$source" in @*) continue ;; esac
			valid_ipv4_source "$source" || return 1
			printf '%s\n' "$source" >>"$target"
		done
	done
	for file in "$full" "$excluded"; do
		sort -u "$file" >"${file}.sorted" || return 1
		mv "${file}.sorted" "$file" || return 1
	done
}

set_elements() {
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}

write_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ipv4_addr\n    flags interval\n' "$name"
	if [ -s "$file" ]; then
		printf '    elements = { '
		set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

sync_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		stop_runtime
		return $?
	}
	ike_values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")" || {
		printf '%s\n' 'Unable to derive the active IKEv2 PBR mark' >&2
		return 1
	}
	wan_values="$(mark_values "$(pbr_mark_rule pbr_wan)")" || {
		printf '%s\n' 'Unable to derive the active WAN PBR mark' >&2
		return 1
	}
	ike_clear="${ike_values%% *}"
	ike_mark="${ike_values#* }"
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"

	work="${TMPDIR:-/tmp}/ikev2-device-routing.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	full="$work/full"
	excluded="$work/excluded"
	collect_sources "$full" "$excluded" || return 1

	signature="$({
		printf 'ike=%s/%s\nwan=%s/%s\nfull\n' "$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark"
		cat "$full"
		printf 'excluded\n'
		cat "$excluded"
	} | sha256sum | awk '{ print $1 }')"
	if runtime_owned && [ "$(cat "$signature_file" 2>/dev/null || true)" = "$signature" ]; then
		rm -rf "$work"
		trap - EXIT INT TERM
		return 0
	fi
	if runtime_exists && ! runtime_owned; then
		printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
		return 1
	fi

	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager device routing"
  }

EOF
		write_set full_route_ipv4 "$full"
		write_set exclude_ipv4 "$excluded"
		cat <<EOF
  chain prerouting {
    type filter hook prerouting priority -152; policy accept;
    ip saddr @exclude_ipv4 meta mark set meta mark & $wan_clear | $wan_mark counter accept
    ip saddr @full_route_ipv4 meta mark set meta mark & $ike_clear | $ike_mark counter accept
  }
}
EOF
	} >"$rules"
	"$nft_bin" -c -f "$rules" >/dev/null 2>&1 || {
		printf '%s\n' 'Device-routing nftables validation failed' >&2
		return 1
	}
	"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
		printf '%s\n' 'Unable to install device-routing nftables rules' >&2
		return 1
	}
	mkdir -p "${signature_file%/*}"
	printf '%s\n' "$signature" >"${signature_file}.new"
	mv "${signature_file}.new" "$signature_file"
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		! runtime_exists
		return
	}
	runtime_owned || return 1
	"$nft_bin" list chain inet "$table" prerouting 2>/dev/null | grep -Fq 'chain prerouting'
}

case "${1:-sync}" in
	sync) sync_runtime ;;
	stop) stop_runtime ;;
	check) check_runtime ;;
	*) printf 'usage: %s [sync|stop|check]\n' "$0" >&2; exit 2 ;;
esac
