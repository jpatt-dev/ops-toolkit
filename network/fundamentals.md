# TCP/IP, TCP vs UDP, ports, routing, and firewalls

Just enough theory to read troubleshooting output correctly. For commands, see [connectivity-testing.md](connectivity-testing.md) and the [cheat sheet](cheatsheet.md).

## Layers that fail separately

| Layer | Question | Typical tools | Typical failure |
| --- | --- | --- | --- |
| Name resolution | Does the name give the right address? | `dig`, `getent`, `Resolve-DnsName` | NXDOMAIN, wrong or stale address |
| Routing (L3) | Is there a path to that address? | `ip route get`, `traceroute`, `Find-NetRoute` | No route, asymmetric routing |
| Transport (L4) | Does TCP connect, or does UDP get an answer? | `nc`, `/dev/tcp`, `Test-NetConnection` | Refused, timeout, reset |
| TLS | Does the handshake succeed and is the certificate trusted? | `openssl s_client`, `curl -v` | Untrusted CA, name mismatch, protocol mismatch |
| Application | Does the server accept the request? | `curl`, `Invoke-WebRequest` | HTTP 4xx and 5xx |

Work from the top down. A DNS error makes every later test meaningless. An HTTP 401 proves the first four layers work.

## IPv4 addressing reminders

| Item | Example | Note |
| --- | --- | --- |
| CIDR | `192.0.2.0/24` | 256 addresses, 254 usable hosts |
| `/32` | One address | Host routes and single-address firewall rules |
| Private ranges | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | Not routed on the internet |
| Documentation ranges | `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` | Use these in examples |
| Loopback | `127.0.0.0/8` | A service bound here is reachable only locally |
| Link-local | `169.254.0.0/16` | Often means DHCP failed; also used by cloud metadata at 169.254.169.254 |
| Carrier-grade NAT | `100.64.0.0/10` | Shared address space, some VPNs and cloud networks |

Overlapping ranges between a VPN and a local network cause traffic for the remote network to stay local.

## TCP versus UDP

| | TCP | UDP |
| --- | --- | --- |
| Connection | Three-way handshake: SYN, SYN-ACK, ACK | None |
| Reliability | Retransmits, ordered delivery | None built in |
| Closed port response | RST ("connection refused") | ICMP port unreachable, often filtered |
| Filtered port response | Nothing: the client times out | Nothing: indistinguishable from "no answer" |
| Testing | Connect and see if it succeeds | Send a real protocol request and wait for a reply |
| Examples | HTTPS, SSH, WinRM, LDAP, SMB | DNS (mostly), NTP, SNMP, syslog, Kerberos (both) |

Because UDP has no handshake, `nc -u` "succeeding" proves nothing. Test UDP services with their own clients: `dig` for DNS, `chronyc` or `ntpdate -q` for NTP, `snmpget` for SNMP.

### What the client sees

| Client sees | What happened |
| --- | --- |
| Immediate "connection refused" | A RST came back. The host is reachable; nothing listens on that port, or a firewall sends rejects. |
| Long wait, then "timed out" | SYN got no reply. A firewall dropped it, the host is down, or the route is wrong. |
| "No route to host" | ICMP host unreachable from a router or a firewall reject rule, or no local route. |
| "Connection reset by peer" after connecting | The server or a middlebox closed the connection: TLS mismatch, idle timeout, proxy policy, or the application crashed. |
| "Network is unreachable" | No route on the local host. |

See [workflows.md](workflows.md#connection-refused-versus-timeout).

## Ports and protocols

| Port | Protocol | Use |
| --- | --- | --- |
| 22/tcp | SSH | Linux management, Git over SSH |
| 53/udp, 53/tcp | DNS | Queries (TCP for large responses and zone transfers) |
| 80/tcp, 443/tcp | HTTP, HTTPS | Web, REST APIs, AAP, ServiceNow |
| 88/tcp, 88/udp | Kerberos | Windows domain authentication |
| 123/udp | NTP | Time |
| 135/tcp + dynamic | RPC endpoint mapper | Windows remote management tools other than WinRM |
| 389/tcp, 636/tcp | LDAP, LDAPS | Directory |
| 445/tcp | SMB | Windows file shares |
| 514/udp, 6514/tcp | Syslog, syslog over TLS | Logging |
| 3268/tcp, 3269/tcp | Global Catalog, GC over TLS | AD forest-wide lookups |
| 3389/tcp | RDP | Remote desktop |
| 5432/tcp | PostgreSQL | AAP database |
| 5985/tcp, 5986/tcp | WinRM HTTP, HTTPS | Ansible to Windows |
| 8530/tcp, 8531/tcp | WSUS HTTP, HTTPS | Windows updates from WSUS |
| 27199/tcp | Receptor (AAP default) | Automation mesh between nodes |

Defaults can be changed. Confirm with the service's configuration and `ss -ltnp` or `Get-NetTCPConnection -State Listen`.

## Routing

```bash
ip route                    # Linux table
ip route get 192.0.2.10     # chosen route, interface, source address
ip rule                     # policy routing rules, used with multiple tables
```

```powershell
Get-NetRoute -AddressFamily IPv4
Find-NetRoute -RemoteIPAddress 192.0.2.10
```

Routing problems to recognize:

- **Wrong source address.** On multi-homed hosts, replies leave a different interface than requests arrived on. Stateful firewalls drop them.
- **Asymmetric routing.** Traffic goes out one path and returns another. Firewalls that see only half the flow drop it.
- **More specific route wins.** A `/24` route through a VPN beats the default route, which is usually what you want; a stray `/32` can hijack one host.
- **Missing return route.** The request reaches the server, but the server has no route back to the client's network.

`traceroute` and `tracepath` show the forward path only. Run them from both ends when you suspect asymmetry.

## Firewalls and connectivity

| Firewall type | What it filters | How a block looks |
| --- | --- | --- |
| Host firewall (firewalld, Windows Firewall) | Ports and sources on the host | Timeout (drop) or refused/unreachable (reject) |
| Network firewall | Flows between networks, often by zone and application | Usually timeout |
| Cloud security group or ACL | Flows to cloud instances | Timeout |
| Proxy or TLS-inspecting gateway | URLs, categories, TLS | HTTP 403 or 407 from the proxy, reset, or an unexpected certificate |

Stateful firewalls allow return traffic automatically. Request a rule for the direction the connection is **initiated**: client source, server destination, destination port.

When asking for a firewall rule, provide: source address or range, destination address or range, destination port and protocol, and the business reason. Do not include customer data in public tickets.

## MTU

Ethernet MTU is usually 1500 bytes. Tunnels and VPNs reduce it. When path MTU discovery is broken (ICMP "fragmentation needed" blocked), small requests work and large ones hang, often during the TLS handshake when the server sends its certificate chain.

```bash
ping -M do -s 1472 192.0.2.10     # Linux: 1472 + 28 header bytes = 1500; lower until it works
tracepath 192.0.2.10              # reports pmtu along the path
```

```powershell
ping -f -l 1472 192.0.2.10        # Windows: -f sets Don't Fragment
```

See [performance-packet-capture.md](performance-packet-capture.md#mtu-problems).
