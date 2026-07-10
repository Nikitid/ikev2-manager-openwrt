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
- local tests for package file selection and APK package-version parsing.

Still required before treating 25.12 as supported:

- build the package as an OpenWrt 25.12 APK with the matching SDK;
- validate APK maintainer scripts on-device;
- run `preflight`, dependency installation, `doctor`, apply/disable/remove on
  the real router target;
- confirm target-specific kmods exist for the router kernel ABI.
