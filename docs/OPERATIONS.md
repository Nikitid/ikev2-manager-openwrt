# Operations

## Health check

Use the LuCI Overview page or:

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
swanctl --list-sas
/etc/init.d/pbr status
```

`doctor_ok=1` means required packages, plugins and the XFRM module are
available. It does not prove that remote credentials or certificates are
correct.

## Expected states

With the outbound client enabled:

- `proxy-out` is established;
- `proxy4` is installed;
- `/var/run/ikev2-vip4` contains the assigned virtual IP;
- table `pbr_ikev2out` has a default route through `ipsec-out`;
- table `pbr_ikev2out` also contains an unreachable default.

With the client disconnected, the PBR table retains an unreachable default.
Selected destinations should fail, not use WAN.

The invariant can be tested without disconnecting traffic:

```sh
/usr/libexec/ikev2-manager-system failclosed-check
```

strongSwan owns normal CHILD_SA recovery. WAN hotplug and the health service
also recover a failed boot-time initiation without competing with a healthy
SA. The minimum interval between automatic attempts is configurable under
Outbound tunnel -> Connection -> Advanced connectivity (15-300 seconds,
default 15). The health service also synchronizes the virtual IP and repairs
derived routing state. If a rekey changes the assigned virtual IPv4, stale
conntrack entries using the previous VIP are removed while ordinary WAN
sessions are retained. The learned IPv4 domain set is kept in RAM during
normal operation and written once on an orderly shutdown, then restored on the
next boot for clients that retain a warm DNS cache.

## Common commands

```sh
/usr/libexec/ikev2-manager reconnect-client
/usr/libexec/ikev2-manager reload
/usr/libexec/ikev2-domains-community apply
/etc/init.d/ikev2-health restart
```

## LuCI background actions

Long-running LuCI actions return immediately and continue in a serialized
background worker. Each click receives a unique `action_id`; the page polls the
matching status and always re-enables the button on success, failure or timeout.

Inspect the current workers with:

```sh
/usr/libexec/ikev2-manager action-status
/usr/libexec/ikev2-manager-system action-status
```

Detailed logs are written to:

```text
/tmp/ikev2-manager-action.log
/tmp/ikev2-system-action.log
```

A browser polling timeout does not cancel the router operation. The UI reports
that it is still running and releases the button; use the status commands above
to inspect the final result.

Inspect inbound access:

```sh
/usr/libexec/ikev2-manager server-access-get
uci show firewall | grep ikev2access_
nft list chain inet fw4 input_ikev2in
nft list chain inet fw4 forward_ikev2in
```

The nft chain names follow the configured inbound firewall zone. On an
upgraded installation they may be `input_vpnin` and `forward_vpnin`.

## Inbound reachability

Traffic selectors decide what the client sends into the VPN. Firewall
permissions decide what is accepted after arrival.

The VPN Users online counter includes only IKEv2 SAs terminating on the
router's inbound server. A client connected directly to the remote outbound
gateway is not visible to the router as an inbound user and appears only as
traffic through the Outbound Tunnel.

For a full-tunnel client that may use the Internet, LAN and router services:

```text
Advertised destinations: 0.0.0.0/0
Allow Internet:           enabled
Allow internal networks: enabled
Allow router itself:     enabled
```

To limit router access, specify ports such as `53 1443 8000-8010`. The same
list applies to TCP and UDP. An empty list allows all protocols and ports.

A public IPv4 address assigned to the router resolves to local input when
accessed by an inbound VPN client. Router access therefore handles
same-router public-IP access without an additional hairpin rule.

## Raw configuration

```sh
/usr/libexec/ikev2-manager advanced-mode inbound
/usr/libexec/ikev2-manager advanced-read inbound
/usr/libexec/ikev2-manager advanced-mode outbound
/usr/libexec/ikev2-manager advanced-read outbound
```

Use LuCI to save raw profiles because the write command accepts base64 data.
Inbound changes reload all profiles without terminating the outbound SA.
Outbound changes reconnect `proxy4` and restart PBR. Resetting returns to the
form-generated profile.

## DNS verification

```sh
dnsmasq -v | grep nftset
nft list set inet fw4 pbr_ikev2out_4_dst_ip_ikev2pbr_domains
/usr/libexec/ikev2-manager-system dns-get
nslookup openwrt.org 127.0.0.1
```

Clients should receive the router as DNS. Plain port 53 can be redirected and
DoT port 853 blocked by Overview. DoH and OS private relay features must be
disabled separately when deterministic policy is required.

Managed upstream changes are tested before they are accepted. If the lookup
fails, the previous `dnsproxy` and `dhcp` configuration is restored. Selecting
**Keep existing router DNS** restores the snapshot saved when managed DNS was
first enabled.

## Certificate verification

```sh
openssl x509 -in /etc/swanctl/x509/ikev2.pem \
  -noout -subject -issuer -dates -fingerprint -sha256
```

After ACME renewal the hotplug script copies the configured source
certificate and key, then calls `swanctl --load-creds`.

## Backup

```sh
sysupgrade -b /tmp/ikev2-manager-backup.tar.gz
gzip -t /tmp/ikev2-manager-backup.tar.gz
```

Backups include reversible VPN passwords, the outbound EAP secret and the
inbound private key. Passwords are not returned by LuCI/RPC after creation, but
they remain present locally for strongSwan. Backups also include custom raw
profiles. Store them as secrets.

## Recovery

1. Disable Overview.
2. Confirm ordinary WAN access.
3. Run the dependency doctor.
4. Re-enable Overview.
5. Enable the outbound client.
6. Test one selected and one control domain.
7. Enable the inbound server only after its certificate is valid.

The application never needs a custom firewall4 template. Removing its named
UCI sections returns routing ownership to the base OpenWrt configuration.
