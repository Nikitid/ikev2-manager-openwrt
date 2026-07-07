# Contributing

IKEv2 Manager for OpenWrt changes routing, firewall and VPN state on embedded
devices. Compatibility and rollback safety take priority over feature breadth.

## Before opening a pull request

1. Keep installation inactive by default.
2. Do not broaden the supported OpenWrt matrix without hardware or VM evidence.
3. Preserve existing UCI configuration during upgrades.
4. Make runtime changes fail closed and restore the previous state on failure.
5. Never commit router backups, firmware, credentials or unsanitized logs.
6. Run:

```sh
./scripts/ci-check.sh
```

## Pull request evidence

Describe:

- OpenWrt release, target, architecture and kernel;
- fresh install or upgrade path;
- dependency doctor output;
- firewall/PBR/strongSwan checks performed;
- rollback or failure-path testing where relevant.

Use documentation addresses and names only. Sanitize screenshots and logs.

Release tags use `v<version>`, for example `v1.0.1`, and must match
`release.env`.

Before a public release:

```sh
./scripts/ci-check.sh
./scripts/check-release-tag.sh v1.0.1
git status --short
```

Do not commit router backups, firmware, SDK archives, private diagnostics,
credentials or generated files outside the ignored `build/` and `dist/`
directories.
