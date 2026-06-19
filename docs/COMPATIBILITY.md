# Compatibility

IKEv2 Manager for OpenWrt intentionally uses a narrow support matrix. A router model
is not sufficient evidence by itself: the OpenWrt release, kernel ABI, target,
package feeds and firewall stack must agree.

## Supported

| Component | Requirement |
|---|---|
| Firmware | Official OpenWrt 24.10.x |
| Package manager | `opkg` |
| Firewall | firewall4 / nftables |
| PBR | 1.2.x |
| strongSwan | 5.9.x packages from the matching OpenWrt feed |
| Kernel | Matching `kmod-xfrm-interface` available for the running kernel ABI |
| DNS | `dnsmasq-full` with nftset support |
| Routing | IPv4 WAN and protected networks |
| Storage | At least 12 MiB free persistent storage; 24 MiB recommended |
| Temporary space | At least 16 MiB free in `/tmp` |
| Memory | At least 32 MiB available during dependency installation |

The validated development device is a GL.iNet Flint 2 running official OpenWrt
24.10.x. This is evidence for that target, not a device whitelist.

## Explicitly unsupported

- OpenWrt 25.12+ until the installer and release packaging support `apk`;
- vendor-modified firmware and forks unless listed as validated;
- OpenWrt snapshots;
- firewall3/iptables systems;
- mismatched or third-party kernel module feeds;
- PBR versions outside 1.2.x;
- routers where XFRM interface IDs 42/43 or names `ipsec-out`/`ipsec-in` are
  already owned by another VPN stack.

Unsupported systems are rejected before managed routing is enabled. Package
installation also rejects unsupported OpenWrt releases so a LuCI upload cannot
look successful while leaving a non-functional application.

The package currently requires the standard official release feeds under
`downloads.openwrt.org/releases/24.10.*`. Custom feed sets are rejected because
they cannot guarantee a kernel-module ABI match.

## Why kernel ABI matters

`kmod-xfrm-interface` is compiled for one exact OpenWrt kernel ABI. A package
for the same CPU architecture but a different kernel build is not compatible.
The dependency installer checks that every required package has either an
installed instance or a candidate in the configured feeds before replacing
dnsmasq or changing runtime state.

## Compatibility report

Run:

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager-system deps-plan
```

The report includes firmware identity, board, target, architecture, kernel,
storage, memory, clock, package manager, crypto acceleration, flow offloading,
PBR version, XFRM support and reserved resource collisions. Missing crypto
acceleration and enabled flow offloading are warnings, not hard failures.
`doctor_ok=1` is required before managed mode can be enabled.

`deps-plan` asks `opkg` to solve the complete dependency set without making
changes. It catches missing architecture packages and kernel ABI mismatches.

## Upstream references

- [OpenWrt 24.10 release notes](https://openwrt.org/releases/24.10/notes-24.10.0)
- [Official OpenWrt release downloads](https://downloads.openwrt.org/releases/)
- [OpenWrt PBR package source](https://github.com/openwrt/packages/tree/openwrt-24.10/net/pbr)
- [OpenWrt package build metadata](https://github.com/openwrt/openwrt/tree/openwrt-24.10/include)
