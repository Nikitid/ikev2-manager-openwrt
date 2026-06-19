# Deployment

## Supported platform

- OpenWrt 24.10.x;
- firewall4/nftables;
- PBR 1.2.x;
- IPv4 LAN and WAN connectivity;
- a supported `kmod-xfrm-interface` for the running kernel.

The release IPK is intentionally a bootstrap package. It installs LuCI pages,
helper scripts and inactive defaults. Runtime packages are installed later by
the setup flow or by the optional CLI installer, so uploading the IPK in LuCI
does not replace DNS, start strongSwan or enable PBR.

## Safe installation

Install the release IPK from LuCI:

```text
System -> Software -> Upload Package
luci-app-ikev2-manager_1.0.0-r4_all.ipk
```

For CLI installation with dependency preparation:

```sh
scp -O dist/luci-app-ikev2-manager_*_all.ipk root@router:/tmp/
scp -O scripts/install.sh root@router:/tmp/
ssh root@router
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

No VPN or routing configuration is applied during package installation.
The init scripts remain disabled while
`ikev2-manager.globals.configured=0`. Overview enables them only after an
administrator explicitly activates the managed configuration.

For an existing manual deployment, installation and migration are separate
steps. The Overview page reports **Legacy configuration** while the live
`vpnin`/`vpnout` firewall zones and the earlier PBR policy remain authoritative.
After a backup, run:

```sh
/usr/libexec/ikev2-manager-system adopt-legacy
```

This preserves the public zone names, removes duplicate legacy sections,
creates the application-owned `ikev2pbr_*` firewall/PBR sections and rolls back
if firewall4 or PBR setup fails.

## Overview

Open **Services -> IKEv2 Manager for OpenWrt -> Overview**.

- **WAN network**: logical OpenWrt network, normally `wan`.
- **WAN firewall zone**: normally `wan`.
- **Protected networks**: logical networks whose selected domains use IKEv2.
- **Protected zones**: matching firewall zones used for forwarding and DNS.

Use **Install runtime dependencies** on Overview when the readiness check
reports missing packages. When managed configuration is enabled, the
application runs its dependency doctor, creates its owned UCI sections and
reloads firewall/PBR.

## Outbound gateway requirements

The remote gateway must:

- accept IKEv2 EAP-MSCHAPv2;
- authenticate with an X.509 certificate;
- issue an IPv4 virtual IP;
- accept `0.0.0.0/0` as the remote traffic selector;
- support AES-256-GCM, PRF-SHA384 and ECP384.

Configure the endpoint, certificate identity, EAP username and password on
the **Outbound Tunnel** page.

## Inbound certificate

Install and configure OpenWrt ACME under **Services -> ACME**, or copy an
existing certificate and key to the router.

By default the server expects:

```text
/etc/ssl/acme/<identity>.fullchain.crt
/etc/ssl/acme/<identity>.key
```

Custom paths can be entered under **Inbound Server -> Certificate paths**.
Only enable the server after both files exist.

## Inbound client access

Configure these independently under **Inbound Server -> Client routes and
access**:

- **Advertised IPv4 destinations**: space-separated traffic selectors.
  `0.0.0.0/0` requests a full-tunnel route on compatible clients.
- **Allow Internet**: home WAN and the outbound IKEv2 policy path.
- **Allow internal networks**: only the listed OpenWrt firewall zones.
- **Allow router itself**: services running on router addresses.
- **Allowed router ports**: optional TCP/UDP port numbers or ranges. Empty
  means all router services.

Router access covers LAN, VPN and public addresses owned by the router. A
router-hosted service such as `192.168.1.1:1443` is therefore reachable both
through its LAN address and the router's public address when this permission
is enabled.

The firewall zone names are available under the advanced zone integration
section. Defaults are `ikev2in` and `ikev2out`; existing installations can
retain legacy names such as `vpnin` and `vpnout`.

## Advanced strongSwan profiles

The **Edit raw config** button shows the currently generated inbound or
outbound `swanctl` profile. Saving it enables custom mode for that profile.
Use **Reset to generated** to return control to the form fields.

Custom mode is intended for strongSwan operators. Keep credentials in the
normal application fields and avoid embedding private keys or passwords in
the raw connection block.

## Upgrade

```sh
opkg install /tmp/luci-app-ikev2-manager_*_all.ipk
```

UCI configuration, users, client secret, domains and certificates are
preserved. Revisit Overview after upgrades that introduce a new schema.

### Migrating the pre-public package name

If `luci-app-ikev2-pbr` is installed, do not upload the new package directly:
both packages contain the same runtime files. Use the release installer, which
creates a backup, removes the legacy package without disabling managed runtime,
installs `luci-app-ikev2-manager` and then runs the compatibility/dependency
checks:

```sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_1.0.0-r4_all.ipk
```

Take an additional backup first when migrating manually:

```sh
sysupgrade -b /tmp/ikev2-manager-pre-upgrade.tar.gz
```

## Removal

Disable managed configuration on **Overview** first. This removes managed runtime sections while
preserving settings for a future reinstall.

```sh
opkg remove luci-app-ikev2-manager
```
