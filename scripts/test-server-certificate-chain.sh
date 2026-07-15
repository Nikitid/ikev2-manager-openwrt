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

cat >"$tmp/leaf.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = vpn.example.test
[v3]
subjectAltName = DNS:vpn.example.test
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$tmp/leaf.cnf" \
	-keyout "$tmp/root/etc/ssl/acme/vpn.example.test.key" \
	-out "$tmp/leaf.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Intermediate One' \
	-keyout "$tmp/intermediate-one.key" -out "$tmp/intermediate-one.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Intermediate Two' \
	-keyout "$tmp/intermediate-two.key" -out "$tmp/intermediate-two.crt" >/dev/null 2>&1
cat "$tmp/leaf.crt" "$tmp/intermediate-one.crt" "$tmp/intermediate-two.crt" \
	>"$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"

IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync

cmp "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt" \
	"$tmp/root/etc/swanctl/x509/ikev2.pem"
openssl x509 -in "$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-1.pem" \
	-noout -subject | grep -q 'Intermediate One'
openssl x509 -in "$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-2.pem" \
	-noout -subject | grep -q 'Intermediate Two'

cp -R "$tmp/root/etc/swanctl" "$tmp/swanctl.before"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
	-out "$tmp/root/etc/ssl/acme/vpn.example.test.key" >/dev/null 2>&1
if IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync \
		>/dev/null 2>&1; then
	printf 'mismatched certificate key unexpectedly succeeded\n' >&2
	exit 1
fi
diff -ru "$tmp/swanctl.before" "$tmp/root/etc/swanctl"

printf 'server certificate chain tests OK\n'
