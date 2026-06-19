# DNS upstreams

## Resolver chain

IKEv2 Manager keeps `dnsmasq-full` on port 53 for LAN and VPN clients:

```text
client -> dnsmasq-full -> dnsproxy -> public resolver
```

`dnsmasq-full` provides DHCP, local-name resolution, caching integration and
the nftset updates used by PBR. It forwards public queries using ordinary DNS;
encrypted upstream transports are provided by the separate `dnsproxy`
process listening on `127.0.0.1:5453`.

## Supported transports

The Outbound Tunnel page exposes every upstream transport supported by the
packaged `dnsproxy`:

| UI option | dnsproxy endpoint |
|---|---|
| DNS over UDP | `udp://host:53` |
| DNS over TCP | `tcp://host:53` |
| DNS over TLS | `tls://hostname` |
| DNS over HTTPS | `https://hostname/dns-query` |
| DoH with HTTP/3 preferred (experimental) | HTTPS endpoint plus `http3=1` |
| DoH over HTTP/3 only (experimental) | `h3://hostname/dns-query` |
| DNS over QUIC (experimental) | `quic://hostname` |
| DNSCrypt | `sdns://...` stamp |

Provider presets are conveniences, not an exhaustive directory. **Custom**
accepts one or more space-separated endpoints using the selected transport.
The setting is router-wide. Connections from `dnsproxy` to public resolvers
follow the router's normal default route; choosing a DNS transport does not
route all DNS traffic through the IKEv2 tunnel.

Standard DoH is the default because it works reliably over ordinary TCP/TLS.
HTTP/3 and DoQ depend on UDP/QUIC path quality and kernel socket buffers, so
they remain advanced experimental choices.

## Safety model

Managed DNS is opt-in. The first activation stores the previous `dnsproxy` and
`dhcp` UCI exports under `/etc/ikev2-manager/dns-original/`.

For every update the runtime:

1. validates the transport and endpoint syntax;
2. updates only the dnsproxy listener, upstream and cache settings;
3. points the primary dnsmasq instance at `127.0.0.1#5453`;
4. restarts both services;
5. resolves `openwrt.org` through the local dnsmasq instance;
6. restores the immediately previous configuration if validation fails.

Selecting **Keep existing router DNS** restores the original snapshot.

## Upstream references

- [dnsmasq manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [AdGuard dnsproxy](https://github.com/AdguardTeam/dnsproxy)
- [Cloudflare encrypted DNS](https://developers.cloudflare.com/1.1.1.1/encryption/)
- [Google Public DNS secure transports](https://developers.google.com/speed/public-dns/docs/secure-transports)
- [Quad9 services](https://docs.quad9.net/services/)
- [AdGuard public DNS provider directory](https://adguard-dns.io/kb/general/dns-providers/)
