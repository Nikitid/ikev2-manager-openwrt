#!/bin/sh
# Package-manager compatibility helpers for OpenWrt 24.10 (opkg) and
# OpenWrt 25.12+ (apk). Callers keep policy decisions; this file only hides
# command syntax differences.

pkg_manager_detect() {
	if command -v apk >/dev/null 2>&1 &&
		{ [ -r /etc/apk/repositories ] || [ -d /etc/apk/repositories.d ]; }; then
		printf 'apk\n'
	elif command -v opkg >/dev/null 2>&1; then
		printf 'opkg\n'
	elif command -v apk >/dev/null 2>&1; then
		printf 'apk\n'
	else
		printf 'missing\n'
	fi
}

pkg_manager_name() {
	printf '%s\n' "${IKEV2_PACKAGE_MANAGER:-$(pkg_manager_detect)}"
}

pkg_manager_supported() {
	case "$(pkg_manager_name)" in
		opkg | apk) return 0 ;;
		*) return 1 ;;
	esac
}

pkg_update() {
	case "$(pkg_manager_name)" in
		opkg) opkg update ;;
		apk) apk update ;;
		*) return 1 ;;
	esac
}

pkg_install_plan() {
	case "$(pkg_manager_name)" in
		opkg) opkg install --noaction "$@" ;;
		apk) apk add --simulate "$@" ;;
		*) return 1 ;;
	esac
}

pkg_install() {
	case "$(pkg_manager_name)" in
		opkg) opkg install "$@" ;;
		apk) apk add "$@" ;;
		*) return 1 ;;
	esac
}

pkg_remove_runtime() {
	case "$(pkg_manager_name)" in
		opkg) opkg remove --force-depends "$@" ;;
		apk) apk del "$@" ;;
		*) return 1 ;;
	esac
}

pkg_download() {
	case "$(pkg_manager_name)" in
		opkg) opkg download "$@" ;;
		apk) apk fetch "$@" ;;
		*) return 1 ;;
	esac
}

pkg_installed() {
	case "$(pkg_manager_name)" in
		opkg) opkg list-installed "$1" 2>/dev/null | grep -q "^$1 " ;;
		apk) apk info -e "$1" >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

pkg_version() {
	case "$(pkg_manager_name)" in
		opkg)
			opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p' | head -n1
			;;
		apk)
			apk info -v "$1" 2>/dev/null |
				sed -n "s/^$1-//p" | head -n1
			;;
	esac
}

pkg_package_file() {
	dir="$1"
	name="$2"
	case "$(pkg_manager_name)" in
		opkg) find "$dir" -name "${name}_*.ipk" -print 2>/dev/null | head -n1 ;;
		apk)
			prefix="${name}-"
			find "$dir" -name "${name}-*.apk" -print 2>/dev/null |
				while IFS= read -r package_file; do
					file_name="${package_file##*/}"
					version="${file_name#$prefix}"
					case "$version" in
						[0-9]*) printf '%s\n' "$package_file"; break ;;
					esac
				done
			;;
	esac
}

pkg_feed_file_matches() {
	pattern="$1"
	shift
	for file in "$@"; do
		[ -r "$file" ] || continue
		grep -qE "$pattern" "$file" && return 0
	done
	return 1
}

pkg_release_feed_ok() {
	release="$1"
	case "$(pkg_manager_name):$release" in
		opkg:24.10.*)
			pkg_feed_file_matches 'downloads\.openwrt\.org/releases/24\.10\.' \
				/etc/opkg/distfeeds.conf
			;;
		apk:25.12.*)
			pkg_feed_file_matches \
				'downloads\.openwrt\.org/releases/(25\.12\.|packages-25\.12)' \
				/etc/apk/repositories /etc/apk/repositories.d/*
			;;
		*) return 1 ;;
	esac
}
