# Changelog

This project follows semantic versioning for the application version and uses
the OpenWrt package release suffix (`-rN`) for packaging revisions.

## Unreleased

- Switched the project license to the MIT License and added complete
  third-party domain-source documentation.
- Stopped bundling the locally cached TikTok list; it is now fetched only
  through the optional external-list integration.
- Aligned the source tree with the `ikev2-manager-openwrt` repository name:
  LuCI domain components and router runtime files now use explicit
  `ikev2-manager` directory names.
- Renamed the sysupgrade keep-file source to `ikev2-manager`.
- Moved the inbound-server state into its configuration card.
- Reworked VPN user rows into compact responsive cards with icon actions and
  clearer session traffic labels.
- Replaced the full dependency matrix with four priority checks and an
  expandable diagnostic report.
- Reviewed Russian UI terminology and removed awkward literal translations.

## 1.0.0-r1

- Public-release compatibility gate and hardware capability report.
- Safe dependency preflight before changing dnsmasq or installing kernel modules.
- Public repository metadata, CI and sanitized validation documentation.
- Unified public name and package identity: IKEv2 Manager for OpenWrt /
  `luci-app-ikev2-manager`.

## Pre-public development

- Faster outbound and inbound actions without unnecessary full PBR rebuilds.
- Live LuCI status refresh and in-place device exception updates.
- Unified asynchronous LuCI action contract with serialized workers, polling,
  timeout handling and guaranteed button recovery.
