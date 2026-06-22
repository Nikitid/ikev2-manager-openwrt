# Changelog

This project follows semantic versioning for the application version and uses
the OpenWrt package release suffix (`-rN`) for packaging revisions.

## Unreleased

- Simplified the Policy Routing page by removing oversized summary cards and
  reducing the domain-routing engine to its status, explanation and mode
  switch.
- Fixed inbound EAP password changes leaving an older credential loaded in
  charon. Credential updates now clear and reload the full set without
  restarting strongSwan or established tunnels.
- Switched generated EAP secret sections to stable numeric names so valid user
  identities never become settings-parser section names.

## 1.0.0-r6 - 2026-06-21

- Added an experimental reliable domain-routing engine based on sing-box
  FakeIP and nftables TProxy. Selected domains keep stable virtual addresses,
  while only covered LAN and inbound-IKEv2 sources use the outbound tunnel.
- Kept the existing PBR nftset policy as a migration fallback for connections
  opened before FakeIP activation.
- Added transactional DNS cutover, persistent FakeIP mappings, automatic
  rollback, boot restoration and safe refresh after domain or coverage changes.
- Added a LuCI switch and runtime diagnostics for the domain-routing engine.
- Fixed the LuCI engine card reading the wrong load result, which made an
  active FakeIP backend appear as legacy mode after every page reload.
- Reworked the engine card into a compact technical summary and update its
  status and action immediately after a successful switch.
- Added lightweight FakeIP invariant checks to the health loop. A missing
  sing-box service, nftables TProxy table, policy rule or dnsmasq hand-off is
  repaired without restarting PBR, WAN or the router.
- Updated Overview, dependency diagnostics, DNS upstream help and device-rule
  notifications to reflect the reliable routing engine.
- Kept sing-box and TProxy in the confirmed runtime dependency workflow instead
  of making the passive LuCI bootstrap package install kernel modules eagerly.
- Added a low-frequency outbound data-plane probe so an installed but
  non-forwarding CHILD_SA is recovered after two consecutive failures.
- Tightened the probe interval to 20 seconds and added a second independent
  endpoint, reducing stale-SA recovery time without reacting to one provider
  timeout.
- Avoided false reconnect errors when IKE_AUTH completes just after the VICI
  initiation timeout.
- Added generic per-service IPv4 network targets for applications that bypass
  DNS, with Telegram MTProto data-centre ranges as the first bundled set.
- Fixed LuCI service-chip persistence and exposed the active direct-network
  count alongside domain and service totals.
- Derived direct-IP service metadata from packaged CIDR files, added health
  repair for a missing PBR service-network rule and covered the combined
  domain/CIDR transaction with a standalone regression test.
- Added separate custom IPv4 address and CIDR entries alongside custom domains;
  both remain independent from downloaded service updates.

## 1.0.0-r5 - 2026-06-21

- Added a locked, rate-limited outbound recovery helper used by WAN hotplug
  and the health watcher, so a boot-time initiation attempted before WAN is
  ready is retried automatically once DNS can resolve the configured peer.
- Added an outbound-tunnel setting for the automatic reconnect cooldown
  (15-300 seconds).
- Re-evaluate existing connections after a domain-policy rebuild by dropping
  only conntrack entries whose destinations now belong to the managed PBR set.
  This prevents hardware-offloaded sessions from retaining an earlier WAN
  route after a service is newly selected.
- Preserve the learned domain-IP set once during an orderly shutdown and
  restore it on the next boot, so devices with warm DNS caches do not bypass
  policy routing before repeating their DNS lookups.

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
