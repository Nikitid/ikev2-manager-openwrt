# Shared OpenWrt 25.12 APK feed

The `apk-feed` branch is the stable feed for Nikitid OpenWrt applications. This
repository is its single writer. Application repositories publish signed APK
release assets; they do not replace the central index independently.

The feed currently contains:

- `luci-app-ikev2-manager`;
- `luci-app-overview-manager`.

Every refresh verifies both APK signatures before rebuilding the signed
`packages.adb`, then verifies the two packages and the resulting index again.
Updating one application must retain the current signed APK for the other.

## Trust identity

The existing P-256 publisher key remains unchanged:

```text
SHA-256: f27474d9261f1084350cf4ba34ecdff29e533769c36483d8dd85566e30a6a703
```

The feed publishes byte-identical public-key files:

- `ikev2-manager-release.pem` for existing installations;
- `nikitid-openwrt-release.pem` as the shared alias.

The private key is available only to release automation through the protected
`OPENWRT_APK_SIGNING_KEY` secret.

## Publishing

An IKEv2 Manager stable tag builds its signed APK, downloads the latest signed
Overview Manager APK, and publishes both through the release workflow.

An Overview Manager release can request a feed-only refresh through the
`overview-manager-release` repository-dispatch event or a manual run of the
`Shared APK feed` workflow. The refresh downloads the selected releases and
does not rebuild either application.

Use `scripts/assemble-shared-apk-feed.sh` for local or CI assembly. It requires
the exact OpenWrt SDK, the matching private key, and paths to both already
signed APKs. `scripts/verify-shared-apk-feed.sh` verifies a completed feed.

## Compatibility

Existing `/etc/apk/repositories.d/ikev2-manager.list` entries continue to use
the same `apk-feed` URL. `scripts/install-openwrt25.sh` and the legacy public
key filename remain supported. Updating IKEv2 Manager stays scoped:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

No system-wide `apk upgrade` is required or performed.
