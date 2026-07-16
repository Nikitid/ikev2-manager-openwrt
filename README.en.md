# IKEv2 Manager for OpenWrt

[Русский](README.md)

[![CI](https://github.com/Nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/Nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

LuCI application for an outbound IKEv2 tunnel, an optional inbound IKEv2
server and selective IPv4 policy routing on OpenWrt.

Ordinary traffic continues through the home WAN. Selected services, custom
domains, IP addresses, networks or entire devices can use the outbound IKEv2
gateway. If the tunnel is unavailable, selected traffic fails closed instead
of leaking through WAN.

The project is compatible with
[ikev2-manager-ubuntu](https://github.com/Nikitid/ikev2-manager-ubuntu) as the
remote gateway.

## Features

- outbound IKEv2/EAP client over an XFRM interface;
- stable domain routing using sing-box FakeIP and nftables TProxy;
- curated service lists plus custom domains, IPv4 addresses and CIDR networks;
- direct-IP coverage for applications such as Telegram;
- per-device domain, full-tunnel and direct-WAN modes;
- fail-closed PBR with automatic tunnel and routing recovery;
- optional inbound IKEv2/EAP server with VPN user management;
- separate inbound access to Internet, local networks and router services;
- optional DNS upstream management: UDP, TCP, DoT, DoH, HTTP/3, DoQ and
  DNSCrypt;
- ACME certificate integration;
- Russian and English LuCI interfaces.

## Requirements

- official OpenWrt `24.10.x`, or experimental `25.12.x` support;
- firewall4/nftables and matching official package feeds;
- IPv4 WAN;
- sufficient storage for strongSwan, PBR, sing-box, `dnsmasq-full` and
  `dnsproxy`.

Vendor firmware, snapshots and firewall3 are not supported. OpenWrt 25.12 is
currently limited to the validated `mediatek/filogic` and
`aarch64_cortex-a53` target; OpenWrt 24.10 remains the stable line.
Compatibility is checked by capabilities rather than by a router whitelist.

## Installation

### OpenWrt 24.10

Download `luci-app-ikev2-manager_1.1.1_all.ipk` from
[Releases](https://github.com/Nikitid/ikev2-manager-openwrt/releases) and upload
it through:

```text
System -> Software -> Upload Package
```

The IPK is passive: installing it does not start a VPN, replace DNS or enable
PBR. Open:

```text
Services -> IKEv2 Manager for OpenWrt -> Overview
```

Then:

1. install the checked runtime dependencies;
2. select the WAN and protected router networks;
3. enable managed mode;
4. configure and connect the outbound tunnel;
5. choose services or add custom destinations under **Policy Routing**;
6. optionally configure the inbound server, ACME and VPN users.

For CLI installation, migration, diagnostics and recovery, see
[Operations](docs/OPERATIONS.md).

### OpenWrt 25.12

The first installation registers the signed project feed:

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-manager-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

The bootstrap validates the OpenWrt release and architecture, the public-key
SHA-256, APK/feed signatures and the package transaction. A failed download or
validation restores the previous key/feed state before any package is
installed. Later updates use `apk update` and
`apk upgrade luci-app-ikev2-manager`.

## Support

Use [GitHub Discussions](https://github.com/Nikitid/ikev2-manager-openwrt/discussions)
for setup questions and
[GitHub Issues](https://github.com/Nikitid/ikev2-manager-openwrt/issues) for
reproducible bugs. Before reporting a bug, run:

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
```

Remove public IPs, private domains, usernames and credentials from output.
Never attach a router backup or files from `/etc/ikev2-manager/` and
`/etc/swanctl/private/`.

## Policy routing

Reliable mode keeps `dnsmasq-full` as the client resolver and sends public DNS
queries through sing-box. Selected domain suffixes receive persistent FakeIP
addresses from `198.18.0.0/15`; nftables intercepts only those destinations.
sing-box sends covered sources through `ipsec-out`, while unrelated traffic
never enters the proxy path.

Services that connect directly to fixed networks can also ship validated CIDR
targets. Administrators can add:

- **Custom domains** — one domain suffix per line;
- **Custom IP addresses and networks** — one IPv4 address or CIDR per line;
- **Device rules** — domain routing, full tunnel or direct WAN.

All generated lists are assembled in temporary files and replaced only after
validation. Failed downloads or invalid custom entries leave the previous
working policy active. The health service repairs missing FakeIP and direct-IP
routing state without restarting WAN.

Clients must use router DNS for domain classification. Browser DoH, Android
Private DNS and Apple Private Relay can bypass it. Direct IP/CIDR policies do
not depend on DNS.

## Domain-list sources

Small project-maintained lists are included under
`luci-ikev2-domains/local-services/`. Optional lists are downloaded at runtime
from [`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains),
validated, cached and never bundled into this repository or its IPK.

The upstream repository did not publish a license when this integration was
added, so downloaded content is not covered by this project's MIT License.
See [NOTICE](NOTICE).

## Safety

- a fresh installation is inactive;
- unsupported firmware and missing kernel packages are rejected before setup;
- selected traffic uses an unreachable fallback route when IKEv2 is down;
- DNS, routing and service-list updates have validation and rollback;
- long LuCI actions are serialized and report their actual status;
- a competing action is rejected promptly, while lists and status refresh in
  place without a manual page reload;
- full dependency reset validates DNS restoration first, removes only packages
  installed by the application and retains shared packages used elsewhere;
- submitted VPN and ACME secrets use permission-restricted temporary files;
- backups contain credentials and private keys and must be stored as secrets.

## Build

The canonical macOS/Linux validation and build command is:

```sh
./scripts/ci-check.sh
```

It checks versions, the public tree, shell and JavaScript syntax, JSON,
runtime modules, domain/CIDR transactions and deterministic IPK output.
Artifacts are written to `dist/`.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Operations](docs/OPERATIONS.md)
- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Project source and project-maintained lists are available under the
[MIT License](LICENSE). Optional downloaded lists are described in
[NOTICE](NOTICE).
