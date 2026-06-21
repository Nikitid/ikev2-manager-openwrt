# Architecture

## Traffic path

```text
LAN / IoT / inbound IKEv2 client
              |
              v
          dnsmasq-full
              |
     selected DNS name?
          /             \
        no               yes
        |                 |
        v                 v
 existing upstream    FakeIP 198.18/15
        |                 |
        v           nftables TProxy
 public resolver           |
                      source covered?
                       /          \
                     no            yes
                     |              |
                     v              v
                    WAN       sing-box mark
                                      |
                              table pbr_ikev2out
                                      |
                                  ipsec-out
                                      |
                         outbound IKEv2 gateway
```

The reliable engine gives selected domains persistent virtual addresses and
intercepts only those destinations. sing-box uses the domain rule and original
source address to choose the outbound route. Its IKEv2 outbound applies the
same mark used by PBR, so the existing fail-closed routing table remains the
single tunnel-safety boundary.

The domain list is also supplied to PBR as a `file://` destination. dnsmasq
continues adding resolved public IPv4 addresses to the generated nftset as a
migration fallback for clients that opened connections before FakeIP was
enabled.

## Fail-closed behavior

The PBR table always contains an unreachable default route. A lower-metric
default through `ipsec-out` is installed only while an outbound CHILD_SA and
virtual IPv4 address exist.

This route is the routing kill-switch: when the tunnel route disappears,
marked traffic terminates at `unreachable` and cannot fall through to the main
WAN table. If a stale route briefly remains without a matching SA, the kernel
XFRM policy drops the packet. Avoiding a duplicate nftables drop rule keeps PBR
and firewall reloads independent and removes an unnecessary failure mode.

## XFRM separation

```text
ipsec-out  if_id 42  outbound client
ipsec-in   if_id 43  inbound server
```

strongSwan does not install routes or virtual addresses into the main table.
The runtime synchronizes the outbound virtual IPv4 onto `ipsec-out` and the
configured inbound pool gateway onto `ipsec-in`.

## Configuration ownership

Persistent settings live in `/etc/config/ikev2-manager`. The application
creates or updates only:

- `network.ikev2out`;
- firewall sections named `ikev2pbr_*`;
- `pbr.ikev2pbr_domains` and `pbr.ikev2pbr_include`;
- generated strongSwan snippets under `/etc/swanctl/conf.d`;
- runtime domain files and secrets listed in the package keep file.

Managed DNS is opt-in. When enabled, the application also owns the
`dnsproxy.global`, `dnsproxy.servers`, `dnsproxy.cache` settings and the
upstream `server`/`noresolv` options of the primary dnsmasq instance. The
pre-existing `dnsproxy` and `dhcp` UCI exports are retained under
`/etc/ikev2-manager/dns-original/` and restored when managed DNS is disabled.
When reliable domain routing is active, dnsmasq remains pointed at sing-box and
the selected managed or restored resolver becomes sing-box's upstream.

Detached action status and routing invariant checks are small shared shell
modules under `/usr/libexec/ikev2-manager.d/`. The public helper commands stay
stable while implementation details remain testable in isolation.

Disabling Base Setup removes the managed network, firewall and PBR sections
but preserves tunnel settings, domain selections, users and certificates.

## Domain list lifecycle

Manual domains and selected community services are normalized and merged in
a temporary directory. The final file is replaced atomically only after all
selected services are available. Cached copies are used when upstream is
temporarily unavailable. A failed rebuild keeps the previous active policy.

The reliable engine rebuilds and validates its source rule-set before replacing
the active files. sing-box keeps FakeIP mappings in a persistent cache, so a
service restart or router boot preserves addresses already returned to clients.
The health service still snapshots the populated legacy nftset and restores it
after firewall or PBR restart for migration coverage.

## Inbound server

The optional server uses certificate authentication locally and
EAP-MSCHAPv2 for users. It assigns IPv4 addresses from the configured pool.
The server traffic selectors and firewall permissions are intentionally
separate:

- `local_ts` controls which IPv4 destinations clients route into IKEv2;
- **Allow Internet** permits forwarding to the home WAN and outbound IKEv2
  zone;
- **Allow internal networks** permits forwarding to selected LAN firewall
  zones;
- **Allow router itself** permits input to services bound to router
  addresses, optionally restricted to TCP/UDP ports.

For example, `local_ts = 0.0.0.0/0` advertises a full-tunnel route, but it
does not grant access by itself. Firewall permissions still determine what
the client may reach.

A public address owned by the router is a local input destination for an
inbound VPN client. Therefore enabling router access also permits a client
to reach a router-hosted service through that public address. No reflection
DNAT is required for this same-router case.

Certificates can be issued by OpenWrt ACME or supplied through explicit file
paths. The ACME hotplug hook copies renewed material into strongSwan and
reloads credentials.

## Raw profile overrides

The Inbound Server and Outbound Tunnel pages can expose the generated
strongSwan snippets. Enabling a custom profile stores it under
`/etc/ikev2-manager/` and replaces only that generated connection block.
Credentials remain managed separately.

Each custom profile is decoded to a temporary file, size checked, required
to contain a `connections` block, installed atomically and loaded with
`swanctl --load-all`. On failure the prior file and mode are restored.
