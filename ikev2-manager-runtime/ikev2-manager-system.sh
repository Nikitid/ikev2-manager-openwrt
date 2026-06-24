#!/bin/sh
# IKEv2 Manager for OpenWrt compatibility and runtime controller.

set -eu

uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

config='ikev2-manager'

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

getv() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

get_list() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

defaultv() {
	value="$(getv "$1" "$2")"
	printf '%s\n' "${value:-$3}"
}

valid_name_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for item in $value; do
		valid_name "$item" || return 1
	done
}

set_list() {
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$config.$section.$option" || true
	for item in $value; do
		uci add_list "$config.$section.$option=$item"
	done
}

add_list_unique() {
	package="$1"
	section="$2"
	option="$3"
	value="$4"
	current="$(uci -q get "$package.$section.$option" 2>/dev/null || true)"
	for item in $current; do
		[ "$item" = "$value" ] && return 0
	done
	uci add_list "$package.$section.$option=$value"
}

domain_file_has_entries() {
	awk 'NF && $1 !~ /^#/ { found = 1 } END { exit found ? 0 : 1 }' "$1" 2>/dev/null
}

delete_prefixed_sections() {
	package="$1"
	prefix="$2"
	uci show "$package" 2>/dev/null |
		sed -n "s/^${package}\.\(${prefix}[A-Za-z0-9_]*\)=.*/\1/p" |
		sort -u |
		while IFS= read -r section; do
			[ -n "$section" ] && uci -q delete "$package.$section"
		done
}

delete_sections() {
	package="$1"
	shift
	for section in "$@"; do
		uci -q delete "$package.$section" || true
	done
}

sanitize() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

network_device() {
	interface="$1"
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	[ -n "$device" ] && printf '%s\n' "$device"
}

gateway_network() {
	gateway="$(getv server gateway4)"
	[ -n "$gateway" ] || return 0
	ipcalc.sh "$gateway" 2>/dev/null |
		awk -F= '/^NETWORK=/{network=$2}/^PREFIX=/{prefix=$2}END{if(network!=""&&prefix!="")print network "/" prefix}'
}

zone_exists() {
	zone="$1"
	uci show firewall 2>/dev/null |
		grep -Fq ".name='$zone'"
}

compatibility_checks() {
	release_id='unknown'
	release='unknown'
	target='unknown'
	arch='unknown'
	if [ -r /etc/openwrt_release ]; then
		. /etc/openwrt_release
		release_id="${DISTRIB_ID:-unknown}"
		release="${DISTRIB_RELEASE:-unknown}"
		target="${DISTRIB_TARGET:-unknown}"
		arch="${DISTRIB_ARCH:-unknown}"
	fi

	board_json="$(ubus call system board 2>/dev/null || true)"
	board_model="$(printf '%s' "$board_json" | jsonfilter -e '@.model' 2>/dev/null || true)"
	board_name="$(printf '%s' "$board_json" | jsonfilter -e '@.board_name' 2>/dev/null || true)"
	printf 'board_model=ok:%s\n' "${board_model:-unknown}"
	printf 'board_name=ok:%s\n' "${board_name:-unknown}"
	printf 'target=ok:%s\n' "$target"
	printf 'architecture=ok:%s\n' "$arch"
	printf 'kernel=ok:%s\n' "$(uname -r 2>/dev/null || echo unknown)"

	if [ "$release_id" = OpenWrt ]; then
		printf 'firmware_source=ok:official\n'
	else
		printf 'firmware_source=unsupported:%s\n' "$release_id"
		ok=0
	fi
	case "$release" in
		24.10.*) printf 'openwrt=ok:%s\n' "$release" ;;
		25.12.*)
			printf 'openwrt=unsupported:%s-apk-not-supported\n' "$release"
			ok=0
			;;
		*)
			printf 'openwrt=unsupported:%s\n' "$release"
			ok=0
			;;
	esac

	if command -v opkg >/dev/null 2>&1; then
		printf 'package_manager=ok:opkg\n'
	else
		if command -v apk >/dev/null 2>&1; then
			printf 'package_manager=unsupported:apk\n'
		else
			printf 'package_manager=missing\n'
		fi
		ok=0
	fi
	if grep -qE 'downloads\.openwrt\.org/releases/24\.10\.' \
		/etc/opkg/distfeeds.conf 2>/dev/null; then
		printf 'package_feeds=ok:official\n'
	else
		printf 'package_feeds=unsupported:non-release-or-vendor\n'
		ok=0
	fi

	overlay_free="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
	[ -n "$overlay_free" ] ||
		overlay_free="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${overlay_free:-0}" in *[!0-9]*) overlay_free=0 ;; esac
	if [ "$overlay_free" -ge 12288 ]; then
		printf 'storage_free=ok:%sKiB\n' "$overlay_free"
	else
		printf 'storage_free=low:%sKiB\n' "$overlay_free"
		ok=0
	fi

	tmp_free="$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${tmp_free:-0}" in *[!0-9]*) tmp_free=0 ;; esac
	if [ "$tmp_free" -ge 16384 ]; then
		printf 'tmp_free=ok:%sKiB\n' "$tmp_free"
	else
		printf 'tmp_free=low:%sKiB\n' "$tmp_free"
		ok=0
	fi

	mem_available="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	case "${mem_available:-0}" in *[!0-9]*) mem_available=0 ;; esac
	if [ "$mem_available" -ge 32768 ]; then
		printf 'memory_available=ok:%sKiB\n' "$mem_available"
	else
		printf 'memory_available=low:%sKiB\n' "$mem_available"
		ok=0
	fi

	year="$(date +%Y 2>/dev/null || echo 0)"
	case "$year" in *[!0-9]*) year=0 ;; esac
	if [ "$year" -ge 2024 ]; then
		printf 'system_clock=ok:%s\n' "$(date -Iseconds 2>/dev/null || date)"
	else
		printf 'system_clock=invalid:%s\n' "$year"
		ok=0
	fi

	if grep -Eq '^Features[[:space:]]*:.*(^|[[:space:]])aes([[:space:]]|$)' \
		/proc/cpuinfo 2>/dev/null ||
		lsmod 2>/dev/null | grep -q '^crypto_safexcel '; then
		printf 'crypto_acceleration=ok:detected\n'
	else
		printf 'crypto_acceleration=warn:not-detected\n'
	fi

	flow_sw="$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || echo 0)"
	flow_hw="$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || echo 0)"
	if [ "$flow_hw" = 1 ]; then
		printf 'flow_offloading=warn:hardware-enabled\n'
	elif [ "$flow_sw" = 1 ]; then
		printf 'flow_offloading=warn:software-enabled\n'
	else
		printf 'flow_offloading=ok:disabled\n'
	fi

	resource_conflicts=''
	if [ "$(getv globals configured)" != 1 ]; then
		uci -q get network.ikev2out >/dev/null 2>&1 &&
			resource_conflicts="${resource_conflicts}network.ikev2out,"
		uci show firewall 2>/dev/null | grep -q '^firewall\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}firewall.ikev2pbr_*,"
		uci show pbr 2>/dev/null | grep -q '^pbr\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}pbr.ikev2pbr_*,"
	fi
	if [ -n "$resource_conflicts" ]; then
		printf 'resource_conflict=%s\n' "${resource_conflicts%,}"
		ok=0
	else
		printf 'resource_conflict=none\n'
	fi
}

preflight() {
	ok=1
	compatibility_checks
	printf 'preflight_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

validate_runtime_config() {
	wan_interface="$(getv globals wan_interface)"
	wan_zone="$(getv globals wan_zone)"
	uci -q get "network.$wan_interface" >/dev/null 2>&1 ||
		die "WAN network '$wan_interface' does not exist"
	zone_exists "$wan_zone" ||
		die "WAN firewall zone '$wan_zone' does not exist"

	for interface in $(get_list globals source_interface); do
		uci -q get "network.$interface" >/dev/null 2>&1 ||
			die "Protected network '$interface' does not exist"
		network_device "$interface" >/dev/null ||
			die "Protected network '$interface' has no device"
	done
	for zone in $(get_list globals source_zone); do
		zone_exists "$zone" ||
			die "Firewall zone '$zone' does not exist"
	done
	if [ "$(getv server enabled)" = 1 ] && [ "$(defaultv server allow_lan 1)" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			zone_exists "$zone" ||
				die "Inbound LAN firewall zone '$zone' does not exist"
		done
	fi
}

doctor() {
	ok=1
	check_command() {
		name="$1"
		command="$2"
		if command -v "$command" >/dev/null 2>&1; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
		fi
	}
	check_file() {
		name="$1"
		path="$2"
		if [ -e "$path" ]; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
		fi
	}

	compatibility_checks

	check_command firewall4 fw4
	check_command ip_full ip
	check_command nft nft
	check_command swanctl swanctl
	check_command openssl openssl
	check_command jsonfilter jsonfilter
	check_command swanmon swanmon
	check_command dnsproxy dnsproxy
	check_command sing_box sing-box
	if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
		printf 'curl=ok\n'
	else
		printf 'curl=missing\n'
		ok=0
	fi
	if find /lib/modules/"$(uname -r)" -name 'xfrm_interface.ko*' -print 2>/dev/null |
		grep -q .; then
		printf 'xfrm_module=ok\n'
	else
		printf 'xfrm_module=missing\n'
		ok=0
	fi
	check_file pbr_service /etc/init.d/pbr

	# The fail-closed apply sequence is coupled to PBR 1.2.x fw4 behavior.
	# Unknown or unsupported versions are a hard compatibility failure.
	pbr_version="$(opkg status pbr 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
	case "$pbr_version" in
		1.2.*) printf 'pbr_version=ok:%s\n' "$pbr_version" ;;
		'') printf 'pbr_version=missing\n'; ok=0 ;;
		*) printf 'pbr_version=unsupported:%s\n' "$pbr_version"; ok=0 ;;
	esac
	if [ "$(getv globals configured)" = 1 ]; then
		if failclosed_check; then
			printf 'failclosed_route=ok\n'
		else
			# Report drift without blocking apply_system, which is the repair
			# path that recreates the PBR table and validates it afterwards.
			printf 'failclosed_route=warn:missing\n'
		fi
	fi

	# Reserved XFRM if_id 42 (ipsec-out) and 43 (ipsec-in). A foreign xfrm
	# interface holding either id collides with the ones this app creates.
	xfrm_conflict="$(
		ip -d link show type xfrm 2>/dev/null | awk '
			/^[0-9]+:/ { name = $2; sub(/@.*/, "", name); sub(/:$/, "", name); next }
			/if_id/ {
				for (i = 1; i <= NF; i++)
					if ($i == "if_id") id = $(i + 1)
				if (name != "ipsec-out" && name != "ipsec-in" &&
				    (id == "42" || id == "0x2a" || id == "43" || id == "0x2b"))
					print name ":" id
			}
		'
	)"
	if [ -n "$xfrm_conflict" ]; then
		printf 'xfrm_ifid_conflict=%s\n' "$(printf '%s' "$xfrm_conflict" | tr '\n' ',')"
		ok=0
	else
		printf 'xfrm_ifid_conflict=none\n'
	fi

	xfrm_name_conflicts=''
	for name_id in 'ipsec-out:42:0x2a' 'ipsec-in:43:0x2b'; do
		name="${name_id%%:*}"
		rest="${name_id#*:}"
		expected_dec="${rest%%:*}"
		expected_hex="${rest#*:}"
		link="$(ip -d link show dev "$name" 2>/dev/null || true)"
		[ -n "$link" ] || continue
		if ! printf '%s\n' "$link" | grep -q ' xfrm '; then
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:not-xfrm,"
			continue
		fi
		actual="$(printf '%s\n' "$link" |
			awk '/if_id/ { for (i=1; i<=NF; i++) if ($i=="if_id") { print $(i+1); exit } }')"
		[ "$actual" = "$expected_dec" ] || [ "$actual" = "$expected_hex" ] ||
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:${actual:-unknown},"
	done
	if [ -n "$xfrm_name_conflicts" ]; then
		printf 'xfrm_name_conflict=%s\n' "${xfrm_name_conflicts%,}"
		ok=0
	else
		printf 'xfrm_name_conflict=none\n'
	fi

	if dnsmasq -v 2>&1 | grep -q 'nftset'; then
		printf 'dnsmasq_nftset=ok\n'
	else
		printf 'dnsmasq_nftset=missing\n'
		ok=0
	fi
	if lsmod 2>/dev/null | grep -Eq '^(nft_tproxy|nf_tproxy_ipv4) '; then
		printf 'nft_tproxy=ok\n'
	else
		printf 'nft_tproxy=missing\n'
		ok=0
	fi

	for plugin in kernel-netlink vici openssl eap-mschapv2 x509; do
		if find /usr/lib/ipsec/plugins -name "libstrongswan-${plugin}.so" -print 2>/dev/null |
			grep -q .; then
			printf 'strongswan_%s=ok\n' "$(sanitize "$plugin")"
		else
			printf 'strongswan_%s=missing\n' "$(sanitize "$plugin")"
			ok=0
		fi
	done

	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'doctor_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

runtime_packages() {
	cat <<'EOF'
pbr
dnsproxy
sing-box
strongswan
strongswan-charon
strongswan-swanctl
strongswan-mod-aes
strongswan-mod-attr
strongswan-mod-constraints
strongswan-mod-eap-identity
strongswan-mod-eap-mschapv2
strongswan-mod-gcm
strongswan-mod-gmp
strongswan-mod-hmac
strongswan-mod-kdf
strongswan-mod-kernel-netlink
strongswan-mod-md4
strongswan-mod-openssl
strongswan-mod-pem
strongswan-mod-pkcs1
strongswan-mod-pubkey
strongswan-mod-random
strongswan-mod-sha2
strongswan-mod-socket-default
strongswan-mod-vici
strongswan-mod-x509
kmod-xfrm-interface
kmod-nft-tproxy
kmod-nf-tproxy
ip-full
openssl-util
curl
libcurl4
ca-bundle
conntrack
jsonfilter
swanmon
acme
luci-app-acme
acme-acmesh-dnsapi
EOF
}

verify_install_plan() {
	packages="$(runtime_packages | tr '\n' ' ')"
	if ! opkg install --noaction dnsmasq-full $packages; then
		deps_status error 'Required packages do not match this firmware/kernel or are missing from configured feeds'
		return 1
	fi
}

deps_status_file='/tmp/ikev2-manager-deps.status'
action_status_file='/var/run/ikev2-system-action.status'
action_status_dir='/var/run/ikev2-system-actions'
action_lock_dir='/var/run/ikev2-action.lock'
action_lock_status='/var/run/ikev2-action.lock.status'
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/routing.sh"

deps_status() {
	{
		[ -z "${DEPS_ACTION_ID:-}" ] || printf 'action_id=%s\n' "$DEPS_ACTION_ID"
		printf 'state=%s\n' "$1"
		printf 'updated=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
		[ -z "${2:-}" ] || printf 'message=%s\n' "$2"
	} > "$deps_status_file"
}

# Heavy installer body. Runs detached (see install_deps) and reports progress
# through deps_status_file so the LuCI page can poll instead of blocking on a
# long XHR that would otherwise time out during opkg update/install.
run_install_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	deps_status running 'Waiting for other router actions...'
	if ! acquire_action_lock dependencies "$DEPS_ACTION_ID"; then
		deps_status error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	[ -r /etc/openwrt_release ] || { deps_status error 'This command must run on OpenWrt'; exit 1; }
	. /etc/openwrt_release
	case "${DISTRIB_RELEASE:-}" in
		24.10.*) ;;
		*) deps_status error "OpenWrt 24.10.x is required; found ${DISTRIB_RELEASE:-unknown}"; exit 1 ;;
	esac
	if ! preflight >/tmp/ikev2-manager-preflight.last 2>&1; then
		deps_status error 'Compatibility preflight failed; run ikev2-manager-system preflight'
		exit 1
	fi

	deps_status running 'Creating a recovery backup...'
	backup="/tmp/ikev2-manager-deps-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	sysupgrade -b "$backup"

	deps_status running 'Updating package lists...'
	if ! opkg update; then
		deps_status error 'opkg update failed; check WAN and DNS connectivity'
		exit 1
	fi

	deps_status running 'Checking firmware, kernel ABI, storage and package availability...'
	if ! verify_install_plan; then
		exit 1
	fi

	if ! opkg list-installed dnsmasq-full 2>/dev/null | grep -q '^dnsmasq-full '; then
		deps_status running 'Downloading DNS rollback packages...'
		cache="/tmp/ikev2-manager-dns-packages"
		rm -rf "$cache"
		mkdir -p "$cache"
		if ! (cd "$cache" && opkg download dnsmasq dnsmasq-full); then
			deps_status error 'Unable to download dnsmasq and dnsmasq-full before replacement'
			exit 1
		fi
		full_pkg="$(find "$cache" -name 'dnsmasq-full_*.ipk' | head -n1)"
		base_pkg="$(find "$cache" -name 'dnsmasq_*.ipk' | head -n1)"
		if [ ! -s "$full_pkg" ] || [ ! -s "$base_pkg" ]; then
			deps_status error 'DNS rollback packages were not downloaded'
			exit 1
		fi

		deps_status running 'Replacing dnsmasq with dnsmasq-full...'
		cp /etc/config/dhcp /tmp/ikev2-manager-dhcp.before-deps
		opkg remove dnsmasq --force-depends
		if ! opkg install "$full_pkg"; then
			opkg install "$base_pkg" || true
			cp /tmp/ikev2-manager-dhcp.before-deps /etc/config/dhcp
			/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
			deps_status error 'dnsmasq-full installation failed; dnsmasq restored'
			exit 1
		fi
		cp /tmp/ikev2-manager-dhcp.before-deps /etc/config/dhcp
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	fi

	deps_status running 'Installing strongSwan, PBR, sing-box and XFRM packages...'
	packages="$(runtime_packages | tr '\n' ' ')"
	if ! opkg install $packages; then
		deps_status error 'Package installation failed; see /tmp/ikev2-manager-deps.log'
		exit 1
	fi

	if doctor >/tmp/ikev2-manager-doctor.last 2>&1 && grep -q '^doctor_ok=1' /tmp/ikev2-manager-doctor.last; then
		deps_status ok 'All runtime dependencies installed.'
	else
		deps_status ok 'Packages installed, but some checks still report missing.'
	fi
}

install_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency installation...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _install-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency installation'
			die 'Unable to start dependency installation'
		fi
	else
		setsid "$0" _install-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}

# Remove the strongSwan / PBR / XFRM stack this app installs, returning the
# router to a clean pre-install state for re-testing. Generic tools (curl,
# ca-bundle, jsonfilter, conntrack, ip-full, openssl-util) and ACME are kept
# on purpose — they are shared and removing them can break the router.
run_remove_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	deps_status running 'Waiting for other router actions...'
	if ! acquire_action_lock dependencies "$DEPS_ACTION_ID"; then
		deps_status error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	deps_status running 'Disabling managed configuration...'
	uci -q set "$config.globals.configured=0" || true
	uci -q commit "$config" || true
	remove_managed || true
	swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
	swanctl --terminate --ike ikev2-in --timeout 3 >/dev/null 2>&1 || true
	/etc/init.d/pbr stop >/dev/null 2>&1 || true
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router deactivate >/dev/null 2>&1 || true
	fi

	deps_status running 'Removing strongSwan, PBR and XFRM packages...'
	removable='pbr sing-box strongswan strongswan-charon strongswan-swanctl strongswan-mod-aes strongswan-mod-attr strongswan-mod-constraints strongswan-mod-eap-identity strongswan-mod-eap-mschapv2 strongswan-mod-gcm strongswan-mod-gmp strongswan-mod-hmac strongswan-mod-kdf strongswan-mod-kernel-netlink strongswan-mod-md4 strongswan-mod-openssl strongswan-mod-pem strongswan-mod-pkcs1 strongswan-mod-pubkey strongswan-mod-random strongswan-mod-sha2 strongswan-mod-socket-default strongswan-mod-vici strongswan-mod-x509 kmod-xfrm-interface kmod-nft-tproxy kmod-nf-tproxy swanmon'
	opkg remove --force-depends $removable >/dev/null 2>&1 || true

	doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
	deps_status ok 'Runtime dependencies removed. Generic tools and ACME were kept.'
}

remove_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency removal...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _remove-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency removal'
			die 'Unable to start dependency removal'
		fi
	else
		setsid "$0" _remove-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}

sync_network() {
	uci -q delete network.ikev2out || true
	uci set network.ikev2out=interface
	uci set network.ikev2out.proto='none'
	uci set network.ikev2out.device='ipsec-out'
	uci set network.ikev2out.auto='1'
	uci commit network
}

sync_firewall() {
	wan_zone="$(getv globals wan_zone)"
	server_enabled="$(getv server enabled)"
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	dns_enforce="$(getv globals dns_enforce)"
	block_dot="$(getv globals block_dot)"
	source_zones="$(get_list globals source_zone)"

	delete_prefixed_sections firewall ikev2pbr_

	uci set firewall.ikev2pbr_out=zone
	uci set "firewall.ikev2pbr_out.name=$outbound_zone"
	uci set firewall.ikev2pbr_out.device='ipsec-out'
	uci set firewall.ikev2pbr_out.input='REJECT'
	uci set firewall.ikev2pbr_out.output='ACCEPT'
	uci set firewall.ikev2pbr_out.forward='REJECT'
	uci set firewall.ikev2pbr_out.masq='1'
	uci set firewall.ikev2pbr_out.mtu_fix='1'

	uci set firewall.ikev2pbr_in=zone
	uci set "firewall.ikev2pbr_in.name=$inbound_zone"
	uci set firewall.ikev2pbr_in.device='ipsec-in'
	uci set firewall.ikev2pbr_in.input='REJECT'
	uci set firewall.ikev2pbr_in.output='ACCEPT'
	uci set firewall.ikev2pbr_in.forward='REJECT'
	uci set firewall.ikev2pbr_in.mtu_fix='1'

	for zone in $source_zones; do
		key="$(sanitize "$zone")"
		section="ikev2pbr_${key}_out"
		uci set "firewall.$section=forwarding"
		uci set "firewall.$section.src=$zone"
		uci set "firewall.$section.dest=$outbound_zone"

		if [ "$dns_enforce" = 1 ]; then
			section="ikev2pbr_dns_${key}"
			uci set "firewall.$section=redirect"
			uci set "firewall.$section.name=IKEv2 PBR DNS: $zone"
			uci set "firewall.$section.src=$zone"
			uci set "firewall.$section.proto=tcp udp"
			uci set "firewall.$section.src_dport=53"
			uci set "firewall.$section.family=ipv4"
			uci set "firewall.$section.target=DNAT"
		fi

		if [ "$block_dot" = 1 ]; then
			section="ikev2pbr_dot_${key}"
			uci set "firewall.$section=rule"
			uci set "firewall.$section.name=IKEv2 PBR block DoT: $zone"
			uci set "firewall.$section.src=$zone"
			uci set "firewall.$section.dest=$wan_zone"
			uci set "firewall.$section.proto=tcp udp"
			uci set "firewall.$section.dest_port=853"
			uci set "firewall.$section.target=REJECT"
		fi
	done

	uci set firewall.ikev2pbr_server=rule
	uci set firewall.ikev2pbr_server.name='IKEv2 PBR inbound server'
	uci set "firewall.ikev2pbr_server.src=$wan_zone"
	uci set firewall.ikev2pbr_server.proto='udp'
	uci set firewall.ikev2pbr_server.dest_port='500 4500'
	uci set firewall.ikev2pbr_server.target='ACCEPT'
	uci set "firewall.ikev2pbr_server.enabled=$server_enabled"

	uci set firewall.ikev2pbr_server_esp=rule
	uci set firewall.ikev2pbr_server_esp.name='IKEv2 PBR inbound ESP'
	uci set "firewall.ikev2pbr_server_esp.src=$wan_zone"
	uci set firewall.ikev2pbr_server_esp.proto='esp'
	uci set firewall.ikev2pbr_server_esp.target='ACCEPT'
	uci set "firewall.ikev2pbr_server_esp.enabled=$server_enabled"

	uci set firewall.ikev2pbr_in_dns=rule
	uci set firewall.ikev2pbr_in_dns.name='IKEv2 PBR inbound DNS'
	uci set "firewall.ikev2pbr_in_dns.src=$inbound_zone"
	uci set firewall.ikev2pbr_in_dns.proto='tcp udp'
	uci set firewall.ikev2pbr_in_dns.dest_port='53'
	uci set firewall.ikev2pbr_in_dns.target='ACCEPT'
	uci set "firewall.ikev2pbr_in_dns.enabled=$server_enabled"

	if [ "$block_dot" = 1 ]; then
		uci set firewall.ikev2pbr_dot_in=rule
		uci set firewall.ikev2pbr_dot_in.name='IKEv2 PBR block inbound DoT'
		uci set "firewall.ikev2pbr_dot_in.src=$inbound_zone"
		uci set "firewall.ikev2pbr_dot_in.dest=$wan_zone"
		uci set firewall.ikev2pbr_dot_in.proto='tcp udp'
		uci set firewall.ikev2pbr_dot_in.dest_port='853'
		uci set firewall.ikev2pbr_dot_in.target='REJECT'
		uci set "firewall.ikev2pbr_dot_in.enabled=$server_enabled"
	fi

	uci commit firewall
	sync_inbound_access
}

sync_inbound_access() {
	server_enabled="$(getv server enabled)"
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	wan_zone="$(getv globals wan_zone)"
	[ -n "$wan_zone" ] || wan_zone='wan'
	allow_internet="$(defaultv server allow_internet 1)"
	allow_lan="$(defaultv server allow_lan 1)"
	allow_router="$(defaultv server allow_router 0)"
	router_ports="$(normalize_list "$(getv server router_ports)")"

	delete_prefixed_sections firewall ikev2access_
	if [ "$server_enabled" != 1 ]; then
		uci commit firewall
		return 0
	fi

	if [ "$allow_internet" = 1 ]; then
		uci set firewall.ikev2access_in_wan=forwarding
		uci set "firewall.ikev2access_in_wan.src=$inbound_zone"
		uci set "firewall.ikev2access_in_wan.dest=$wan_zone"

		if zone_exists "$outbound_zone"; then
			uci set firewall.ikev2access_in_out=forwarding
			uci set "firewall.ikev2access_in_out.src=$inbound_zone"
			uci set "firewall.ikev2access_in_out.dest=$outbound_zone"
		fi
	fi

	if [ "$allow_lan" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			key="$(sanitize "$zone")"
			section="ikev2access_in_${key}"
			uci set "firewall.$section=forwarding"
			uci set "firewall.$section.src=$inbound_zone"
			uci set "firewall.$section.dest=$zone"
		done
	fi

	if [ "$allow_router" = 1 ]; then
		uci set firewall.ikev2access_router=rule
		uci set firewall.ikev2access_router.name='IKEv2 inbound access to router'
		uci set "firewall.ikev2access_router.src=$inbound_zone"
		uci set firewall.ikev2access_router.target='ACCEPT'
		if [ -n "$router_ports" ]; then
			uci set firewall.ikev2access_router.proto='tcp udp'
			uci set "firewall.ikev2access_router.dest_port=$router_ports"
		else
			uci set firewall.ikev2access_router.proto='all'
		fi
	fi

	uci commit firewall
}

sync_pbr() {
	domain_file='/etc/pbr-ikev2-domains.txt'
	service_cidr_file='/etc/pbr-ikev2-service-cidrs.txt'
	manual_file='/etc/pbr-ikev2-domains.manual.txt'
	source_interfaces="$(get_list globals source_interface)"
	src=''
	for interface in $source_interfaces; do
		device="$(network_device "$interface" || true)"
		[ -n "$device" ] || die "Unable to resolve network device for '$interface'"
		src="${src:+$src }@$device"
	done
	# Inbound VPN-server clients (ipsec-in) follow the domain policy like local
	# networks only when both the server is enabled and the "VPN server" network
	# is selected in Network Integration (globals.source_include_vpn, default on).
	if [ "$(getv server enabled)" = 1 ] &&
		[ "$(defaultv globals source_include_vpn 1)" = 1 ]; then
		src="${src:+$src }@ipsec-in"
	fi

	# Snapshot the user's original pbr.config once, so disabling managed mode can
	# restore it. Enabling PBR globally and not reverting it broke routers where
	# PBR was intentionally disabled.
	if [ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" != 1 ]; then
		uci set "$config.globals.pbr_prev_enabled=$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)"
		uci set "$config.globals.pbr_prev_ipv6=$(uci -q get pbr.config.ipv6_enabled 2>/dev/null || echo 0)"
		uci set "$config.globals.pbr_prev_resolver=$(uci -q get pbr.config.resolver_set 2>/dev/null || true)"
		uci set "$config.globals.pbr_prev_strict=$(uci -q get pbr.config.strict_enforcement 2>/dev/null || true)"
		uci set "$config.globals.pbr_saved=1"
		uci commit "$config"
	fi
	uci set pbr.config.enabled='1'
	uci set pbr.config.ipv6_enabled='0'
	uci set pbr.config.resolver_set='dnsmasq.nftset'
	uci set pbr.config.strict_enforcement='1'
	add_list_unique pbr config supported_interface ikev2out

	# PBR 1.2.x reads file:// policies through curl. Keep the active merged
	# file present before PBR starts, and avoid enabling an empty domain policy.
	if [ ! -s "$domain_file" ]; then
		if [ -x /usr/libexec/ikev2-domains-community ]; then
			/usr/libexec/ikev2-domains-community apply >/dev/null 2>&1 || true
		fi
		if [ ! -s "$domain_file" ] && [ -s "$manual_file" ]; then
			cp "$manual_file" "${domain_file}.tmp"
			chmod 600 "${domain_file}.tmp"
			mv "${domain_file}.tmp" "$domain_file"
		fi
	fi

	uci -q delete pbr.ikev2pbr_domains || true
	uci set pbr.ikev2pbr_domains=policy
	uci set pbr.ikev2pbr_domains.name='IKEv2 PBR domains'
	uci set pbr.ikev2pbr_domains.interface='ikev2out'
	uci set "pbr.ikev2pbr_domains.src_addr=$src"
	uci set pbr.ikev2pbr_domains.dest_addr='file:///etc/pbr-ikev2-domains.txt'
	uci set pbr.ikev2pbr_domains.proto='all'
	if domain_file_has_entries "$domain_file"; then
		uci set pbr.ikev2pbr_domains.enabled='1'
	else
		uci set pbr.ikev2pbr_domains.enabled='0'
	fi

	uci -q delete pbr.ikev2pbr_service_cidrs || true
	uci set pbr.ikev2pbr_service_cidrs=policy
	uci set pbr.ikev2pbr_service_cidrs.name='IKEv2 PBR service networks'
	uci set pbr.ikev2pbr_service_cidrs.interface='ikev2out'
	uci set "pbr.ikev2pbr_service_cidrs.src_addr=$src"
	uci set pbr.ikev2pbr_service_cidrs.dest_addr='file:///etc/pbr-ikev2-service-cidrs.txt'
	uci set pbr.ikev2pbr_service_cidrs.proto='all'
	if domain_file_has_entries "$service_cidr_file"; then
		uci set pbr.ikev2pbr_service_cidrs.enabled='1'
	else
		uci set pbr.ikev2pbr_service_cidrs.enabled='0'
	fi

	uci -q delete pbr.ikev2pbr_include || true
	uci set pbr.ikev2pbr_include=include
	uci set pbr.ikev2pbr_include.path='/usr/share/pbr/pbr.user.ikev2out'
	uci set pbr.ikev2pbr_include.enabled='1'
	uci commit pbr
}

dns_original_dir='/etc/ikev2-manager/dns-original'
dns_input_file='/tmp/ikev2-manager-dns.in'

ensure_dns_section() {
	uci -q get "$config.dns" >/dev/null 2>&1 && return 0
	uci set "$config.dns=dns"
	uci set "$config.dns.managed=0"
	uci set "$config.dns.protocol=doh"
	uci set "$config.dns.provider=cloudflare"
	uci set "$config.dns.upstream_mode=load_balance"
	uci set "$config.dns.upstream=https://dns.cloudflare.com/dns-query"
	uci set "$config.dns.bootstrap=1.1.1.1:53 1.0.0.1:53"
	uci set "$config.dns.fallback="
	uci set "$config.dns.timeout=10s"
	uci commit "$config"
}

dns_protocol_for_upstream() {
	case "$1" in
		udp://*) printf 'udp\n' ;;
		tcp://*) printf 'tcp\n' ;;
		tls://*) printf 'dot\n' ;;
		https://*) printf 'doh\n' ;;
		h3://*) printf 'h3\n' ;;
		quic://*) printf 'doq\n' ;;
		sdns://*) printf 'dnscrypt\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

valid_dns_endpoint() {
	protocol="$1"
	endpoint="$2"
	printf '%s' "$endpoint" |
		grep -Eq '^[A-Za-z0-9._~:/?@%+=,&;-]+$' || return 1
	case "$protocol:$endpoint" in
		udp:udp://*) ;;
		tcp:tcp://*) ;;
		dot:tls://*) ;;
		doh:https://*) ;;
		doh3:https://*) ;;
		h3:h3://*) ;;
		doq:quic://*) ;;
		dnscrypt:sdns://*) ;;
		*) return 1 ;;
	esac
}

valid_dns_endpoint_list() {
	protocol="$1"
	value="$(normalize_list "$2")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_endpoint "$protocol" "$endpoint" || return 1
	done
}

valid_dns_endpoint_any() {
	endpoint="$1"
	protocol="$(dns_protocol_for_upstream "$endpoint")"
	[ "$protocol" != unknown ] && valid_dns_endpoint "$protocol" "$endpoint"
}

valid_dns_endpoint_list_any() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_endpoint_any "$endpoint" || return 1
	done
}

valid_dns_bootstrap_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		printf '%s\n' "$endpoint" | awk -F: '
			NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 65535 { exit 1 }
			{
				split($1, octet, ".")
				if (length(octet) != 4) exit 1
				for (i = 1; i <= 4; i++)
					if (octet[i] !~ /^[0-9]+$/ || octet[i] < 0 || octet[i] > 255)
						exit 1
			}
		' || return 1
	done
}

set_uci_list() {
	package="$1"
	section="$2"
	option="$3"
	value="$(normalize_list "$4")"
	uci -q delete "$package.$section.$option" || true
	for item in $value; do
		uci add_list "$package.$section.$option=$item"
	done
}

dns_service_state() {
	{
		if /etc/init.d/dnsproxy enabled 2>/dev/null; then
			printf 'enabled=1\n'
		else
			printf 'enabled=0\n'
		fi
		if /etc/init.d/dnsproxy running 2>/dev/null; then
			printf 'running=1\n'
		else
			printf 'running=0\n'
		fi
	}
}

save_dns_state() {
	dir="$1"
	mkdir -p "$dir"
	uci export dnsproxy >"$dir/dnsproxy.uci" 2>/dev/null || :
	uci export dhcp >"$dir/dhcp.uci" 2>/dev/null || :
	dns_service_state >"$dir/service.state"
}

restore_dns_state() {
	dir="$1"
	restart_dnsmasq="${2:-1}"
	[ -d "$dir" ] || return 0
	for package in dnsproxy dhcp; do
		[ -s "$dir/$package.uci" ] || continue
		uci import "$package" <"$dir/$package.uci"
		uci commit "$package"
	done
	enabled="$(sed -n 's/^enabled=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	running="$(sed -n 's/^running=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	if [ "$enabled" = 1 ]; then
		/etc/init.d/dnsproxy enable >/dev/null 2>&1 || true
	else
		/etc/init.d/dnsproxy disable >/dev/null 2>&1 || true
	fi
	if [ "$running" = 1 ]; then
		/etc/init.d/dnsproxy restart >/dev/null 2>&1 || true
	else
		/etc/init.d/dnsproxy stop >/dev/null 2>&1 || true
	fi
	if [ "$restart_dnsmasq" = 1 ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	fi
}

ensure_dns_original() {
	[ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ] && return 0
	rm -rf "$dns_original_dir"
	save_dns_state "$dns_original_dir"
	uci set "$config.dns.saved=1"
	uci commit "$config"
}

dns_query_ok() {
	tries=0
	while [ "$tries" -lt 8 ]; do
		if nslookup openwrt.org 127.0.0.1 >/tmp/ikev2-manager-dns-test 2>&1 &&
			awk '
				/^Name:/ { answer = 1; next }
				answer && /^Address:/ { found = 1 }
				END { exit found ? 0 : 1 }
			' /tmp/ikev2-manager-dns-test; then
			rm -f /tmp/ikev2-manager-dns-test
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	cat /tmp/ikev2-manager-dns-test >&2 2>/dev/null || true
	rm -f /tmp/ikev2-manager-dns-test
	return 1
}

dns_show() {
	ensure_dns_section
	managed="$(defaultv dns managed 0)"
	protocol="$(defaultv dns protocol doh)"
	provider="$(defaultv dns provider cloudflare)"
	upstream_mode="$(defaultv dns upstream_mode load_balance)"
	upstream="$(getv dns upstream)"
	bootstrap="$(getv dns bootstrap)"
	fallback="$(getv dns fallback)"
	current_upstream="$(uci -q get dnsproxy.servers.upstream 2>/dev/null || true)"
	current_bootstrap="$(uci -q get dnsproxy.servers.bootstrap 2>/dev/null || true)"
	current_fallback="$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true)"
	current_upstream_mode="$(uci -q get dnsproxy.global.upstream_mode 2>/dev/null || true)"
	[ -n "$current_upstream_mode" ] || current_upstream_mode=load_balance
	current_protocol='unknown'
	for endpoint in $current_upstream; do
		current_protocol="$(dns_protocol_for_upstream "$endpoint")"
		break
	done
	printf 'managed=%s\n' "$managed"
	printf 'protocol=%s\n' "$protocol"
	printf 'provider=%s\n' "$provider"
	printf 'upstream_mode=%s\n' "$upstream_mode"
	printf 'upstream=%s\n' "$upstream"
	printf 'bootstrap=%s\n' "$bootstrap"
	printf 'fallback=%s\n' "$fallback"
	printf 'current_protocol=%s\n' "$current_protocol"
	printf 'current_upstream=%s\n' "$current_upstream"
	printf 'current_bootstrap=%s\n' "$current_bootstrap"
	printf 'current_fallback=%s\n' "$current_fallback"
	printf 'current_upstream_mode=%s\n' "$current_upstream_mode"
	if /etc/init.d/dnsproxy running 2>/dev/null; then
		printf 'running=1\n'
	else
		printf 'running=0\n'
	fi
}

dns_apply() {
	ensure_dns_section
	managed="$1"
	protocol="$2"
	selected_protocol="$protocol"
	provider="$3"
	upstream_mode="$4"
	upstream="$(normalize_list "$5")"
	bootstrap="$(normalize_list "$6")"
	fallback="$(normalize_list "$7")"
	[ "$managed" = 0 ] || [ "$managed" = 1 ] || die 'Invalid DNS management mode'
	valid_name "$provider" || die 'Invalid DNS provider'
	fakeip_active=0
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		fakeip_active=1
	fi

	if [ "$managed" = 0 ]; then
		if [ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ]; then
			restore_dns_state "$dns_original_dir" "$([ "$fakeip_active" = 1 ] && echo 0 || echo 1)"
			if [ "$fakeip_active" = 1 ]; then
				/usr/libexec/ikev2-domain-router adopt-upstream ||
					die 'Original DNS was restored, but FakeIP could not adopt its upstream'
			fi
		fi
		uci set "$config.dns.managed=0"
		uci commit "$config"
		dns_query_ok || die 'Restored DNS configuration is not resolving'
		return 0
	fi

	case "$selected_protocol" in
		udp | tcp | dot | doh | doh3 | h3 | doq | dnscrypt) ;;
		*) die 'Unsupported DNS protocol' ;;
	esac
	case "$upstream_mode" in
		load_balance | parallel | fastest_addr) ;;
		*) die 'Unsupported DNS upstream mode' ;;
	esac
	valid_dns_endpoint_list "$selected_protocol" "$upstream" ||
		die 'Invalid DNS upstream for the selected protocol'
	valid_dns_bootstrap_list "$bootstrap" ||
		die 'Bootstrap DNS must contain IPv4:port entries'
	if [ -n "$fallback" ]; then
		valid_dns_endpoint_list_any "$fallback" ||
			die 'Invalid fallback DNS endpoint'
	fi
	command -v dnsproxy >/dev/null 2>&1 || die 'dnsproxy is not installed'

	ensure_dns_original
	rollback="/tmp/ikev2-manager-dns-rollback-$$"
	rm -rf "$rollback"
	save_dns_state "$rollback"
	uci export "$config" >"$rollback/$config.uci"

	uci -q get dnsproxy.global >/dev/null 2>&1 ||
		uci set dnsproxy.global=dnsproxy
	uci -q get dnsproxy.servers >/dev/null 2>&1 ||
		uci set dnsproxy.servers=dnsproxy
	uci -q get dnsproxy.cache >/dev/null 2>&1 ||
		uci set dnsproxy.cache=cache
	uci set dnsproxy.global.enabled='1'
	uci set dnsproxy.global.http3="$([ "$selected_protocol" = doh3 ] && echo 1 || echo 0)"
	uci set dnsproxy.global.insecure='0'
	uci set dnsproxy.global.timeout="$(defaultv dns timeout 10s)"
	uci set dnsproxy.global.upstream_mode="$upstream_mode"
	set_uci_list dnsproxy global listen_addr '127.0.0.1'
	set_uci_list dnsproxy global listen_port '5453'
	set_uci_list dnsproxy servers upstream "$upstream"
	set_uci_list dnsproxy servers bootstrap "$bootstrap"
	set_uci_list dnsproxy servers fallback "$fallback"
	uci set dnsproxy.cache.enabled='1'
	uci set dnsproxy.cache.cache_optimistic='1'
	uci set dnsproxy.cache.size='65535'
	uci commit dnsproxy

	if [ "$fakeip_active" = 1 ]; then
		uci set "$config.domains.prev_noresolv=1"
		uci -q delete "$config.domains.prev_server" || true
		uci add_list "$config.domains.prev_server=127.0.0.1#5453"
	else
		uci set dhcp.@dnsmasq[0].noresolv='1'
		set_uci_list dhcp '@dnsmasq[0]' server '127.0.0.1#5453'
		uci commit dhcp
	fi

	uci set "$config.dns.managed=1"
	uci set "$config.dns.protocol=$selected_protocol"
	uci set "$config.dns.provider=$provider"
	uci set "$config.dns.upstream_mode=$upstream_mode"
	uci set "$config.dns.upstream=$upstream"
	uci set "$config.dns.bootstrap=$bootstrap"
	uci set "$config.dns.fallback=$fallback"
	uci commit "$config"

	/etc/init.d/dnsproxy enable >/dev/null 2>&1 || true
	if ! /etc/init.d/dnsproxy restart >/dev/null 2>&1 ||
		{ [ "$fakeip_active" = 1 ] &&
			! /usr/libexec/ikev2-domain-router refresh; } ||
		{ [ "$fakeip_active" != 1 ] &&
			! /etc/init.d/dnsmasq restart >/dev/null 2>&1; } ||
		! dns_query_ok; then
		restore_dns_state "$rollback"
		uci import "$config" <"$rollback/$config.uci"
		uci commit "$config"
		if [ "$fakeip_active" = 1 ]; then
			/usr/libexec/ikev2-domain-router refresh >/dev/null 2>&1 || true
		fi
		rm -rf "$rollback"
		die 'DNS validation failed; previous resolver configuration was restored'
	fi
	rm -rf "$rollback"
}

dns_set_async() {
	[ -s "$dns_input_file" ] || die 'DNS settings input is missing'
	{
		IFS= read -r managed
		IFS= read -r protocol
		IFS= read -r provider
		IFS= read -r upstream_mode
		IFS= read -r upstream
		IFS= read -r bootstrap
		IFS= read -r fallback || true
	} <"$dns_input_file"
	rm -f "$dns_input_file"
	start_action dns-set "$managed" "$protocol" "$provider" "$upstream_mode" \
		"$upstream" "$bootstrap" "$fallback"
}

backup_uci_state() {
	label="$1"
	stamp="$(date +%Y%m%d-%H%M%S)"
	dir="/etc/ikev2-manager/backups/${stamp}-${label}"
	mkdir -p "$dir"
	for package in ikev2-manager firewall pbr network; do
		uci export "$package" >"$dir/$package.uci" 2>/dev/null || :
	done
	printf '%s\n' "$dir"
}

restore_uci_state() {
	dir="$1"
	for package in ikev2-manager firewall pbr network; do
		[ -s "$dir/$package.uci" ] || continue
		uci import "$package" <"$dir/$package.uci"
	done
	for package in ikev2-manager firewall pbr network; do
		uci commit "$package" 2>/dev/null || true
	done
	fw4 -q reload >/dev/null 2>&1 || true
	if [ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" = 1 ]; then
		/etc/init.d/pbr restart >/dev/null 2>&1 || true
	else
		/etc/init.d/pbr stop >/dev/null 2>&1 || true
	fi
	/usr/share/pbr/pbr.user.ikev2out >/dev/null 2>&1 || true
}

remove_legacy_sections() {
	delete_sections firewall \
		vpnout lan_to_vpnout iot_to_vpnout \
		vpnin vpnin_dns vpnin_icmp \
		dns_hijack_lan4 dns_hijack_iot4 dns_hijack_vpnin4 block_dot \
		ikev2_udp ikev2_esp
	delete_sections pbr ikev2_test ikev2out_include
	uci commit firewall
	uci commit pbr
}

adopt_legacy() {
	backup_dir="$(backup_uci_state adopt-legacy)"
	trap 'restore_uci_state "$backup_dir"; die "Legacy adoption failed; restored $backup_dir"' INT TERM HUP

	uci set "$config.globals.configured=1"
	uci commit "$config"
	remove_legacy_sections

	if ! ( apply_system ); then
		restore_uci_state "$backup_dir"
		die "Legacy adoption failed; restored $backup_dir"
	fi

	if ! fw4 -q check; then
		restore_uci_state "$backup_dir"
		die "Firewall check failed; restored $backup_dir"
	fi

	/usr/libexec/ikev2-sync-vips >/dev/null 2>&1 || true
	/usr/share/pbr/pbr.user.ikev2out >/dev/null 2>&1 || true
	trap - INT TERM HUP
	printf 'adopted=1\nbackup=%s\n' "$backup_dir"
}

remove_managed() {
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router deactivate >/dev/null 2>&1 || true
	fi
	delete_prefixed_sections firewall ikev2pbr_
	delete_prefixed_sections firewall ikev2access_
	uci commit firewall
	uci -q delete network.ikev2out || true
	uci commit network
	uci -q delete pbr.ikev2pbr_domains || true
	uci -q delete pbr.ikev2pbr_service_cidrs || true
	uci -q delete pbr.ikev2pbr_include || true
	uci -q del_list pbr.config.supported_interface='ikev2out' || true
	if [ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" = 1 ]; then
		uci set pbr.config.enabled="$(uci -q get "$config.globals.pbr_prev_enabled" 2>/dev/null || echo 0)"
		uci set pbr.config.ipv6_enabled="$(uci -q get "$config.globals.pbr_prev_ipv6" 2>/dev/null || echo 0)"
		v="$(uci -q get "$config.globals.pbr_prev_resolver" 2>/dev/null || true)"
		[ -n "$v" ] && uci set pbr.config.resolver_set="$v" || uci -q delete pbr.config.resolver_set
		v="$(uci -q get "$config.globals.pbr_prev_strict" 2>/dev/null || true)"
		[ -n "$v" ] && uci set pbr.config.strict_enforcement="$v" || uci -q delete pbr.config.strict_enforcement
		for k in pbr_saved pbr_prev_enabled pbr_prev_ipv6 pbr_prev_resolver pbr_prev_strict; do
			uci -q delete "$config.globals.$k"
		done
		uci commit "$config"
	fi
	uci commit pbr
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-pbr-killswitch.nft
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	rm -f /var/run/ikev2-vip4
	# Drop the IPv6 fail-fast route only if we added it (no real v6 default).
	ip -6 route show default 2>/dev/null | grep -q 'unreachable' &&
		ip -6 route del unreachable default metric 2147483647 2>/dev/null || true
	/etc/init.d/ikev2-health stop >/dev/null 2>&1 || true
	/etc/init.d/ikev2-xfrm stop >/dev/null 2>&1 || true
	/etc/init.d/ikev2-health disable >/dev/null 2>&1 || true
	/etc/init.d/ikev2-xfrm disable >/dev/null 2>&1 || true
	fw4 -q reload >/dev/null 2>&1 || true
	if [ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" = 1 ]; then
		/etc/init.d/pbr restart >/dev/null 2>&1 || true
	else
		/etc/init.d/pbr stop >/dev/null 2>&1 || true
	fi
}

apply_system() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	validate_runtime_config
	doctor >/tmp/ikev2-manager-doctor.last 2>&1 ||
		die 'Dependency check failed; run ikev2-manager-system doctor'
	sync_network
	sync_firewall
	sync_pbr
	# Remove the pre-r3 redundant nft drop rule. Fail-closed behavior now has
	# two independent native layers: an unreachable PBR default and XFRM's
	# policy drop when no matching SA exists.
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-pbr-killswitch.nft
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	/etc/init.d/ikev2-xfrm enable || die 'Failed to enable ikev2-xfrm'
	/etc/init.d/ikev2-health enable || die 'Failed to enable ikev2-health'
	/etc/init.d/ikev2-xfrm start || die 'Failed to start ikev2-xfrm'
	fw4 -q check || die 'firewall4 validation failed'
	/etc/init.d/pbr restart || die 'PBR restart command failed'
	/etc/init.d/pbr running >/dev/null 2>&1 ||
		die 'PBR failed to start; check /tmp/ikev2-manager-doctor.last and logread'
	fw4 -q reload || die 'firewall4 reload failed after PBR restart'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after apply (LAN->WAN would be dropped); rolled back'
	failclosed_check >/dev/null ||
		die 'PBR fail-closed route validation failed'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router refresh ||
			die 'FakeIP domain router refresh failed'
	fi
}

# Narrow runtime apply for Inbound Server saves. Most server edits only need a
# firewall reload and a strongSwan reload (performed by the manager worker).
# PBR itself is restarted only when enabling/disabling the server changes
# whether @ipsec-in participates in the domain policy.
apply_server_runtime() {
	needs_pbr="${1:-0}"
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	[ "$needs_pbr" = 0 ] || [ "$needs_pbr" = 1 ] ||
		die 'Invalid server PBR-change flag'
	validate_runtime_config
	sync_firewall
	if [ "$needs_pbr" = 1 ]; then
		sync_pbr
	fi
	fw4 -q check || die 'firewall4 validation failed'
	if [ "$needs_pbr" = 1 ]; then
		/etc/init.d/pbr restart || die 'PBR restart command failed'
		/etc/init.d/pbr running >/dev/null 2>&1 ||
			die 'PBR failed to start after server policy change'
	fi
	fw4 -q reload || die 'firewall4 reload failed'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after server apply'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	if [ "$needs_pbr" = 1 ] &&
	   [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router refresh ||
			die 'FakeIP domain router refresh failed'
	fi
}

show_config() {
	domain_status=''
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		domain_status="$(/usr/libexec/ikev2-domain-router status 2>/dev/null || true)"
	fi
	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'wan_interface=%s\n' "$(getv globals wan_interface)"
	printf 'wan_zone=%s\n' "$(getv globals wan_zone)"
	printf 'source_interfaces=%s\n' "$(get_list globals source_interface)"
	printf 'source_zones=%s\n' "$(get_list globals source_zone)"
	printf 'dns_enforce=%s\n' "$(getv globals dns_enforce)"
	printf 'block_dot=%s\n' "$(getv globals block_dot)"
	printf 'source_include_vpn=%s\n' "$(defaultv globals source_include_vpn 1)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	printf 'domain_engine=%s\n' "$(getv domains engine)"
	printf 'domain_healthy=%s\n' "$(
		printf '%s\n' "$domain_status" | sed -n 's/^healthy=//p' | tail -n1
	)"
	case "$(ip -6 route show default 2>/dev/null | head -1)" in
		*unreachable*) printf 'ipv6_failfast=active\n' ;;
		'') printf 'ipv6_failfast=off\n' ;;
		*) printf 'ipv6_failfast=na\n' ;;
	esac
}

set_config() {
	[ "$#" -eq 5 ] || [ "$#" -eq 6 ] ||
		die 'Expected: configured wan_interface source_interfaces dns_enforce block_dot [source_include_vpn]'
	enabled="$1"
	wan_interface="$2"
	source_interfaces="$3"
	dns_enforce="$4"
	block_dot="$5"
	# Optional 6th arg keeps older callers working; absent -> preserve current.
	include_vpn="${6:-$(defaultv globals source_include_vpn 1)}"

	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	valid_name "$wan_interface" || die 'Invalid WAN network interface'
	valid_name_list "$source_interfaces" || die 'Invalid protected networks'
	[ "$dns_enforce" = 0 ] || [ "$dns_enforce" = 1 ] || die 'Invalid DNS enforcement value'
	[ "$block_dot" = 0 ] || [ "$block_dot" = 1 ] || die 'Invalid DoT block value'
	[ "$include_vpn" = 0 ] || [ "$include_vpn" = 1 ] || die 'Invalid VPN-server inclusion value'

	# Firewall zones are derived from the chosen networks (no separate UI fields).
	wan_zone="$(zone_for_network "$wan_interface")"
	source_zones=""
	for _n in $(normalize_list "$source_interfaces"); do
		_z="$(zone_for_network "$_n")"
		case " $source_zones " in *" $_z "*) ;; *) source_zones="${source_zones:+$source_zones }$_z" ;; esac
	done

	if [ "$enabled" = 1 ]; then
		backup_dir="$(backup_uci_state enable-managed)"
		uci set "$config.globals.configured=$enabled"
		uci set "$config.globals.wan_interface=$wan_interface"
		uci set "$config.globals.wan_zone=$wan_zone"
		set_list globals source_interface "$source_interfaces"
		set_list globals source_zone "$source_zones"
		uci set "$config.globals.dns_enforce=$dns_enforce"
		uci set "$config.globals.block_dot=$block_dot"
		uci set "$config.globals.source_include_vpn=$include_vpn"
		uci commit "$config"
		# Run in a subshell because die() exits the current shell. This keeps the
		# failure catchable here so the UCI snapshot is actually restored.
		if ! ( apply_system ); then
			restore_uci_state "$backup_dir"
			die "Managed mode failed; restored $backup_dir"
		fi
	else
		uci set "$config.globals.configured=$enabled"
		uci set "$config.globals.wan_interface=$wan_interface"
		uci set "$config.globals.wan_zone=$wan_zone"
		set_list globals source_interface "$source_interfaces"
		set_list globals source_zone "$source_zones"
		uci set "$config.globals.dns_enforce=$dns_enforce"
		uci set "$config.globals.block_dot=$block_dot"
		uci set "$config.globals.source_include_vpn=$include_vpn"
		uci commit "$config"
		remove_managed
	fi
}

zone_for_network() {
	n="$1"; i=0
	while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
		zname="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null || true)"
		nets="$(uci -q get "firewall.@zone[$i].network" 2>/dev/null || true)"
		for net in $nets; do
			[ "$net" = "$n" ] && { printf '%s' "${zname:-$n}"; return 0; }
		done
		i=$((i + 1))
	done
	printf '%s' "$n"
}

coverage_add() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	add_list_unique "$config" globals source_interface "$name"
	add_list_unique "$config" globals source_zone "$(zone_for_network "$name")"
	uci commit "$config"
	if [ "$(getv globals configured)" = 1 ]; then apply_system; fi
}

coverage_remove() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	new=''
	for i in $(get_list globals source_interface); do
		[ "$i" = "$name" ] || new="${new:+$new }$i"
	done
	set_list globals source_interface "$new"
	zone="$(zone_for_network "$name")"
	keep=0
	for i in $new; do
		[ "$(zone_for_network "$i")" = "$zone" ] && keep=1
	done
	if [ "$keep" = 0 ]; then
		zn=''
		for z in $(get_list globals source_zone); do
			[ "$z" = "$zone" ] || zn="${zn:+$zn }$z"
		done
		set_list globals source_zone "$zn"
	fi
	uci commit "$config"
	if [ "$(getv globals configured)" = 1 ]; then apply_system; fi
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	exec >>/tmp/ikev2-system-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	action_status "$id" running 'Waiting for other router actions...'
	if ! acquire_action_lock system "$id"; then
		action_status "$id" error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	action_status "$id" running 'Applying router configuration...'

	case "$kind" in
		set)
			if ( set_config "$@" ); then
				action_status "$id" ok 'Router configuration applied.'
			else
				action_status "$id" error 'Router apply failed; previous managed configuration was restored.'
			fi
			;;
		coverage-add)
			if ( coverage_add "$1" ); then
				action_status "$id" ok 'Network added to policy routing.'
			else
				action_status "$id" error 'Unable to add the network; see /tmp/ikev2-system-action.log.'
			fi
			;;
		coverage-remove)
			if ( coverage_remove "$1" ); then
				action_status "$id" ok 'Network removed from policy routing.'
			else
				action_status "$id" error 'Unable to remove the network; see /tmp/ikev2-system-action.log.'
			fi
			;;
		dns-set)
			action_status "$id" running 'Applying and testing DNS settings...'
			if ( dns_apply "$@" ); then
				action_status "$id" ok 'DNS settings applied.'
			else
				action_status "$id" error 'DNS apply failed; previous resolver configuration was restored.'
			fi
			;;
		*)
			action_status "$id" error 'Unknown router action.'
			;;
	esac
}

case "${1:-}" in
	preflight)
		preflight
		;;
	deps-plan)
		verify_install_plan
		printf 'install_plan=ok\n'
		;;
	doctor)
		doctor
		;;
	failclosed-check)
		failclosed_check
		printf 'failclosed_route=ok\n'
		;;
	install-deps)
		install_deps
		;;
	_install-deps-run)
		run_install_deps "${2:-}"
		;;
	remove-deps)
		remove_deps
		;;
	_remove-deps-run)
		run_remove_deps "${2:-}"
		;;
	deps-status)
		cat "$deps_status_file" 2>/dev/null || true
		;;
	get)
		show_config
		;;
	dns-get)
		dns_show
		;;
	dns-set-async)
		dns_set_async
		;;
	set)
		shift
		set_config "$@"
		;;
	set-async)
		shift
		start_action set "$@"
		;;
	apply)
		apply_system
		;;
	_sync-pbr)
		sync_pbr
		;;
	server-apply)
		apply_server_runtime "${2:-0}"
		;;
	adopt-legacy)
		adopt_legacy
		;;
	access-apply)
		zone="$(defaultv server firewall_zone ikev2in)"
		zone_exists "$zone" ||
			die "Inbound firewall zone '$zone' does not exist"
		sync_inbound_access
		fw4 -q check
		fw4 -q reload
		;;
	disable)
		uci set "$config.globals.configured=0"
		uci commit "$config"
		remove_managed
		;;
	gateway-network)
		gateway_network
		;;
	coverage-add)
		coverage_add "${2:-}"
		;;
	coverage-remove)
		coverage_remove "${2:-}"
		;;
	coverage-async)
		[ "$#" -eq 3 ] || die 'Expected: coverage-async add|remove network'
		case "$2" in
			add) start_action coverage-add "$3" ;;
			remove) start_action coverage-remove "$3" ;;
			*) die 'Expected coverage action: add or remove' ;;
		esac
		;;
	_action-run)
		shift
		run_action "$@"
		;;
	action-status)
		if [ -n "${2:-}" ]; then
			cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
		else
			cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		fi
		;;
	*)
		die 'Usage: ikev2-manager-system {preflight|deps-plan|doctor|failclosed-check|install-deps|remove-deps|deps-status|get|dns-get|dns-set-async|set|set-async|apply|server-apply|adopt-legacy|access-apply|disable|gateway-network|coverage-add|coverage-remove|coverage-async|action-status}'
		;;
esac
