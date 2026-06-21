# Architecture

## Traffic paths

```text
Selected domain
client -> dnsmasq -> sing-box FakeIP -> nftables TProxy
       -> source policy -> PBR mark -> ipsec-out -> IKEv2 gateway

Selected IPv4/CIDR
client -> PBR destination rule -> ipsec-out -> IKEv2 gateway

Ordinary destination
client -> normal OpenWrt routing -> WAN
```

Selected domain suffixes receive persistent addresses from `198.18.0.0/15`.
Only that range is intercepted by TProxy. sing-box checks the original source
network and binds its outbound connection to `ipsec-out`.

Direct-IP service networks and administrator-defined IPv4/CIDR entries use a
separate PBR destination policy. Both paths share the same covered networks,
device exclusions and fail-closed routing table.

## Fail-closed boundary

PBR table `pbr_ikev2out` always contains an unreachable default. A lower-metric
default through `ipsec-out` exists only while the outbound CHILD_SA and virtual
IPv4 are usable.

When the tunnel route disappears, marked traffic terminates at the unreachable
route and cannot fall through to the WAN table. A stale route without a
matching SA is additionally rejected by the kernel XFRM policy.

```text
ipsec-out  if_id 42  outbound client
ipsec-in   if_id 43  inbound server
```

strongSwan does not install routes into the main table. The runtime owns the
XFRM interfaces, synchronizes virtual addresses and lets PBR own route
selection.

## DNS

`dnsmasq-full` remains the resolver for LAN and inbound VPN clients:

```text
client -> dnsmasq-full -> sing-box DNS -> dnsproxy or existing resolver
```

Reliable mode disables the dnsmasq cache and stores FakeIP mappings in
`/etc/ikev2-manager/domain-router-cache.db`. Existing mappings therefore
survive service restarts and boots. Non-selected queries receive ordinary
public IPv4 answers.

Managed DNS is optional. `dnsproxy` supports UDP, TCP, DoT, DoH, HTTP/3, DoQ
and DNSCrypt. Standard DoH is the conservative default; HTTP/3 and DoQ remain
experimental. Resolver changes are validated and rolled back on failure.

## Destination lifecycle

The active policy is built from:

- selected service domain lists;
- packaged direct-service CIDR files;
- `/etc/pbr-ikev2-domains.manual.txt`;
- `/etc/pbr-ikev2-addresses.manual.txt`.

Every input is normalized in a temporary directory. Service downloads are
size-limited, validated and cached. Bare custom IPv4 addresses become `/32`.
The active domain and CIDR files are replaced only after the complete build
succeeds.

Optional external lists come from `itdoginfo/allow-domains` at runtime. They
are not redistributed by this project. Packaged `.lst` and `.cidrs` files are
project-maintained and covered by the project license.

## Ownership and recovery

Persistent settings live in `/etc/config/ikev2-manager`. Generated UCI sections
use the `ikev2pbr_` prefix. Disabling managed mode removes generated network,
firewall and PBR state while preserving user settings, certificates and
destination lists.

The health service checks:

- outbound CHILD_SA data-plane reachability;
- virtual IP and fail-closed routes;
- sing-box, dnsmasq, TProxy and policy-rule invariants;
- the direct-service CIDR PBR rule;
- inbound server configuration drift.

Repairs are serialized and avoid restarting WAN or the router.

## Inbound server

The optional inbound server uses certificate authentication for the router and
EAP-MSCHAPv2 for users. Traffic selectors decide what clients send into IKEv2;
firewall permissions independently allow Internet, selected local zones and
router services.

Raw strongSwan profile overrides are validated, installed atomically and rolled
back when loading fails. Credentials remain managed separately.
