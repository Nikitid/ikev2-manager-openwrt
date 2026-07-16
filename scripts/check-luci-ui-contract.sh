#!/bin/sh

set -eu

files="luci-ikev2-manager luci-ikev2-domains"

if grep -R -n --include='*.js' 'ui\.addNotification' $files; then
	printf '%s\n' 'LuCI actions must report through an inline result, not global notifications' >&2
	exit 1
fi

if grep -R -n --include='*.js' "dispatchEvent(new Event('ikev2-.*-updated" $files; then
	printf '%s\n' 'LuCI actions must refresh their concrete state instead of emitting unhandled update events' >&2
	exit 1
fi

if grep -R -n --include='*.js' -E 'please reload the page|Reload the Overview|reload in a moment' $files; then
	printf '%s\n' 'LuCI actions must not require a manual page reload to expose their result' >&2
	exit 1
fi

acl='luci-ikev2-manager/acl.json'
for broad_rule in \
	'"/usr/libexec/ikev2-manager *"' \
	'"/usr/libexec/ikev2-manager-system *"' \
	'"/usr/libexec/ikev2-domains-community *"' \
	'"/usr/libexec/ikev2-domain-router *"' \
	'"/usr/libexec/ikev2-devices *"'; do
	if grep -Fq "$broad_rule" "$acl"; then
		printf 'broad LuCI exec ACL is forbidden: %s\n' "$broad_rule" >&2
		exit 1
	fi
done

if grep -R -n --include='*.js' 'advanced-start.*encodeBase64' $files; then
	printf '%s\n' 'custom strongSwan profiles must use one-shot input files, not argv' >&2
	exit 1
fi
grep -Fq '"/var/run/ikev2-manager-profile-*.in": [ "write" ]' "$acl"
if grep -Fq 'Blocked — strongSwan upgrade required' \
	'luci-ikev2-manager/settings.js'; then
	printf '%s\n' 'inbound strongSwan advisory must not be rendered as a runtime block' >&2
	exit 1
fi
grep -Fq "notice ? 'info'" 'luci-ikev2-manager/setup.js'
grep -Fq "Reset app and remove dependencies" 'luci-ikev2-manager/setup.js'
grep -Fq "removing only the package in Software preserves configuration and dependencies" \
	'luci-ikev2-manager/setup.js'
grep -Fq "Date.now() + 120000" 'luci-ikev2-domains/editor.js'
grep -Fq "result.busy(_(st.message))" 'luci-ikev2-domains/editor.js'
for phase in \
	'Preparing selected domain lists...' \
	'Downloading selected service lists...' \
	'Building the combined policy list...' \
	'Restarting policy routing...'; do
	grep -Fq "$phase" 'luci-ikev2-domains/community-domains.sh'
done

printf '%s\n' 'luci UI contract OK'
