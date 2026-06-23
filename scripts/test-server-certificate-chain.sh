#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ssl/acme" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root/ikev2-manager-runtime/lib/actions.sh" \
	"$tmp/root/usr/libexec/ikev2-manager.d/actions.sh"

cat >"$tmp/bin/uci" <<EOF
#!/bin/sh
key=
for arg in "\$@"; do key="\$arg"; done
case "\$key" in
	ikev2-manager.server.enabled) echo 1 ;;
	ikev2-manager.server.identity) echo vpn.example.test ;;
	ikev2-manager.server.cert_source) echo "$tmp/root/etc/ssl/acme" ;;
	ikev2-manager.server.cert_file|ikev2-manager.server.key_file) ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

cat >"$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt" <<'EOF'
-----BEGIN CERTIFICATE-----
LEAF
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
INTERMEDIATE
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
CROSS-SIGNED-ISSUER
-----END CERTIFICATE-----
EOF
printf '%s\n' 'PRIVATE-KEY' >"$tmp/root/etc/ssl/acme/vpn.example.test.key"

IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync

cmp "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt" \
	"$tmp/root/etc/swanctl/x509/ikev2.pem"
grep -q '^INTERMEDIATE$' \
	"$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-1.pem"
grep -q '^CROSS-SIGNED-ISSUER$' \
	"$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-2.pem"
if grep -R -q '^LEAF$' "$tmp/root/etc/swanctl/x509ca"; then
	printf 'leaf certificate was copied into the CA chain directory\n' >&2
	exit 1
fi

printf 'server certificate chain tests OK\n'
