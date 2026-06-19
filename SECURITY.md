# Security policy

## Supported versions

Only the latest published release is supported with security fixes.

The currently supported router platform is official OpenWrt 24.10.x with
firewall4. Vendor firmware, snapshots and OpenWrt 25.12+ are unsupported until
they are explicitly listed in the compatibility matrix.

## Reporting a vulnerability

Do not open a public issue for a vulnerability, private key, credential,
router backup or diagnostic archive containing secrets.

Use GitHub private vulnerability reporting for this repository. Include:

- the package version;
- OpenWrt release, target and kernel version;
- the smallest reproducible description;
- whether the issue can leak traffic outside the VPN or expose credentials.

Remove passwords, ACME credentials, private keys, public IP addresses and
personally identifying domain names from all attachments.

## Secret-bearing files

Router backups and `/etc/ikev2-manager/` contain reversible VPN credentials.
`/etc/swanctl/private/` contains private keys. Treat both as secrets.

The LuCI interface submits new VPN and ACME credentials through temporary
files with mode `0600`; secrets are removed immediately after the backend reads
them and are never passed as process command-line arguments.
