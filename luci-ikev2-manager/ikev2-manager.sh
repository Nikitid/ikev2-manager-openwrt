#!/bin/sh

set -eu

root="${IKEV2_ROOT:-}"
uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-$root/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

uci_config='ikev2-manager'
users_db="$root/etc/ikev2-manager/users.db"
inbound_conf="$root/etc/swanctl/conf.d/30-inbound.conf"
inbound_secrets="$root/etc/swanctl/conf.d/91-inbound-secrets.conf"
outbound_conf="$root/etc/swanctl/conf.d/20-proxy-out.conf"
outbound_secret="$root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
client_secret_db="$root/etc/ikev2-manager/client.secret"
user_input_file="${IKEV2_USER_INPUT:-/var/run/ikev2-manager-user.in}"
client_input_file="${IKEV2_CLIENT_INPUT:-/var/run/ikev2-manager-client.in}"
inbound_custom="$root/etc/ikev2-manager/inbound.custom.conf"
outbound_custom="$root/etc/ikev2-manager/outbound.custom.conf"
system_helper="${IKEV2_SYSTEM_HELPER:-$root/usr/libexec/ikev2-manager-system}"
acme_cert_section='ikev2'
acme_status_file="${IKEV2_ACME_STATUS:-/tmp/ikev2-acme.status}"
acme_log_file='/tmp/ikev2-acme.log'
acme_dnsapi_dir="${IKEV2_ACME_DNSAPI:-/usr/lib/acme/client/dnsapi}"
action_status_file="${IKEV2_ACTION_STATUS:-/var/run/ikev2-manager-action.status}"
action_status_dir="${IKEV2_ACTION_STATUS_DIR:-/var/run/ikev2-manager-actions}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-$root/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

filter_swanctl_noise() {
	grep -viE "plugin '.*': failed to load|no plugin file available|_plugin_create" |
		sed '/^[[:space:]]*$/d'
}

swanctl_quiet() {
	err="$(mktemp)"
	if swanctl "$@" 2>"$err"; then
		rm -f "$err"
		return 0
	fi
	code=$?
	filtered="$(filter_swanctl_noise <"$err" | tail -n 8 | tr '\n' ' ')"
	rm -f "$err"
	[ -n "$filtered" ] && printf '%s\n' "$filtered" >&2
	return "$code"
}

consume_user_input() {
	[ -f "$user_input_file" ] || die 'User input is missing'
	[ ! -L "$user_input_file" ] || die 'User input must not be a symbolic link'
	chmod 600 "$user_input_file"
	action="$(sed -n '1p' "$user_input_file")"
	user="$(sed -n '2p' "$user_input_file")"
	password="$(sed -n '3p' "$user_input_file")"
	rm -f "$user_input_file"
	[ "$action" = add ] || [ "$action" = password ] || die 'Invalid user action'
	valid_user "$user" || die 'Invalid username'
	valid_password "$password" || die 'Password must be 1-256 characters without control characters'
	encoded="$(printf '%s' "$password" | openssl base64 -A)"
	update_user "$user" "0s$encoded"
}

consume_client_input() {
	[ -f "$client_input_file" ] || die 'Client input is missing'
	[ ! -L "$client_input_file" ] || die 'Client input must not be a symbolic link'
	chmod 600 "$client_input_file"
	mode="$(sed -n '1p' "$client_input_file")"
	enabled="$(sed -n '2p' "$client_input_file")"
	remote_address="$(sed -n '3p' "$client_input_file")"
	remote_id="$(sed -n '4p' "$client_input_file")"
	username="$(sed -n '5p' "$client_input_file")"
	dpd="$(sed -n '6p' "$client_input_file")"
	mtu="$(sed -n '7p' "$client_input_file")"
	password="$(sed -n '8p' "$client_input_file")"
	rm -f "$client_input_file"

	[ "$mode" = set ] || [ "$mode" = save ] || die 'Invalid client action'
	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	if [ "$enabled" = 1 ]; then
		if [ "$mode" = set ]; then
			[ "$(getv globals configured)" = 1 ] ||
				ip link show ipsec-out >/dev/null 2>&1 ||
				die 'Complete and enable Overview first'
		fi
		valid_host_list "$remote_address" || die 'Invalid remote address list'
		valid_host "$remote_id" || die 'Invalid remote identity'
		valid_user "$username" || die 'Invalid username'
		[ -s "$client_secret_db" ] || [ -n "$password" ] ||
			die 'EAP password is required when enabling the client'
	fi
	in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
	in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'

	uci set "$uci_config.client.enabled=$enabled"
	uci set "$uci_config.client.remote_address=$(normalize_host_list "$remote_address")"
	uci set "$uci_config.client.remote_id=$remote_id"
	uci set "$uci_config.client.username=$username"
	uci set "$uci_config.client.dpd=$dpd"
	uci set "$uci_config.client.mtu=$mtu"
	uci commit "$uci_config"
	if [ -n "$password" ]; then
		set_client_secret "$username" "$password"
	else
		sync_client_secret_identity "$username"
	fi
	render_client
	render_client_secret

	[ "$mode" = set ] || return 0
	if [ "$(getv globals configured)" = 1 ]; then
		if [ "$enabled" = 1 ]; then
			start_action client-connect
		else
			start_action client-disable
		fi
	elif [ "$enabled" = 1 ]; then
		start_action connect
	fi
}

valid_user() {
	[ -n "$1" ] && [ "${#1}" -le 64 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'
}

valid_password() {
	[ -n "$1" ] && [ "${#1}" -le 256 ] &&
		! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

valid_host() {
	[ -n "$1" ] && [ "${#1}" -le 253 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9:._-]+$'
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}

valid_ipv4_pool() {
	start="${1%%-*}"
	end="${1#*-}"
	[ "$start" != "$1" ] && valid_ipv4 "$start" && valid_ipv4 "$end"
}

valid_ipv4_cidr() {
	address="${1%/*}"
	prefix="${1#*/}"
	[ "$address" != "$1" ] && valid_ipv4 "$address" &&
		valid_uint "$prefix" && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

valid_ipv4_cidr_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for cidr in $value; do
		valid_ipv4_cidr "$cidr" || return 1
	done
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_name_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for name in $value; do
		valid_name "$name" || return 1
	done
}

valid_port_list() {
	value="$(normalize_list "$1")"
	[ -z "$value" ] && return 0
	for item in $value; do
		printf '%s' "$item" | grep -Eq '^[0-9]+(-[0-9]+)?$' || return 1
		start="${item%%-*}"
		end="${item#*-}"
		[ "$start" -ge 1 ] && [ "$start" -le 65535 ] || return 1
		[ "$end" -ge "$start" ] && [ "$end" -le 65535 ] || return 1
	done
}

valid_path_or_empty() {
	[ -z "$1" ] || {
		[ "${#1}" -le 255 ] &&
			printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9_./@+-]+$'
	}
}

normalize_host_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' |
		sed 's/^ //; s/ $//'
}

valid_host_list() {
	hosts="$(normalize_host_list "$1")"
	[ -n "$hosts" ] || return 1
	for host in $hosts; do
		valid_host "$host" || return 1
	done
}

valid_uint() {
	[ -n "$1" ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'
}

in_range() {
	valid_uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

atomic_install() {
	src="$1"
	dst="$2"
	mode="$3"
	chmod "$mode" "$src"
	mv "$src" "$dst"
}

getv_default() {
	value="$(uci -q get "$uci_config.$1.$2" 2>/dev/null || true)"
	printf '%s\n' "${value:-$3}"
}

get_list() {
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

set_list() {
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$uci_config.$section.$option" || true
	for item in $value; do
		uci add_list "$uci_config.$section.$option=$item"
	done
}

init_uci() {
	mkdir -p "$uci_config_dir"
	mkdir -p "$root/etc/ikev2-manager" "$root/etc/swanctl/conf.d"
	chmod 700 "$root/etc/ikev2-manager"
	touch "$uci_config_dir/$uci_config"

	uci -q get "$uci_config.globals" >/dev/null 2>&1 || {
		uci set "$uci_config.globals=globals"
		uci set "$uci_config.globals.schema_version=1"
		uci set "$uci_config.globals.configured=0"
		uci set "$uci_config.globals.wan_interface=wan"
		uci set "$uci_config.globals.wan_zone=wan"
		uci add_list "$uci_config.globals.source_interface=lan"
		uci add_list "$uci_config.globals.source_zone=lan"
		# Default off, matching the shipped conffile. Enabling DNS redirect /
		# DoT block by default has caused LAN DNS outages; let the admin opt in.
		uci set "$uci_config.globals.dns_enforce=0"
		uci set "$uci_config.globals.block_dot=0"
		uci set "$uci_config.globals.source_include_vpn=1"
	}

	uci -q get "$uci_config.server" >/dev/null 2>&1 || {
		uci set "$uci_config.server=server"
		uci set "$uci_config.server.enabled=0"
		uci set "$uci_config.server.identity="
		uci set "$uci_config.server.pool4=10.20.30.10-10.20.30.100"
		uci set "$uci_config.server.gateway4=10.20.30.1/24"
		uci set "$uci_config.server.dns4=10.20.30.1"
		uci set "$uci_config.server.cert_source=/etc/ssl/acme"
		uci set "$uci_config.server.cert_file="
		uci set "$uci_config.server.key_file="
		uci set "$uci_config.server.dpd=30"
		uci set "$uci_config.server.ike_rekey=14400"
		uci set "$uci_config.server.child_rekey=3600"
		uci set "$uci_config.server.mtu=1400"
		uci set "$uci_config.server.mobike=1"
		uci set "$uci_config.server.fragmentation=1"
		uci set "$uci_config.server.local_ts=0.0.0.0/0"
		uci set "$uci_config.server.allow_internet=1"
		uci set "$uci_config.server.allow_lan=1"
		uci set "$uci_config.server.allow_router=0"
		uci set "$uci_config.server.router_ports="
		uci add_list "$uci_config.server.lan_zone=lan"
		uci set "$uci_config.server.firewall_zone=ikev2in"
		uci set "$uci_config.server.outbound_zone=ikev2out"
		uci set "$uci_config.server.custom_config=0"
	}

	uci -q get "$uci_config.client" >/dev/null 2>&1 || {
		uci set "$uci_config.client=client"
		uci set "$uci_config.client.enabled=0"
		uci set "$uci_config.client.remote_address="
		uci set "$uci_config.client.remote_id="
		uci set "$uci_config.client.username="
		uci set "$uci_config.client.dpd=30"
		uci set "$uci_config.client.mtu=1400"
		uci set "$uci_config.client.custom_config=0"
	}

	uci -q get "$uci_config.dns" >/dev/null 2>&1 || {
		uci set "$uci_config.dns=dns"
		uci set "$uci_config.dns.managed=0"
		uci set "$uci_config.dns.protocol=doh"
		uci set "$uci_config.dns.provider=cloudflare"
		uci set "$uci_config.dns.upstream=https://dns.cloudflare.com/dns-query"
		uci set "$uci_config.dns.bootstrap=1.1.1.1:53 1.0.0.1:53"
		uci set "$uci_config.dns.fallback="
		uci set "$uci_config.dns.timeout=10s"
	}

	for assignment in \
		'server.gateway4=10.20.30.1/24' \
		'server.cert_source=/etc/ssl/acme' \
		'server.cert_file=' \
		'server.key_file=' \
		'server.local_ts=0.0.0.0/0' \
		'server.allow_internet=1' \
		'server.allow_lan=1' \
		'server.allow_router=0' \
		'server.router_ports=' \
		'server.firewall_zone=ikev2in' \
		'server.outbound_zone=ikev2out' \
		'server.custom_config=0' \
		'client.custom_config=0'; do
		section="${assignment%%.*}"
		rest="${assignment#*.}"
		option="${rest%%=*}"
		value="${rest#*=}"
		uci -q get "$uci_config.$section.$option" >/dev/null 2>&1 ||
			uci set "$uci_config.$section.$option=$value"
	done
	uci -q get "$uci_config.server.lan_zone" >/dev/null 2>&1 || {
		legacy_zones="$(uci -q get "$uci_config.globals.inbound_lan_zone" 2>/dev/null || true)"
		set_list server lan_zone "${legacy_zones:-lan}"
	}
	uci commit "$uci_config"
}

init_client_secret() {
	[ -s "$client_secret_db" ] && return 0
	[ -s "$outbound_secret" ] || return 0
	username="$(sed -n 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$outbound_secret" | head -n1)"
	secret="$(sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$outbound_secret" | head -n1)"
	[ -n "$username" ] && [ -n "$secret" ] || return 0
	printf '%s\t%s\n' "$username" "$secret" >"${client_secret_db}.new"
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

init_users() {
	[ -s "$users_db" ] && return 0

	mkdir -p "${users_db%/*}"
	chmod 700 "${users_db%/*}"
	tmp="${users_db}.new"
	awk '
		/^[[:space:]]*eap-[^[:space:]]+[[:space:]]*\{/ {
			in_eap = 1
			id = ""
			secret = ""
			next
		}
		in_eap && /^[[:space:]]*id[[:space:]]*=/ {
			id = $0
			sub(/^[^=]*=[[:space:]]*/, "", id)
			gsub(/^"|"$/, "", id)
			next
		}
		in_eap && /^[[:space:]]*secret[[:space:]]*=/ {
			secret = $0
			sub(/^[^=]*=[[:space:]]*/, "", secret)
			next
		}
		in_eap && /^[[:space:]]*\}/ {
			if (id != "" && secret != "")
				printf "%s\t%s\n", id, secret
			in_eap = 0
		}
	' "$inbound_secrets" 2>/dev/null >"$tmp" || :
	atomic_install "$tmp" "$users_db" 600
}

render_users() {
	tmp="${inbound_secrets}.new"
	{
		echo 'secrets {'
		while IFS="$(printf '\t')" read -r user secret; do
			[ -n "$user" ] || continue
			printf '\teap-%s {\n' "$user"
			printf '\t\tid = "%s"\n' "$user"
			printf '\t\tsecret = %s\n' "$secret"
			echo '	}'
			echo
		done <"$users_db"
		echo '	private-key {'
		printf '\t\tfile = %s\n' "$root/etc/swanctl/private/ikev2.key"
		echo '	}'
		echo '}'
	} >"$tmp"
	atomic_install "$tmp" "$inbound_secrets" 600
}

update_user() {
	user="$1"
	secret="$2"
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	printf '%s\t%s\n' "$user" "$secret" >>"$tmp"
	sort -t "$(printf '\t')" -k1,1 "$tmp" -o "$tmp"
	atomic_install "$tmp" "$users_db" 600
	render_users
	swanctl_quiet --load-creds >/dev/null || :
}

delete_user() {
	user="$1"
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	atomic_install "$tmp" "$users_db" 600
	render_users
	swanctl_quiet --load-creds >/dev/null || :
}

getv() {
	# Tolerate empty/missing options like get_list/getv_default and the system
	# helper's getv. A bare `uci -q get` returns non-zero for a set-but-empty
	# option, which under `set -eu` aborts mid-operation (e.g. server-set commits
	# enabled=1, then sync_server_certificate dies on an empty cert_file before
	# rendering/loading — a partial-applied state). Callers only read the value.
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

render_server() {
	enabled="$(getv server enabled)"
	tmp="${inbound_conf}.new"

	if [ "$(getv_default server custom_config 0)" = 1 ]; then
		[ -s "$inbound_custom" ] || die 'Inbound custom configuration is missing'
		cp "$inbound_custom" "$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Inbound server is disabled.' >"$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	identity="$(getv server identity)"
	pool4="$(getv server pool4)"
	dns4="$(getv server dns4)"
	dpd="$(getv server dpd)"
	ike_rekey="$(getv server ike_rekey)"
	child_rekey="$(getv server child_rekey)"
	mobike="$(getv server mobike)"
	fragmentation="$(getv server fragmentation)"
	local_ts="$(normalize_list "$(getv_default server local_ts 0.0.0.0/0)" | sed 's/ /, /g')"
	cat >"$tmp" <<EOF
connections {
	ikev2-in {
		version = 2
		send_cert = always
		proposals = aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048
		unique = never
		dpd_delay = ${dpd}s
		rekey_time = ${ike_rekey}s
		mobike = $([ "$mobike" = 1 ] && echo yes || echo no)
		fragmentation = $([ "$fragmentation" = 1 ] && echo yes || echo no)
		pools = router_pool4

		local {
			auth = pubkey
			certs = ikev2.pem
			id = $identity
		}

		remote {
			auth = eap-mschapv2
			eap_id = %any
			id = %any
		}

		children {
			net {
				esp_proposals = aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16,aes256-sha256-modp2048,aes256-sha256
				local_ts = $local_ts
				if_id_in = 43
				if_id_out = 43
				rekey_time = ${child_rekey}s
				dpd_action = clear
				start_action = none
			}
			}
		}
	}
pools {
	router_pool4 {
		addrs = $pool4
		dns = $dns4
	}
}
EOF
	atomic_install "$tmp" "$inbound_conf" 600
}

sync_server_certificate() {
	[ "$(getv server enabled)" = 1 ] || return 0
	identity="$(getv server identity)"
	cert_file="$(getv server cert_file)"
	key_file="$(getv server key_file)"
	cert_source="$(getv server cert_source)"

	if [ -z "$cert_file" ] && [ -n "$identity" ]; then
		cert_file="$cert_source/$identity.fullchain.crt"
	fi
	if [ -z "$key_file" ] && [ -n "$identity" ]; then
		key_file="$cert_source/$identity.key"
	fi
	[ -s "$cert_file" ] || die "Server certificate not found: $cert_file"
	[ -s "$key_file" ] || die "Server private key not found: $key_file"

	mkdir -p "$root/etc/swanctl/x509" "$root/etc/swanctl/private"
	umask 077
	cp "$cert_file" "$root/etc/swanctl/x509/ikev2.pem.new"
	cp "$key_file" "$root/etc/swanctl/private/ikev2.key.new"
	mv "$root/etc/swanctl/x509/ikev2.pem.new" "$root/etc/swanctl/x509/ikev2.pem"
	mv "$root/etc/swanctl/private/ikev2.key.new" "$root/etc/swanctl/private/ikev2.key"
	chmod 644 "$root/etc/swanctl/x509/ikev2.pem"
	chmod 600 "$root/etc/swanctl/private/ikev2.key"
}

# ACME issuance for the inbound server certificate. The app owns the
# /etc/config/acme cert section so the UI can pick HTTP-01 or DNS-01 without
# touching luci-app-acme. The acme hotplug (90-ikev2-acme) and acme-issue both
# sync the issued cert into swanctl.
acme_server_cert_path() {
	cert_source="$(getv server cert_source)"
	[ -n "$cert_source" ] || cert_source='/etc/ssl/acme'
	printf '%s/%s.fullchain.crt' "$cert_source" "$(getv server identity)"
}

acme_emit() {
	identity="$(getv server identity)"
	section="acme.$acme_cert_section"
	method="$(uci -q get "$section.validation_method" 2>/dev/null || true)"
	case "$method" in
		dns) printf 'method=dns\n' ;;
		*) printf 'method=http\n' ;;
	esac
	email="$(uci -q get acme.@acme[0].account_email 2>/dev/null || true)"
	[ "$email" = 'email@example.org' ] && email=''
	printf 'email=%s\n' "$email"
	printf 'dns_provider=%s\n' "$(uci -q get "$section.dns" 2>/dev/null || true)"
	printf 'staging=%s\n' "$(uci -q get "$section.staging" 2>/dev/null || echo 0)"
	[ -n "$(uci -q get "$section.credentials" 2>/dev/null || true)" ] &&
		printf 'has_credentials=1\n' || printf 'has_credentials=0\n'
	printf 'providers='
	for d in "$acme_dnsapi_dir"/dns_*.sh; do
		[ -e "$d" ] || continue
		b="${d##*/}"
		printf '%s ' "${b%.sh}"
	done
	printf '\n'
	cert="$(acme_server_cert_path)"
	if [ -n "$identity" ] && [ -s "$cert" ]; then
		printf 'cert_present=1\n'
		printf 'cert_expiry=%s\n' "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
		printf 'cert_subject=%s\n' "$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	else
		printf 'cert_present=0\n'
	fi
	# Runtime truth for the Inbound Server page: is the conn actually loaded into
	# charon? Lets the UI distinguish "enabled with a cert" from "actually serving".
	printf 'conn_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' && echo 1 || echo 0)"
}

# Primary env var for single-credential DNS providers, so a user can paste just
# the token instead of the exact `VAR="value"` acme.sh syntax.
acme_primary_var() {
	case "$1" in
		dns_timeweb) echo 'TW_Token' ;;
		dns_cf) echo 'CF_Token' ;;
		dns_duckdns) echo 'DuckDNS_Token' ;;
		dns_dynv6) echo 'DYNV6_TOKEN' ;;
		dns_desec) echo 'DEDYN_TOKEN' ;;
		dns_hetzner) echo 'HETZNER_Token' ;;
		dns_njalla) echo 'NJALLA_Token' ;;
		dns_vultr) echo 'VULTR_API_KEY' ;;
		dns_gcore) echo 'GCORE_Key' ;;
		dns_namesilo) echo 'Namesilo_Key' ;;
		dns_linode_v4) echo 'LINODE_V4_API_KEY' ;;
		dns_dynu) echo 'Dynu_ClientId' ;;
		*) echo '' ;;
	esac
}

acme_set() {
	# Settings arrive through a file written with fs.write, not as a command
	# argument. Passing the (large, secret) token on the exec command line is
	# fragile: rpcd gates file-exec with an fnmatch ACL, and arbitrary base64
	# content broke the match (slashes, length) -> Permission denied. A file
	# keeps acme-set argument-free, so the ACL is a plain exact match and the
	# token never lands in the process list. Layout: line1=email, line2=method,
	# line3=provider, line4=staging, line5+=credentials.
	infile="${IKEV2_ACME_INPUT:-/tmp/ikev2-acme.in}"
	[ -s "$infile" ] || die 'No ACME settings received'
	a_email="$(sed -n '1p' "$infile")"
	a_method="$(sed -n '2p' "$infile")"
	a_provider="$(sed -n '3p' "$infile")"
	a_staging="$(sed -n '4p' "$infile")"
	a_creds="$(sed -n '5,$p' "$infile")"
	rm -f "$infile"
	identity="$(getv server identity)"
	[ -n "$identity" ] || die 'Set the server public identity first'
	valid_host "$identity" || die 'Invalid server identity'
	printf '%s' "$a_email" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' ||
		die 'A valid ACME account email is required'
	[ "$a_staging" = 0 ] || [ "$a_staging" = 1 ] || die 'Invalid staging value'

	uci -q get acme.@acme[0] >/dev/null 2>&1 || uci add acme acme >/dev/null
	uci set acme.@acme[0].account_email="$a_email"
	uci -q delete "acme.$acme_cert_section" 2>/dev/null || true
	uci set "acme.$acme_cert_section=cert"
	uci set "acme.$acme_cert_section.enabled=1"
	uci add_list "acme.$acme_cert_section.domains=$identity"
	uci set "acme.$acme_cert_section.key_type=rsa2048"
	uci set "acme.$acme_cert_section.staging=$a_staging"

	case "$a_method" in
		dns)
			printf '%s' "$a_provider" | grep -Eq '^dns_[a-z0-9_]+$' ||
				die 'Invalid DNS provider'
			[ -e "$acme_dnsapi_dir/$a_provider.sh" ] ||
				die "DNS provider not installed: $a_provider"
			uci set "acme.$acme_cert_section.validation_method=dns"
			uci set "acme.$acme_cert_section.dns=$a_provider"
			# Fixed propagation wait (--dnssleep). Providers with split
			# authoritative nameservers (e.g. Timeweb's ns*.timeweb.ru +
			# ns*.timeweb.org) do not sync the challenge TXT to every server
			# within acme.sh's default check window, so Let's Encrypt secondary
			# validation reads a stale record and fails ("Incorrect TXT record").
			uci set "acme.$acme_cert_section.dns_wait=120"
			# Non-empty credentials replace stored ones; empty keeps existing.
			if printf '%s' "$a_creds" | grep -q '[^[:space:]]'; then
				primary_var="$(acme_primary_var "$a_provider")"
				uci -q delete "acme.$acme_cert_section.credentials" 2>/dev/null || true
				printf '%s\n' "$a_creds" | while IFS= read -r line; do
					line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
					[ -n "$line" ] || continue
					if printf '%s' "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
						: # already VAR=value
					elif [ -n "$primary_var" ]; then
						# Bare token pasted: wrap in the provider's primary var.
						line="$primary_var=\"$line\""
					else
						die "Enter credentials as VAR=value for $a_provider (see acme.sh docs)"
					fi
					uci add_list "acme.$acme_cert_section.credentials=$line"
				done
			fi
			;;
		http)
			uci set "acme.$acme_cert_section.validation_method=standalone"
			;;
		*)
			die 'Invalid challenge method (expected dns or http)'
			;;
	esac
	uci commit acme
}

acme_issue() {
	identity="$(getv server identity)"
	[ -n "$identity" ] || die 'Set the server public identity first'
	uci -q get "acme.$acme_cert_section" >/dev/null 2>&1 ||
		die 'Configure ACME settings first'
	cert="$(acme_server_cert_path)"
	id="$(date +%s)-$$"
	{
		printf 'action_id=%s\nstate=running\nmessage=Requesting certificate (DNS propagation can take a minute)...\nupdated=%s\n' \
			"$id" "$(date +%s)" >"$acme_status_file"
		(
			exec >>"$acme_log_file" 2>&1
			printf '\n=== %s acme issue ===\n' "$(date)"
			if /etc/init.d/acme start && [ -s "$cert" ]; then
				if [ "$(getv server enabled)" = 1 ]; then
					# Bring the inbound server up now that the cert exists: copy
					# it into swanctl, (re)write the connection, and reload. The
					# initial server enable aborts when the cert is missing, so
					# the conn may not have been written yet.
					sync_server_certificate || true
					render_server || true
					render_users || true
					swanctl_quiet --load-all >/dev/null 2>&1 || true
				fi
				printf 'action_id=%s\nstate=ok\nmessage=Certificate issued and installed\nupdated=%s\n' \
					"$id" "$(date +%s)" >"$acme_status_file"
			else
				printf 'action_id=%s\nstate=error\nmessage=Request failed; see /tmp/ikev2-acme.log\nupdated=%s\n' \
					"$id" "$(date +%s)" >"$acme_status_file"
			fi
		) </dev/null >/dev/null 2>&1 &
	}
	printf 'action_id=%s\n' "$id"
}

# strongSwan validates the remote VPS certificate only against CAs in
# /etc/swanctl/x509ca/. Unlike iPhone/Windows it does not consult the OS trust
# store automatically, so a public Let's Encrypt server cert is otherwise
# rejected ("no trusted RSA public key" -> AUTH_FAILED). Install the Let's
# Encrypt (ISRG) roots shipped with this package into the swanctl trust store.
# The server identity is still pinned via remote `id`, so this is not blanket
# trust of every CA — only the roots that sign the VPS certificate. Copying the
# bundled PEMs is instant; scanning the system ca-bundle (~150 certs) was too
# slow and timed out the LuCI view that re-renders the client on open.
sync_client_ca() {
	src="$root/usr/share/ikev2-manager/ca"
	dir="$root/etc/swanctl/x509ca"
	mkdir -p "$dir"
	for pem in "$src"/isrg-root-*.pem; do
		[ -s "$pem" ] || continue
		cp "$pem" "$dir/ikev2-le-${pem##*/}.new"
		chmod 644 "$dir/ikev2-le-${pem##*/}.new"
		mv "$dir/ikev2-le-${pem##*/}.new" "$dir/ikev2-le-${pem##*/}"
	done
}

render_client() {
	enabled="$(getv client enabled)"
	tmp="${outbound_conf}.new"

	if [ "$(getv_default client custom_config 0)" = 1 ]; then
		[ -s "$outbound_custom" ] || die 'Outbound custom configuration is missing'
		cp "$outbound_custom" "$tmp"
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Outbound client is disabled.' >"$tmp"
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	sync_client_ca

	remote_address="$(getv client remote_address)"
	remote_id="$(getv client remote_id)"
	username="$(getv client username)"
	dpd="$(getv client dpd)"
	remote_addrs="$(normalize_host_list "$remote_address" | sed 's/ /, /g')"

	cat >"$tmp" <<EOF
connections {
	proxy-out {
		version = 2
		remote_addrs = $remote_addrs
		proposals = aes256gcm16-prfsha384-ecp384
		vips = 0.0.0.0
		mobike = yes
		fragmentation = yes
		dpd_delay = ${dpd}s
		reauth_time = 0
		keyingtries = 0

		local {
			auth = eap-mschapv2
			id = $username
			eap_id = $username
		}

		remote {
			auth = pubkey
			id = $remote_id
		}

		children {
			proxy4 {
				local_ts = 0.0.0.0/0
				remote_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
				if_id_in = 42
				if_id_out = 42
				start_action = start
				dpd_action = restart
				close_action = start
			}
		}
	}
}
EOF
	atomic_install "$tmp" "$outbound_conf" 600
}

set_client_secret() {
	username="$1"
	password="$2"
	encoded="$(printf '%s' "$password" | openssl base64 -A)"
	mkdir -p "${client_secret_db%/*}"
	printf '%s\t0s%s\n' "$username" "$encoded" >"${client_secret_db}.new"
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
	render_client_secret
}

render_client_secret() {
	tmp="${outbound_secret}.new"
	if [ ! -s "$client_secret_db" ]; then
		echo '# Managed by IKEv2 Manager. Client secret is not configured.' >"$tmp"
		atomic_install "$tmp" "$outbound_secret" 600
		return
	fi
	IFS="$(printf '\t')" read -r username encoded <"$client_secret_db"
	tmp="${outbound_secret}.new"
	cat >"$tmp" <<EOF
secrets {
	eap-proxy-out {
		id = "$username"
		secret = $encoded
	}
}
EOF
	atomic_install "$tmp" "$outbound_secret" 600
}

sync_client_secret_identity() {
	username="$1"
	[ -s "$client_secret_db" ] || return 0
	IFS="$(printf '\t')" read -r old_username encoded <"$client_secret_db"
	[ "$old_username" = "$username" ] && return 0
	printf '%s\t%s\n' "$username" "$encoded" >"${client_secret_db}.new"
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

load_profile() {
	profile="$1"
	[ -z "$root" ] || return 0
	case "$profile" in
		inbound)
			swanctl_quiet --load-all >/dev/null
			;;
		outbound)
			swanctl_quiet --load-all >/dev/null
			if [ "$(getv client enabled)" = 1 ]; then
				swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null || :
				initiate_outbound
				/usr/libexec/ikev2-sync-vips
				/usr/share/pbr/pbr.user.ikev2out || :
			fi
			;;
		*)
			die 'Unknown profile'
			;;
	esac
}

profile_values() {
	case "$1" in
		inbound)
			profile_section='server'
			profile_active="$inbound_conf"
			profile_custom="$inbound_custom"
			;;
		outbound)
			profile_section='client'
			profile_active="$outbound_conf"
			profile_custom="$outbound_custom"
			;;
		*)
			die 'Expected profile: inbound or outbound'
			;;
	esac
}

advanced_read() {
	profile_values "$1"
	if [ "$profile_section" = server ]; then
		render_server
	else
		render_client
	fi
	cat "$profile_active"
}

advanced_set() {
	profile="$1"
	encoded="$2"
	profile_values "$profile"
	tmp="${profile_custom}.new"
	printf '%s' "$encoded" | openssl base64 -d -A >"$tmp" 2>/dev/null ||
		die 'Unable to decode custom configuration'
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		die 'Custom configuration cannot be empty'
	}
	[ "$(wc -c <"$tmp")" -le 65536 ] || {
		rm -f "$tmp"
		die 'Custom configuration is larger than 64 KiB'
	}
	grep -Eq '^[[:space:]]*connections[[:space:]]*\{' "$tmp" || {
		rm -f "$tmp"
		die 'Custom configuration must contain a connections block'
	}

	old_mode="$(getv_default "$profile_section" custom_config 0)"
	backup="${profile_custom}.backup"
	[ -s "$profile_custom" ] && cp "$profile_custom" "$backup" || rm -f "$backup"
	atomic_install "$tmp" "$profile_custom" 600
	uci set "$uci_config.$profile_section.custom_config=1"
	uci commit "$uci_config"

	if ! {
		cp "$profile_custom" "${profile_active}.new"
		atomic_install "${profile_active}.new" "$profile_active" 600
		load_profile "$profile"
	}; then
		[ -s "$backup" ] && mv "$backup" "$profile_custom" || rm -f "$profile_custom"
		uci set "$uci_config.$profile_section.custom_config=$old_mode"
		uci commit "$uci_config"
		if [ "$profile_section" = server ]; then
			render_server
		else
			render_client
		fi
		load_profile "$profile" >/dev/null 2>&1 || :
		die 'strongSwan rejected the custom configuration'
	fi
	rm -f "$backup"
}

advanced_reset() {
	profile="$1"
	profile_values "$profile"
	uci set "$uci_config.$profile_section.custom_config=0"
	uci commit "$uci_config"
	if [ "$profile_section" = server ]; then
		render_server
	else
		render_client
	fi
	load_profile "$profile"
}

apply_all() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Complete and enable Overview first'
	sync_server_certificate
	render_server
	render_client
	render_client_secret
	render_users
	"$system_helper" apply
	swanctl_quiet --load-all >/dev/null
	/usr/libexec/ikev2-sync-vips || :
	/usr/share/pbr/pbr.user.ikev2out || :
}

overview() {
	cert="$root/etc/swanctl/x509/ikev2.pem"
	count_lines() {
		[ -r "$1" ] && awk 'NF && $1 !~ /^#/ { n++ } END { print n + 0 }' "$1" || echo 0
	}
	configured="$(getv globals configured)"
	[ -n "$configured" ] || configured=0
	if [ "$configured" = 1 ]; then
		runtime_mode=managed
	elif uci show firewall 2>/dev/null | grep -Eq '^firewall\.(vpnin|vpnout)=' &&
		uci show pbr 2>/dev/null | grep -q "interface='ikev2out'"; then
		runtime_mode=legacy
	else
		runtime_mode=unconfigured
	fi
	printf 'health=%s\n' "$(sed -n 's/^state=\([^ ]*\).*/\1/p' /var/run/ikev2-health.status 2>/dev/null || echo unknown)"
	printf 'pbr=%s\n' "$(/etc/init.d/pbr running && echo running || echo stopped)"
	printf 'configured=%s\n' "$configured"
	printf 'runtime_mode=%s\n' "$runtime_mode"
	printf 'package_installed=%s\n' "$(opkg status luci-app-ikev2-manager 2>/dev/null | grep -q '^Status: .* installed' && echo 1 || echo 0)"
	printf 'zapret=%s\n' "$([ -x /etc/init.d/zapret ] && /etc/init.d/zapret running && echo running || echo not-installed)"
	printf 'client_enabled=%s\n' "$(getv client enabled)"
	printf 'client_remote=%s\n' "$(getv client remote_address)"
	printf 'client_mtu=%s\n' "$(getv client mtu)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	# Runtime truth (not just the UCI flag): is the inbound conn + pool actually
	# loaded into charon? A drifted server (cert/pool unloaded) is enabled but not
	# serving — surface that instead of showing a healthy "Enabled".
	printf 'inbound_conn_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' && echo 1 || echo 0)"
	printf 'inbound_pool_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-pools 2>/dev/null | grep -q 'router_pool4' && echo 1 || echo 0)"
	printf 'server_pool=%s\n' "$(getv server pool4)"
	printf 'configured_users=%s\n' "$(count_lines "$users_db")"
	printf 'pbr_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.txt")"
	printf 'manual_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.manual.txt")"
	printf 'community_services=%s\n' "$(count_lines "$root/etc/pbr-ikev2-community-selected.txt")"
	printf 'dns_hijack=%s\n' "$(
		if nft list ruleset 2>/dev/null | grep -Eq 'dport 53.*dnat|dnat.*dport 53'; then
			echo active
		elif uci show firewall 2>/dev/null | grep -Eq '^firewall\.(dns_hijack_|ikev2pbr_dns_)'; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'dot_block=%s\n' "$(
		if nft list ruleset 2>/dev/null | grep -Eq 'dport 853.*reject|reject.*dport 853'; then
			echo active
		elif uci show firewall 2>/dev/null | grep -Eq '^firewall\.(block_dot|ikev2pbr_dot_)'; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'killswitch=%s\n' "$(ip -4 route show table pbr_ikev2out 2>/dev/null |
		grep -Eq '^unreachable default( |$)' && echo active || echo missing)"
	printf 'inbound_firewall=%s\n' "$(nft list ruleset 2>/dev/null | grep -Eq 'udp dport.*500.*4500.*accept' && echo active || echo missing)"
	printf 'mtproto=%s\n' "$([ -x /etc/init.d/tg-ws-proxy ] && /etc/init.d/tg-ws-proxy running && echo running || echo not-installed)"
	printf 'mtproto_firewall=%s\n' "$(nft list ruleset 2>/dev/null | grep -Eq 'tcp dport 1443.*dnat' && echo active || echo missing)"
	printf 'flow_software=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading || echo 0)"
	printf 'flow_hardware=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)"
	printf 'safexcel=%s\n' "$(lsmod | grep -q '^crypto_safexcel ' && echo loaded || echo unloaded)"
	printf 'cert_subject=%s\n' "$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	printf 'cert_issuer=%s\n' "$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
	printf 'cert_not_before=%s\n' "$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2-)"
	printf 'cert_not_after=%s\n' "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
	printf 'cert_fingerprint=%s\n' "$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2-)"
}

show_users() {
	while IFS="$(printf '\t')" read -r user secret; do
		[ -n "$user" ] || continue
		# Passwords remain available to strongSwan locally, but are write-only
		# through LuCI/RPC so a read action never returns them to the browser.
		printf '%s\n' "$user"
	done <"$users_db"
}

init_uci
init_users
init_client_secret

# Run swanctl --initiate but swallow strongSwan's noisy plugin-load warnings,
# surfacing only the meaningful failure reason to the caller (and the LuCI UI).
initiate_outbound() {
	_err="$(swanctl --initiate --child proxy4 --timeout 20 2>&1 >/dev/null)" && return 0
	_reason="$(printf '%s\n' "$_err" \
		| grep -viE 'failed to load|no plugin file|_plugin_create' \
		| grep -iE 'initiate|establish|auth|propos|timeout|retransmit|no ike|unable|notify|peer|certificate|fail' \
		| tail -n 4 | tr '\n' ' ' | sed 's/  */ /g')"
	[ -n "$_reason" ] || _reason='establishing CHILD_SA proxy4 failed (run logread for strongSwan details)'
	printf 'Tunnel did not come up: %s\n' "$_reason" >&2
	return 1
}

connect_action() {
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	if initiate_outbound; then
		/usr/libexec/ikev2-sync-vips || :
		# The policy itself did not change. Refresh only the live PBR table route;
		# a full PBR restart would rebuild firewall4 and add ~20 seconds.
		/usr/share/pbr/pbr.user.ikev2out || :
		return 0
	else
		/usr/libexec/ikev2-sync-vips || :
		/usr/share/pbr/pbr.user.ikev2out || :
		return 1
	fi
}

disable_client_action() {
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	rm -f /var/run/ikev2-vip4
	ip -4 addr flush dev ipsec-out scope global 2>/dev/null || :
	/usr/share/pbr/pbr.user.ikev2out || :
}

apply_action() {
	"$system_helper" apply || return 1
	swanctl_quiet --load-all >/dev/null || return 1
	/usr/libexec/ikev2-sync-vips || :
	return 0
}

server_apply_action() {
	needs_pbr="${1:-0}"
	"$system_helper" server-apply "$needs_pbr" || return 1
	swanctl_quiet --load-all >/dev/null || return 1
	/usr/libexec/ikev2-sync-vips || :
	/usr/share/pbr/pbr.user.ikev2out || :
	return 0
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	exec >>/tmp/ikev2-manager-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	action_status "$id" running 'Waiting for other router actions...'
	if ! acquire_action_lock manager "$id"; then
		action_status "$id" error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM

	case "$kind" in
		apply)
			action_status "$id" running 'Applying firewall, PBR and strongSwan...'
			if apply_action; then
				action_status "$id" ok 'Configuration applied.'
			else
				action_status "$id" error 'Apply failed; see /tmp/ikev2-manager-action.log and logread.'
			fi
			;;
		connect)
			action_status "$id" running 'Reconnecting the outbound tunnel...'
			if connect_action; then
				action_status "$id" ok 'Outbound tunnel reconnected.'
			else
				action_status "$id" error 'Tunnel did not come up; see /tmp/ikev2-manager-action.log and logread.'
			fi
			;;
		client-connect)
			action_status "$id" running 'Loading settings and reconnecting the outbound tunnel...'
			if swanctl_quiet --load-conns >/dev/null &&
			   swanctl_quiet --load-creds >/dev/null &&
			   connect_action; then
				action_status "$id" ok 'Settings saved and tunnel connected.'
			else
				action_status "$id" error 'Settings were saved, but the tunnel did not come up; see logread.'
			fi
			;;
		client-disable)
			action_status "$id" running 'Stopping the outbound tunnel...'
			if disable_client_action; then
				action_status "$id" ok 'Settings saved and tunnel disabled.'
			else
				action_status "$id" error 'Settings were saved, but the tunnel could not be stopped cleanly.'
			fi
			;;
		server-apply)
			action_status "$id" running 'Applying inbound server settings...'
			if server_apply_action "${1:-0}"; then
				action_status "$id" ok 'Inbound server settings applied.'
			else
				action_status "$id" error 'Inbound server apply failed; see /tmp/ikev2-manager-action.log.'
			fi
			;;
		advanced-set)
			action_status "$id" running 'Validating and loading the custom profile...'
			if ( advanced_set "$1" "$2" ); then
				action_status "$id" ok 'Custom profile loaded.'
			else
				action_status "$id" error 'Custom profile was rejected; previous profile restored.'
			fi
			;;
		advanced-reset)
			action_status "$id" running 'Restoring the generated profile...'
			if ( advanced_reset "$1" ); then
				action_status "$id" ok 'Generated profile restored.'
			else
				action_status "$id" error 'Unable to restore the generated profile.'
			fi
			;;
		*)
			action_status "$id" error 'Unknown background action.'
			;;
	esac
}

case "${1:-}" in
	overview)
		overview
		;;
	users)
		cut -f1 "$users_db"
		;;
	users-show)
		show_users
		;;
	user-secret-set)
		consume_user_input
		;;
	user-delete)
		user="${2:-}"
		valid_user "$user" || die 'Invalid username'
		delete_user "$user"
		;;
	disconnect)
		id="${2:-}"
		valid_uint "$id" || die 'Invalid IKE SA identifier'
		swanctl_quiet --terminate --ike-id "$id" --timeout 5 >/dev/null
		;;
	disconnect-all)
		swanctl_quiet --terminate --ike ikev2-in --timeout 5 >/dev/null || :
		;;
	server-get)
		for key in enabled identity pool4 gateway4 dns4 cert_source cert_file key_file dpd ike_rekey child_rekey mtu mobike fragmentation custom_config; do
			printf '%s=%s\n' "$key" "$(getv server "$key")"
		done
		;;
	server-set)
		shift
		[ "$#" -eq 14 ] || die 'Expected: enabled identity pool4 gateway4 dns4 cert_source cert_file key_file dpd ike_rekey child_rekey mtu mobike fragmentation'
		old_enabled="$(getv_default server enabled 0)"
		enabled="$1"; identity="$2"; pool4="$3"; gateway4="$4"; dns4="$5"; cert_source="$6"; cert_file="$7"; key_file="$8"
		dpd="$9"; shift 9
		ike_rekey="$1"; child_rekey="$2"; mtu="$3"; mobike="$4"; fragmentation="$5"
		[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
		[ "$enabled" = 0 ] || valid_host "$identity" || die 'Invalid server identity'
		valid_ipv4_pool "$pool4" || die 'Invalid IPv4 pool'
		valid_ipv4_cidr "$gateway4" || die 'Invalid IPv4 gateway/prefix'
		valid_ipv4 "$dns4" || die 'Invalid IPv4 DNS'
		valid_path_or_empty "$cert_source" || die 'Invalid certificate directory'
		valid_path_or_empty "$cert_file" || die 'Invalid certificate path'
		valid_path_or_empty "$key_file" || die 'Invalid private key path'
		in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
		in_range "$ike_rekey" 3600 86400 || die 'IKE rekey must be 3600-86400 seconds'
		in_range "$child_rekey" 900 86400 || die 'CHILD rekey must be 900-86400 seconds'
		in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
		[ "$mobike" = 0 ] || [ "$mobike" = 1 ] || die 'Invalid MOBIKE value'
		[ "$fragmentation" = 0 ] || [ "$fragmentation" = 1 ] || die 'Invalid fragmentation value'
		# Reject enabling the server with no certificate BEFORE mutating UCI.
		# Otherwise enabled=1 is committed and then sync_server_certificate dies,
		# leaving config that claims the server is on while nothing is rendered or
		# loaded (partial-applied state). Mirror sync_server_certificate's path
		# resolution so the pre-check matches what apply would use.
		if [ "$enabled" = 1 ]; then
			_certf="$cert_file"
			_keyf="$key_file"
			[ -n "$_certf" ] || _certf="$cert_source/$identity.fullchain.crt"
			[ -n "$_keyf" ] || _keyf="$cert_source/$identity.key"
			[ -s "$_certf" ] ||
				die "Server certificate not found: $_certf (issue or install it before enabling the server)"
			[ -s "$_keyf" ] ||
				die "Server private key not found: $_keyf"
		fi
		uci set "$uci_config.server.enabled=$enabled"
		uci set "$uci_config.server.identity=$identity"
		uci set "$uci_config.server.pool4=$pool4"
		uci set "$uci_config.server.gateway4=$gateway4"
		uci set "$uci_config.server.dns4=$dns4"
		uci set "$uci_config.server.cert_source=$cert_source"
		uci set "$uci_config.server.cert_file=$cert_file"
		uci set "$uci_config.server.key_file=$key_file"
		uci set "$uci_config.server.dpd=$dpd"
		uci set "$uci_config.server.ike_rekey=$ike_rekey"
		uci set "$uci_config.server.child_rekey=$child_rekey"
		uci set "$uci_config.server.mtu=$mtu"
		uci set "$uci_config.server.mobike=$mobike"
		uci set "$uci_config.server.fragmentation=$fragmentation"
		uci commit "$uci_config"
		[ "$enabled" = 0 ] || sync_server_certificate
		render_server
		# The firewall/PBR re-apply is slow. Commit first, then return an action id
		# immediately while one serialized worker applies the runtime state.
		if [ "$(getv globals configured)" = 1 ]; then
			[ "$old_enabled" = "$enabled" ] && pbr_changed=0 || pbr_changed=1
			start_action server-apply "$pbr_changed"
		fi
		;;
	server-access-get)
		printf 'local_ts=%s\n' "$(getv_default server local_ts 0.0.0.0/0)"
		printf 'allow_internet=%s\n' "$(getv_default server allow_internet 1)"
		printf 'allow_lan=%s\n' "$(getv_default server allow_lan 1)"
		printf 'allow_router=%s\n' "$(getv_default server allow_router 0)"
		printf 'router_ports=%s\n' "$(getv server router_ports)"
		printf 'lan_zones=%s\n' "$(get_list server lan_zone)"
		printf 'firewall_zone=%s\n' "$(getv_default server firewall_zone ikev2in)"
		printf 'outbound_zone=%s\n' "$(getv_default server outbound_zone ikev2out)"
		;;
	server-access-set)
		shift
		[ "$#" -eq 8 ] || [ "$#" -eq 9 ] ||
			die 'Expected: local_ts allow_internet allow_lan allow_router router_ports lan_zones firewall_zone outbound_zone [defer_apply]'
		local_ts="$1"; allow_internet="$2"; allow_lan="$3"; allow_router="$4"
		router_ports="$5"; lan_zones="$6"; firewall_zone="$7"; outbound_zone="$8"
		valid_ipv4_cidr_list "$local_ts" || die 'Invalid IPv4 traffic selector list'
		for value in "$allow_internet" "$allow_lan" "$allow_router"; do
			[ "$value" = 0 ] || [ "$value" = 1 ] || die 'Invalid access toggle'
		done
		valid_port_list "$router_ports" ||
			die 'Router ports must contain ports or ranges separated by spaces'
		valid_name_list "$lan_zones" || die 'Invalid LAN firewall zone list'
		valid_name "$firewall_zone" || die 'Invalid inbound firewall zone'
		valid_name "$outbound_zone" || die 'Invalid outbound firewall zone'
		uci set "$uci_config.server.local_ts=$(normalize_list "$local_ts")"
		uci set "$uci_config.server.allow_internet=$allow_internet"
		uci set "$uci_config.server.allow_lan=$allow_lan"
		uci set "$uci_config.server.allow_router=$allow_router"
		uci set "$uci_config.server.router_ports=$(normalize_list "$router_ports")"
		set_list server lan_zone "$lan_zones"
		uci set "$uci_config.server.firewall_zone=$firewall_zone"
		uci set "$uci_config.server.outbound_zone=$outbound_zone"
		uci commit "$uci_config"
		render_server
		# Optional 9th arg defers the apply: the UI saves access then server, and
		# the server save runs one detached apply that covers both (avoids two
		# concurrent fw4/PBR operations racing on the live router).
		if [ -z "$root" ] && [ "${9:-0}" != 1 ]; then
			"$system_helper" access-apply
			[ "$(getv server enabled)" = 0 ] || load_profile inbound
		fi
		;;
	acme-get)
		acme_emit
		;;
	acme-set)
		acme_set
		;;
	acme-issue)
		acme_issue
		;;
	acme-status)
		cat "$acme_status_file" 2>/dev/null || printf 'state=idle\n'
		;;
	client-get)
		for key in enabled remote_address remote_id username dpd mtu custom_config; do
			printf '%s=%s\n' "$key" "$(getv client "$key")"
		done
		;;
	client-input)
		consume_client_input
		;;
	reconnect-client)
		[ "$(getv globals configured)" = 1 ] || die 'Complete and enable Overview first'
		[ "$(getv client enabled)" = 1 ] || die 'Outbound client is disabled'
		start_action connect
		;;
	advanced-start)
		[ "$#" -eq 3 ] || die 'Expected: profile base64'
		start_action advanced-set "$2" "$3"
		;;
	advanced-reset-start)
		[ "$#" -eq 2 ] || die 'Expected: profile'
		start_action advanced-reset "$2"
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
	# Compatibility aliases for r26-r30 pages during an in-place package upgrade.
	connect-status | apply-status)
		cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		;;
	reload)
		apply_all
		;;
	server-ensure)
		# Self-heal a drifted inbound server: if it is enabled but the cert,
		# connection or pool is not actually loaded into charon (e.g. after a
		# strongSwan reinstall cleared /etc/swanctl, or a partial reload), re-sync
		# the certificate and reload everything. No-op when already healthy or the
		# server is disabled. Called by the health service; safe to run anytime.
		[ "$(getv server enabled)" = 1 ] || exit 0
		_need=0
		[ -s "$root/etc/swanctl/x509/ikev2.pem" ] || _need=1
		if [ -z "$root" ]; then
			swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' || _need=1
			swanctl --list-pools 2>/dev/null | grep -q 'router_pool4' || _need=1
		fi
		[ "$_need" = 1 ] || exit 0
		sync_server_certificate || die 'server-ensure: certificate sync failed'
		render_server
		render_users
		[ -z "$root" ] && swanctl_quiet --load-all >/dev/null || :
		printf 'server-ensured=1\n'
		;;
	advanced-mode)
		profile_values "${2:-}"
		getv_default "$profile_section" custom_config 0
		;;
	advanced-read)
		advanced_read "${2:-}"
		;;
	advanced-set)
		[ "$#" -eq 3 ] || die 'Expected: advanced-set PROFILE BASE64_CONFIG'
		advanced_set "$2" "$3"
		;;
	advanced-reset)
		[ "$#" -eq 2 ] || die 'Expected: advanced-reset PROFILE'
		advanced_reset "$2"
		;;
	*)
		die 'Usage: ikev2-manager {overview|users|users-show|user-secret-set|user-delete|disconnect|disconnect-all|server-get|server-set|server-access-get|server-access-set|server-ensure|client-get|client-input|reconnect-client|action-status|advanced-mode|advanced-read|advanced-start|advanced-reset-start|advanced-set|advanced-reset|reload}'
		;;
esac
