# Changelog

This project follows semantic versioning for the application and release tags.

## Unreleased

## 1.0.5 - 2026-07-12
## 1.0.8 - 2026-07-12

- Keep `ca-bundle` installed: APK requires it to securely update HTTPS feeds
  after a dependency reset.
- Remove the application's dnsmasq hand-off to a removed local dnsproxy so a
  clean Install can resolve package feeds through the original WAN resolver.

## 1.0.7 - 2026-07-12

- Do not record `jsonfilter` as a removable runtime package: it is a required
  dependency of the LuCI bootstrap package and must remain installed while the
  application is present.

## 1.0.6 - 2026-07-12

- Runtime dependency installation now records the original DNS/DHCP state and
  every package that was not present before installation.
- Remove restores that saved state and deletes only application-owned runtime
  packages, including DNS, ACME and generic tools when this app installed them.
- Installation rollback now restores the saved baseline when package setup
  fails, instead of leaving a partial dependency stack.


- Fixed LuCI Software installs, upgrades and removals losing their rpcd JSON
  response: package lifecycle scripts no longer restart rpcd while apk or opkg
  is executing.
- Fixed runtime dependency removal on apk: absent optional modules are filtered
  before `apk del`, and the action now reports a failure instead of a false
  success when package removal does not complete.
- Documented the deliberate safety boundary for dependency removal: DNS
  packages, generic shared tools and ACME remain installed to avoid disrupting
  router DNS/DHCP or unrelated services.

## 1.0.4 - 2026-07-12

- Fixed an intentionally empty managed DNS fallback being replaced in LuCI by
  the dnsproxy package default, which could break DNS validation and Reliable
  mode domain routing.
- Added client-side DNS endpoint validation and preserved the exact backend
  failure reason instead of reporting every failure as a completed rollback.
- Replaced the ambiguous Reliable mode warning with the failed runtime
  invariant: service, dnsmasq hand-off/cache, nftables table or policy rule.
- Wait for the router resolver after PBR/community refresh before releasing the
  global action lock, preventing a successful action from briefly returning
  while DNS still refuses connections.
- Verified guarded removal cleanup in the generated APK metadata.

## 1.0.3 - 2026-07-12

- Fixed OpenWrt 25.12 dependency installation rejecting official fetched
  dnsmasq packages as untrusted; apk now switches providers by trusted feed
  name and rolls back through the apk solver.
- Updated installed-version queries for apk-tools 3 and corrected the dnsmasq
  nftset capability check so `no-nftset` is not accepted.
- Preserved the previously installed dnsmasq provider during rollback and
  removed leftover apk/opkg conffile templates after configuration restore.
- Fixed APK removal cleanup: OpenWrt apk runs `pre-deinstall` without the opkg
  `remove` argument, while upgrades are now explicitly skipped through
  `PKG_UPGRADE` so live routing is not torn down.

## 1.0.2 - 2026-07-12

- Added a signed OpenWrt 25.12 APK feed backed by GitHub Release assets.
- Added a one-time bootstrap installer that verifies the project release key,
  registers the feed, simulates the transaction and rolls key/feed changes back
  when installation fails.
- Added release-key/SDK identity checks and CI release assembly for signed APKs
  and `packages.adb` indexes.

## 1.0.1 - 2026-07-07

- Released version `1.0.1`.
- Reworked the outbound DNS editor around addable primary, bootstrap and
  fallback resolver rows, provider presets and native dnsproxy upstream modes.
- Added remove-time cleanup for generated runtime state. Explicit package
  removal now disables managed mode and removes rendered strongSwan profiles
  before files are deleted, while upgrades keep live routing untouched.
- Aligned the SDK Makefile preinstall checks with the canonical IPK preinstall
  guard, including required base commands and persistent-storage preflight.
- Added Mullvad and Yandex resolver presets and allowed fallback resolvers to
  use a transport different from the primary group.
- Added a Russian primary README and retained the English documentation as a
  separate language version.
- Fixed fresh Windows IKEv2 clients rejecting valid credentials when the ACME
  certificate used a new intermediate CA. The server now loads and sends the
  complete certificate chain instead of only the leaf certificate.
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
