#!/bin/sh

# Persistent ownership record for the runtime dependency transaction. It lets
# removal restore only packages that this application added.
deps_state_dir="${IKEV2_DEPS_STATE_DIR:-/etc/ikev2-manager/deps-state}"
deps_state_dhcp_file="${IKEV2_DEPS_DHCP_FILE:-/etc/config/dhcp}"

deps_state_file() {
	printf '%s/%s\n' "$deps_state_dir" "$1"
}

deps_state_has() {
	file="$(deps_state_file "$1")"
	grep -Fxq "$2" "$file" 2>/dev/null
}

deps_state_value() {
	key="$1"
	sed -n "s/^${key}=//p" "$(deps_state_file metadata)" 2>/dev/null | head -n1
}

deps_state_ready() {
	[ "$(deps_state_value state)" = installed ] &&
	[ -r "$(deps_state_file owned-packages)" ] &&
	[ -r "$(deps_state_file dhcp.before)" ]
}

deps_state_capture() {
	deps_state_ready && return 0
	[ ! -e "$deps_state_dir" ] || return 1
	provider="$(pkg_dnsmasq_provider || true)"
	[ -n "$provider" ] || return 1
	[ -r "$deps_state_dhcp_file" ] || return 1

	parent="${deps_state_dir%/*}"
	tmp="${deps_state_dir}.new.$$"
	mkdir -p "$parent" || return 1
	rm -rf "$tmp"
	( umask 077; mkdir -p "$tmp" ) || return 1

	: >"$tmp/before-packages"
	: >"$tmp/owned-packages"
	for package in dnsmasq-full $(runtime_packages); do
		if pkg_installed "$package"; then
			printf '%s\n' "$package" >>"$tmp/before-packages"
		else
			printf '%s\n' "$package" >>"$tmp/owned-packages"
		fi
	done
	cp "$deps_state_dhcp_file" "$tmp/dhcp.before" || {
		rm -rf "$tmp"
		return 1
	}
	cat >"$tmp/metadata" <<EOF
version=1
state=installing
dns_provider=$provider
EOF
	rm -rf "$deps_state_dir"
	mv "$tmp" "$deps_state_dir"
}

deps_state_mark_installed() {
	[ -r "$(deps_state_file metadata)" ] || return 1
	provider="$(deps_state_value dns_provider)"
	[ -n "$provider" ] || return 1
	cat >"$(deps_state_file metadata)" <<EOF
version=1
state=installed
dns_provider=$provider
EOF
}

deps_state_clear() {
	rm -rf "$deps_state_dir"
}

deps_state_remaining() {
	file="$(deps_state_file owned-packages)"
	[ -r "$file" ] || return 1
	while IFS= read -r package; do
		[ -n "$package" ] || continue
		pkg_installed "$package" && printf '%s\n' "$package"
	done <"$file"
}

deps_state_restore() {
	deps_state_ready || return 1
	provider="$(deps_state_value dns_provider)"
	[ -n "$provider" ] || return 1
	owned="$(deps_state_file owned-packages)"

	if deps_state_has owned-packages dnsmasq-full; then
		pkg_restore_dnsmasq '' "$provider" || return 1
		cp "$(deps_state_file dhcp.before)" "$deps_state_dhcp_file" || return 1
		rm -f "${deps_state_dhcp_file}.apk-new" "${deps_state_dhcp_file}-opkg"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
	fi

	packages="$(grep -Fxv 'dnsmasq-full' "$owned" 2>/dev/null | tr '\n' ' ')"
	[ -z "$packages" ] || pkg_remove_runtime $packages || return 1

	[ -z "$(deps_state_remaining)" ] || return 1
	if deps_state_has owned-packages dnsmasq-full; then
		pkg_installed "$provider" || return 1
	fi
}
