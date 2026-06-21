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
- sing-box 1.12.22 with nftables TProxy kernel support.

Validation on one target does not imply support for every router. New targets
should be added only after the same release gate passes and the result is
recorded without private router data.

## Unreleased reliable-domain-routing evidence

- transactional switch from dnsmasq/dnsproxy to dnsmasq/sing-box/dnsproxy;
- selected DNS answers remained stable across sing-box restarts;
- router probes bound to the LAN source address kept control traffic on the
  home WAN while TikTok HTTPS completed through FakeIP and the outbound IKEv2
  address;
- PBR restart refreshed the sing-box rule-set without changing FakeIP mappings;
- managed DNS re-apply kept dnsmasq on the FakeIP resolver;
- health restored a deliberately deleted TProxy table in 14 seconds and
  repaired a missing policy rule plus dnsmasq upstream drift;
- a temporary direct-WAN device exclusion appeared before the covered-LAN
  FakeIP rule and was removed cleanly afterward;
- 12 consecutive TikTok HTTPS requests completed through FakeIP; sing-box used
  about 37 MiB RSS and retained the same FakeIP after a forced process respawn;
- a stale installed CHILD_SA was detected during testing, reconnected without a
  router reboot, and the new data-plane probe reported zero failures;
- an explicit outbound-SA termination blocked selected traffic instead of
  leaking it to WAN, kept ordinary WAN traffic online and recovered the tunnel
  in 5 seconds;
- router reboot validation remains intentionally pending.

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
