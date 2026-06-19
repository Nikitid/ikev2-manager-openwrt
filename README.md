# IKEv2 Manager for OpenWrt

[![CI](https://github.com/nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/nikitid/ikev2-manager-openwrt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

The OpenWrt companion to **IKEv2 Manager** for Ubuntu servers.

An installable LuCI application for:

- an outbound IPv4 IKEv2/EAP client on an XFRM interface;
- domain-based policy routing through that tunnel;
- fail-closed routing when the tunnel is unavailable;
- per-device domain, full-tunnel and direct-WAN modes;
- an optional inbound IKEv2/EAP server;
- independent inbound access controls for Internet, internal zones and router
  services;
- VPN user and session management;
- certificate, tunnel and traffic monitoring;
- inbound server self-healing after partial reloads or certificate drift;
- conditional IPv6 fail-fast for IPv4-only VPN policy routing;
- Russian and English application interfaces;
- optional raw strongSwan overrides for both tunnel profiles.

The package targets official OpenWrt 24.10.x with firewall4 and PBR 1.2.x.
Compatibility is capability-based rather than model-based: firmware source,
target, architecture, kernel ABI, package feeds, storage, memory and reserved
XFRM resources are checked before managed routing can be enabled.

## Installation behavior

Installing the package does **not** create firewall or PBR policies and does
not connect either tunnel. The release IPK is a LuCI/bootstrap package: it
installs the UI, helper scripts and an inactive UCI configuration with
`configured=0`. Runtime dependencies such as PBR, strongSwan and
`dnsmasq-full` and `dnsproxy` are checked and installed from the setup flow
before activation.

After installation open:

```text
LuCI -> Services -> IKEv2 Manager for OpenWrt -> Overview
```

Review the OpenWrt network names and firewall zones, then explicitly enable
the managed configuration.

## Install a release

Download the release `.ipk`, then install it in LuCI:

```text
System -> Software -> Upload Package
```

Upload `luci-app-ikev2-manager_1.0.0-r3_all.ipk` and install it. The package is
safe to install from the web UI on a fresh supported system: it does not replace
`dnsmasq`, start strongSwan, enable PBR or change firewall rules. Its package
pre-install script rejects unsupported OpenWrt releases and vendor firmware.

If the pre-public `luci-app-ikev2-pbr` package is installed, use
`scripts/install.sh` for the one-time package-name migration.

For CLI installation, upload the `.ipk` and optional installer to `/tmp`, then
run:

```sh
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

The installer:

1. verifies OpenWrt 24.10.x;
2. creates a sysupgrade backup in `/tmp`;
3. replaces `dnsmasq` with `dnsmasq-full` when required;
4. installs the package and dependencies through the same setup helper used by LuCI;
5. leaves VPN and policy routing disabled.

The package does not enable its init services during installation. They are
enabled only after Overview is explicitly activated in LuCI.

Existing manually configured installations can be adopted after taking a
backup:

```sh
/usr/libexec/ikev2-manager-system adopt-legacy
```

The command removes the known legacy firewall/PBR sections, recreates them as
application-owned `ikev2pbr_*` sections, checks firewall4 and keeps a rollback
snapshot under `/etc/ikev2-manager/backups/`.

Replacing dnsmasq briefly restarts DNS and DHCP. Existing
`/etc/config/dhcp` is preserved.

## Initial configuration

1. Open **Overview**.
2. Confirm the WAN network.
3. Select the router networks whose domains should use IKEv2. Firewall zones
   are detected automatically. Inbound VPN clients can be included separately.
4. Use **Install runtime dependencies** if the readiness check reports missing packages.
5. Save and enable the managed configuration.
6. Configure **Outbound Tunnel** and connect it.
7. Optionally choose the router DNS transport and provider under
   **Outbound Tunnel -> DNS upstream**.
8. Select services or domains in **Policy Routing**.
9. Optionally configure ACME in LuCI, then enable **Inbound Server**.
10. Choose inbound routes and access permissions.
11. Add credentials under **VPN Users**.

## DNS upstream

`dnsmasq-full` remains the LAN and VPN-client resolver because PBR uses its
DNS answers to populate nftsets. It can forward public queries to a local
`dnsproxy` instance, which supports UDP, TCP, DNS-over-TLS, DNS-over-HTTPS,
DoH over HTTP/3, DNS-over-QUIC and DNSCrypt upstreams. Standard DoH is the
default; QUIC-based transports are exposed as experimental options.

The DNS block on the Outbound Tunnel page offers provider presets and a custom
endpoint mode. Enabling managed DNS first saves the existing `dnsproxy` and
`dhcp` UCI configuration. Every change is applied with a live lookup test; a
failed test restores the previous resolver automatically. Selecting
**Keep existing router DNS** restores the configuration captured before the
application took ownership.

The application owns only UCI sections prefixed `ikev2pbr_`, the
`network.ikev2out` interface and the `pbr.ikev2pbr_*` sections. Managed DNS
additionally owns the documented `dnsproxy` and primary dnsmasq upstream
settings while enabled.

## Domain-list sources

The Policy Routing page includes small project-maintained service lists and an
optional integration with
[`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains).
Selected external lists are downloaded by the router at runtime; they are not
embedded in this package. Downloads are normalized, cached and merged
atomically. If an update fails, the previous active policy remains in place.

The upstream repository currently does not publish a license file. This
project therefore does not redistribute its domain-list contents and makes no
claim that they are covered by this project's MIT license. See
[docs/DOMAIN_SOURCES.md](docs/DOMAIN_SOURCES.md) and [NOTICE](NOTICE).

## Build

The release package is assembled by `scripts/build-ipk.sh`, which stages the
tree and packs it with `scripts/pack-ipk.py` (a macOS-safe `opkg` packer that
avoids the PAX headers busybox `tar` cannot read). It contains only
architecture-independent scripts, UCI defaults and LuCI assets:

```sh
./scripts/build-ipk.sh
```

The resulting architecture-independent package and checksum are written to
`dist/`.

### Repository layout

- `luci-ikev2-manager/` — Overview, tunnel and user-management LuCI views;
- `luci-ikev2-domains/` — domain-policy editor, service lists and helpers;
- `ikev2-manager-runtime/` — router services, hooks and runtime controller;
- `openwrt/files/` — package-owned configuration and sysupgrade keep files;
- `scripts/` — validation, staging, installation and release tooling.

`scripts/build-ipk.sh` is the **canonical** build: it runs on macOS and Linux
and side-steps a historical
breakage where packing on macOS with the system `tar` (bsdtar/libarchive)
emitted PAX headers that busybox `opkg` rejects
(`Unknown typeflag: 0x78` → `Malformed package file`). That risk only returns
if the IPK is packed with raw `tar`; the canonical packer uses Python's GNU
tar format and is safe.

Package identity (name/version/release/arch) lives in `release.env`, the single
source of truth the canonical build reads. The OpenWrt SDK `Makefile` is a
**secondary** build (Linux/SDK only — it is not run in the macOS workflow). It
keeps its own `PKG_*` literals because OpenWrt's relative include path is
unreliable; `scripts/check-version-sync.sh` (run automatically by
`build-ipk.sh`) fails the build if those literals drift from `release.env`.
To cut a new release, edit `release.env` and the Makefile `PKG_VERSION`/
`PKG_RELEASE` together.

## Important limitations

- Domain routing is IPv4-only.
- When no IPv6 WAN default route exists, managed mode installs an unreachable
  global IPv6 route so dual-stack clients fail fast to IPv4 instead of bypassing
  or hanging. Local link-local and ULA IPv6 remain available.
- Clients must use the router DNS resolver for deterministic classification.
- Browser DoH, Android Private DNS and Apple Private Relay can bypass it.
- The outbound gateway must support IKEv2, EAP-MSCHAPv2, virtual IPv4 and the
  configured cryptographic profile.
- VPN passwords are write-only in LuCI, but strongSwan requires reversible
  local secrets for EAP-MSCHAPv2. Router backups therefore contain secrets.
- Raw strongSwan overrides bypass the form generator. The application
  validates and loads them, but their semantics remain the administrator's
  responsibility.
- This package does not configure the remote IKEv2 gateway.

## Public release status

`1.0.0-r1` is the first public package identity. Unsupported firmware is
rejected before installation or activation, dependency availability is checked
with `opkg --noaction` before DNS is touched, and both `dnsmasq` packages are
downloaded before replacement so the original resolver can be restored locally.

See [ARCHITECTURE.md](ARCHITECTURE.md),
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md),
[docs/DNS.md](docs/DNS.md),
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md),
[docs/VALIDATION.md](docs/VALIDATION.md) and
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## License

The application source code is licensed under the MIT License. Optional
third-party domain lists downloaded at runtime are not covered by that license;
see [NOTICE](NOTICE).
