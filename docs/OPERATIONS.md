# Operations

## CLI installation and upgrade

The preferred installation path is LuCI package upload. For CLI installation
with dependency preparation:

```sh
scp -O dist/luci-app-ikev2-manager_*_all.ipk root@router:/tmp/
scp -O scripts/install.sh root@router:/tmp/
ssh root@router
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

Upgrade an existing public package with:

```sh
opkg install /tmp/luci-app-ikev2-manager_*_all.ipk
```

Configuration, users, custom destinations, cached service lists and
certificates are preserved.

### OpenWrt 25.12 signed feed

The supported first-install path for OpenWrt 25.12 is:

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-manager-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

This installs the project public key and signed feed before adding the package.
It requires working HTTPS access to GitHub Releases and the official OpenWrt
feeds. It does not enable VPN, PBR, DNS replacement or firewall rules.

Subsequent updates use:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

## Diagnostics

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
/usr/libexec/ikev2-manager-system failclosed-check
/usr/libexec/ikev2-domain-router status
/etc/init.d/pbr status
swanctl --list-sas
```

Healthy outbound routing has:

- an installed `proxy4` CHILD_SA;
- the assigned virtual IPv4 on `ipsec-out`;
- a tunnel default and unreachable fallback in `pbr_ikev2out`;
- PBR, FakeIP and health services running.

The health watcher performs a small data-plane probe through `ipsec-out`. Two
failed probe cycles trigger the serialized reconnect action. The reconnect
cooldown is configurable under the outbound tunnel settings.

## Destination updates

```sh
/usr/libexec/ikev2-domains-community apply
/usr/libexec/ikev2-domain-router status
```

Selected services, custom domains and custom IPv4/CIDR entries are rebuilt
atomically. Existing matching conntrack sessions are removed after a successful
update so they cannot retain an older WAN route.

Clients must use router DNS for domain routing. Custom IPv4/CIDR entries and
direct-service networks do not depend on DNS.

## Background actions

Long LuCI operations continue in serialized workers:

```sh
/usr/libexec/ikev2-manager action-status
/usr/libexec/ikev2-manager-system action-status
```

Logs:

```text
/tmp/ikev2-manager-action.log
/tmp/ikev2-system-action.log
/tmp/ikev2-domains-community.log
/tmp/ikev2-domains-pbr-restart.log
```

A browser timeout does not cancel the router-side operation.

## Certificates

Inspect the active inbound certificate:

```sh
openssl x509 -in /etc/swanctl/x509/ikev2.pem \
  -noout -subject -issuer -dates -fingerprint -sha256
```

The ACME hotplug hook reloads renewed credentials automatically. Certificate
identity must match the public DNS name used by clients.

## Backup and recovery

```sh
sysupgrade -b /tmp/ikev2-manager-backup.tar.gz
gzip -t /tmp/ikev2-manager-backup.tar.gz
```

Backups contain reversible VPN credentials and private keys. Store them as
secrets and never attach them to public issues.

Recovery sequence:

1. disable managed mode in Overview;
2. confirm ordinary WAN access;
3. run the dependency doctor;
4. re-enable managed mode and the outbound client;
5. verify one selected and one ordinary destination;
6. enable the inbound server only after certificate validation.

Removing the package disables managed mode first and removes generated runtime
state, including rendered strongSwan profiles and copied certificate material.
Package-owned files are removed by the active package manager. User
configuration, credentials, source certificates, custom destination lists, cached service lists and
sysupgrade backups are preserved. If managed mode is still enabled and cleanup
cannot run, package removal stops before files are changed.

OpenWrt 24.10:

```sh
opkg remove luci-app-ikev2-manager
```

OpenWrt 25.12:

```sh
apk del luci-app-ikev2-manager
```
