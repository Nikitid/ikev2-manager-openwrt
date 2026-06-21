# Validation status

## Release gate

Every release must pass:

- shell, JavaScript, JSON and Python syntax checks;
- version and package metadata consistency;
- public-tree secret/artifact scan;
- deterministic IPK build and checksum generation;
- fresh-install and upgrade checks on a supported OpenWrt target;
- dependency doctor with `doctor_ok=1`;
- outbound reconnect, inbound reload and fail-closed data-plane checks;
- firewall forwarding and PBR health checks after every disruptive operation.

## Current validated environment

- official OpenWrt 24.10.7;
- GL.iNet GL-MT6000 (Flint 2);
- MediaTek Filogic / aarch64_cortex-a53 / Linux 6.6.141;
- firewall4/nftables;
- PBR 1.2.2-r14;
- strongSwan 5.9.14;
- `kmod-xfrm-interface` matching the running kernel.

Validation on one target does not imply support for every router. New targets
should be added only after the same release gate passes and the result is
recorded without private router data.

## 1.0.0-r5 evidence

- reproduced boot ordering with strongSwan starting before WAN;
- automatic recovery helper re-established a deliberately terminated outbound
  SA and recovered a boot-time DNS race without manual input;
- health watcher fallback independently re-established the SA;
- PBR domain rebuild preserved the fail-closed route and refreshed matching
  conntrack sessions;
- learned domain-IP entries survived an orderly reboot and were restored before
  clients repeated their DNS lookups;
- outbound VIP, PBR service, managed DNS and health watcher remained healthy.

## 1.0.0-r4 evidence

- public compatibility preflight: pass;
- complete `opkg --noaction` dependency plan: pass;
- migration from the pre-public `luci-app-ikev2-pbr` package: pass;
- UCI configuration and all three domain-selection files preserved byte-for-byte;
- old package and helper removed; new package, helper and LuCI paths installed;
- outbound SA, virtual IPv4, PBR service and fw4 forwarding remained healthy;
- inbound certificate and connection remained loaded;
- native fail-closed route self-test: pass;
- managed Cloudflare DoH lookup: pass;
- two simultaneous established IKEv2 SAs after upgrade: pass;
- deterministic package build: pass.
