# Network

Practical network troubleshooting: DNS, TCP, routing, firewalls, TLS, load balancers, proxies, VPNs, performance, and packet captures. Start with the [cheat sheet](cheatsheet.md) or the [workflows](workflows.md).

| File | Covers |
| --- | --- |
| [cheatsheet.md](cheatsheet.md) | Layer-by-layer checks, symptom lookup, curl, OpenSSL, DNS, path, proxy quick reference |
| [workflows.md](workflows.md) | Server cannot reach an API; DNS resolves but connection fails; refused vs timeout; TLS handshake fails; authentication vs connectivity; works from one host only |
| [check-endpoint.sh](check-endpoint.sh) | Read-only script that checks DNS, TCP, TLS, and HTTP for one endpoint and names the failing layer |
| [fundamentals.md](fundamentals.md) | Layers, IPv4 ranges, TCP vs UDP, ports and protocols, routing, firewalls, MTU |
| [dns.md](dns.md) | Resolver path, `dig`, `nslookup`, `Resolve-DnsName`, response codes, failure patterns |
| [connectivity-testing.md](connectivity-testing.md) | TCP tests, testing from the right place, `curl` options and timings, traceroute and mtr |
| [tls-openssl.md](tls-openssl.md) | `openssl s_client`, verify return codes, certificate files and formats, handshake failures, TLS-inspecting proxies |
| [lb-proxy-vpn.md](lb-proxy-vpn.md) | Load balancers, HAProxy runtime and log codes, proxy variables and responses, VPN symptoms |
| [performance-packet-capture.md](performance-packet-capture.md) | Latency, loss, throughput, MTU, `tcpdump`, `tshark`, Windows `pktmon` |

Host-specific detail lives elsewhere: [linux/networking-dns-firewalld.md](../linux/networking-dns-firewalld.md), [windows/networking-firewall.md](../windows/networking-firewall.md). The REST API diagnostic in [api/](../api/README.md) classifies DNS, connection, and TLS failures for a single HTTPS request from PowerShell.

## Using check-endpoint.sh

```bash
./network/check-endpoint.sh api.example.com                 # HTTPS on 443
./network/check-endpoint.sh -p /api/health api.example.com 8443
./network/check-endpoint.sh -c /path/to/internal-ca.pem api.example.com
./network/check-endpoint.sh --plain intranet.example.com 80
```

It sends one unauthenticated GET and never disables certificate verification. Exit codes identify the failing layer: `1` DNS, `2` TCP, `3` TLS, `4` HTTP request did not complete, `6` HTTP 4xx or 5xx status. `5` means a required tool is missing and nothing was checked. Exit `0` only when every requested step passed. Requirements: `bash`, `getent`, `timeout`, `openssl`, and `curl`, all present on a default RHEL install.

## Conventions

- Commands are read-only unless marked `CHANGE`.
- Examples use `example.com` names and documentation address ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- Do not commit packet captures, real addresses, or customer hostnames. `.gitignore` excludes `*.pcap`, `*.pcapng`, and `*.har`.
