# IKEv2 Manager for OpenWrt

[![CI](https://github.com/nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A LuCI application for running an outbound IKEv2 tunnel, an optional inbound
IKEv2 server and domain-based policy routing on OpenWrt.

The project is designed for one practical setup: ordinary traffic keeps using
the home WAN, while selected domains or devices use an IKEv2 gateway. If that
tunnel goes down, policy-routed traffic fails closed instead of leaking through
the normal WAN.

Is this project compatible with [ikev2-manager-ubuntu](https://github.com/Nikitid/ikev2-manager-ubuntu)

## Features

- outbound IPv4 IKEv2/EAP client on an XFRM interface;
- domain-based routing through PBR and `dnsmasq-full` nftsets;
- full-tunnel and direct-WAN overrides for individual devices;
- fail-closed routing when the outbound tunnel is unavailable;
- optional inbound IKEv2/EAP server for phones and other remote devices;
- separate inbound permissions for Internet, local networks and router services;
- VPN user, session and traffic management;
- selectable DNS upstreams through `dnsproxy`:
  UDP, TCP, DoT, DoH, HTTP/3, DoQ and DNSCrypt;
- ACME certificate management;
- Russian and English interfaces;
- compatibility checks, rollback paths and diagnostics in LuCI.

## Requirements

- official OpenWrt `24.10.x`;
- firewall4;
- official OpenWrt package feeds;
- enough storage for strongSwan, PBR, `dnsmasq-full` and optional `dnsproxy`.

Vendor firmware, snapshots and OpenWrt 25.12+ are currently rejected. Hardware
support is checked by capabilities rather than by a fixed router-model list.
See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Installation

Download `luci-app-ikev2-manager_1.0.0-r5_all.ipk` from the GitHub release and
install it through:

```text
System -> Software -> Upload Package
```

Installing the IPK is intentionally passive. It adds the LuCI application and
helper scripts, but does not enable VPN services, replace `dnsmasq` or change
firewall and PBR rules.

Then open:

```text
Services -> IKEv2 Manager for OpenWrt -> Overview
```

The Overview page checks the router, installs the required runtime packages
only after confirmation and enables managed routing only when you explicitly
turn it on.

For command-line installation and migration from the pre-public
`luci-app-ikev2-pbr` package, see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## First setup

1. Open **Overview** and install the runtime dependencies.
2. Select the WAN and router networks managed by the application.
3. Enable managed mode.
4. Configure and connect the **Outbound Tunnel**.
5. Select services or enter domains under **Policy Routing**.
6. Optionally configure the **Inbound Server**, ACME and VPN users.

The application owns only UCI sections and interfaces created with its
`ikev2pbr_` naming. Disabling managed mode removes those generated sections but
keeps tunnel settings, users and domain lists.

## DNS and domain routing

`dnsmasq-full` remains the resolver for LAN and inbound VPN clients because PBR
uses its DNS answers to populate nftsets. Optional managed DNS forwards public
queries to a local `dnsproxy` instance.

Standard DoH is the default encrypted transport. HTTP/3 and DoQ options are
available but marked experimental because their behavior depends more heavily
on firmware, network path and UDP buffer limits.

DNS changes are tested before they are accepted. If validation fails, the
previous resolver configuration is restored automatically.

Clients must use the router resolver for deterministic domain classification.
Browser DoH, Android Private DNS and Apple Private Relay can bypass this model.

More details: [docs/DNS.md](docs/DNS.md).

## Domain-list sources

The package contains small project-maintained service lists. It can also
download selected lists at runtime from
[`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains).

External lists are not copied into this repository or its IPK. The upstream
repository does not currently publish a license, so its content is not covered
by this project's MIT license. Downloads are optional, validated, cached and
applied atomically; the previous active policy remains in place after a failed
update.

See [docs/DOMAIN_SOURCES.md](docs/DOMAIN_SOURCES.md) and [NOTICE](NOTICE).

## Safety model

- fresh installation is inactive by default;
- unsupported firmware is rejected before runtime changes;
- dependency replacement creates a recovery backup;
- generated routing is fail-closed;
- configuration updates are validated before service reloads;
- long operations run as serialized background jobs with visible status;
- VPN and ACME secrets are passed through permission-restricted temporary files,
  not command-line arguments;
- router backups still contain reversible VPN credentials and private keys and
  must be treated as secrets.

The application cannot protect traffic that bypasses router DNS, and it does
not configure the remote IKEv2 gateway.

## Build and validation

The canonical build works on macOS and Linux:

```sh
./scripts/ci-check.sh
```

It validates the public tree, versions, shell and JavaScript syntax, runtime
modules, JSON metadata and deterministic IPK output. GitHub CI additionally
runs ShellCheck, actionlint and Gitleaks.

Artifacts are written to `dist/`:

```text
luci-app-ikev2-manager_1.0.0-r5_all.ipk
SHA256SUMS
```

The custom packer uses deterministic GNU tar archives so the resulting IPK is
accepted by BusyBox `opkg` even when built on macOS.

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Compatibility](docs/COMPATIBILITY.md)
- [Deployment](docs/DEPLOYMENT.md)
- [DNS](docs/DNS.md)
- [Operations and recovery](docs/OPERATIONS.md)
- [Validation](docs/VALIDATION.md)
- [Publishing checklist](docs/PUBLISHING.md)
- [Security policy](SECURITY.md)

## Release

`1.0.0-r3` was the first public release. `1.0.0-r5` is the current package
revision. The application version follows semantic versioning; the `-rN`
suffix is the OpenWrt package revision.

## License

Project source code and project-maintained domain lists are available under the
[MIT License](LICENSE). Optional third-party lists downloaded at runtime are
covered separately in [NOTICE](NOTICE).
