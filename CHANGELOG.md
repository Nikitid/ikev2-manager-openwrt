# Changelog

This project follows semantic versioning for the application version and uses
the OpenWrt package release suffix (`-rN`) for packaging revisions.

## Unreleased

No changes yet.

## 1.0.0-r4 - 2026-06-19

- Made `Installed-Size` independent of filesystem block allocation so canonical
  builds on macOS and Linux produce the same IPK bytes.
- Replaced the Gitleaks wrapper Action with a checksum-verified Gitleaks CLI
  invocation that correctly scans a repository beginning at a root commit.
- Updated pinned GitHub Actions to their Node.js 24 releases.

## 1.0.0-r3 - 2026-06-19

First public release.

- Consolidated inbound server settings into one compact card with expandable
  access, ACME and advanced connection panels.
- Moved VPN and ACME secret submission to permission-restricted temporary files
  so credentials do not appear in process command lines.
- Added ShellCheck, actionlint and Gitleaks CI checks and pinned every GitHub
  Action to an immutable commit.
- Simplified fail-closed routing to the native PBR unreachable default plus
  XFRM policy enforcement, removing the duplicate nftables drop layer and
  redundant PBR/firewall restarts.
- Made strongSwan the sole owner of automatic outbound reconnects; health
  monitoring now observes and repairs derived state without competing IKE
  initiations.
- Split detached-action and routing-invariant logic into reusable backend
  modules, and fixed nftset discovery for the OpenWrt nft CLI.
- Kept standard DoH as the default and marked HTTP/3/DoQ transports as
  experimental.
- Added opt-in DNS upstream management with provider presets for plain DNS,
  DoT, DoH, HTTP/3, DoQ and DNSCrypt, including live validation and rollback.
- Corrected VPN-user traffic directions so download and upload are shown from
  the remote user's perspective.
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
- Added the public-release compatibility gate, hardware capability report,
  safe dependency preflight, CI and sanitized support documentation.
- Unified long-running LuCI operations around serialized background jobs,
  status polling and reliable button recovery.
