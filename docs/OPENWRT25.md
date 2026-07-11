# OpenWrt 25.12/apk Port

This branch is the OpenWrt 25.12/apk compatibility line. The stable release
line remains `main` until the 25.12 path is built as an APK and validated on a
real router target.

## Branch Model

- `main`: stable OpenWrt 24.10/opkg releases.
- `openwrt-25-apk`: OpenWrt 25.12/apk porting and validation.
- Merge back to `main` only after the 24.10 IPK path and the 25.12 APK path are
  both covered by local checks and router validation.

## Compatibility Policy

The runtime accepts only these release/package-manager pairs:

- OpenWrt `24.10.x` with `opkg`;
- OpenWrt `25.12.x` with `apk`.

Other versions, vendor firmware, snapshots, mismatched package managers and
non-release package feeds fail before dependency installation.

## Current Scope

Implemented in this branch:

- package-manager abstraction for `opkg` and `apk` runtime operations;
- preflight checks for OpenWrt 25.12 release feeds;
- dependency installation/removal flow prepared for `apk`;
- LuCI package-installed detection for `apk` systems;
- apk-tools 3 installed-version queries and exact dnsmasq provider detection;
- trusted-feed dnsmasq-full replacement with apk solver rollback;
- exact dnsmasq nftset capability validation;
- reproducible APK builds with the official OpenWrt 25.12 SDK;
- a project-owned P-256 release key, signed APKs and signed `packages.adb`;
- a rollback-safe bootstrap installer for the GitHub Release APK feed.

Still required before treating 25.12 as supported:

- run `preflight`, dependency installation, `doctor`, apply/disable/remove on
  the real router target;
- confirm target-specific kmods exist for the router kernel ABI.

## Signed feed

The first OpenWrt 25.12 installation uses the bootstrap script:

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-manager-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

The script accepts only official OpenWrt 25.12 on the currently validated
`mediatek/filogic` and `aarch64_cortex-a53` target, verifies the release
public key checksum, installs the key under `/etc/apk/keys/`, registers the
signed GitHub Release feed, refreshes indexes, simulates the transaction and
only then installs the package. Failed bootstrap attempts restore the previous
key/feed configuration.

Later package updates use the normal package manager:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```
