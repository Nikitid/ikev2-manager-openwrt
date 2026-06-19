# Publishing checklist

## Public source tree

Before every public push:

```sh
./scripts/ci-check.sh
git status --short
git ls-files --others --exclude-standard
```

The repository must not contain router backups, firmware, SDK archives,
diagnostic reports, credentials, private keys or generated IPK artifacts.

Local working artifacts belong only in ignored directories such as
`.local-artifacts/`, `build/` and `dist/`.

## Git history

The public `main` branch starts from a clean root commit containing only the
reviewed source tree. The discarded pre-public development history contained
private network identifiers and must never be reintroduced, pushed as another
branch or restored as a public tag.

Verify the clean publication branch before pushing:

```sh
git log --oneline --decorate
git ls-tree -r --name-only HEAD
./scripts/check-public-tree.sh
```

## Repository settings

Recommended GitHub settings:

- default branch: `main`;
- enable Issues, Discussions and private vulnerability reporting;
- require the `validate` GitHub Actions job before merging;
- enable Dependabot alerts and secret scanning where available;
- automatically delete merged branches;
- publish releases only from tags matching `v<version>-r<release>`.

The intended repository URL is:

```text
https://github.com/nikitid/ikev2-manager-openwrt
```
