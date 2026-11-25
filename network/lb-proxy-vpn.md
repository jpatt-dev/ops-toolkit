# Load balancers, HAProxy, proxies, and VPNs

Read-only unless marked `CHANGE` or `RESTART`.

## Load balancers

A load balancer (LB) adds a hop that can fail on its own. Identify which side failed:

| Client sees | Usually means |
| --- | --- |
| Timeout to the VIP | VIP not listening, firewall, or the LB has no route to the client |
| `503 Service Unavailable` from the LB | No healthy backend in the pool |
| `502 Bad Gateway` | Backend sent an invalid response, closed the connection, or TLS to the backend failed |
| `504 Gateway Timeout` | Backend did not answer within the LB timeout |
| Intermittent failures | One unhealthy backend still in rotation, or uneven health checks |
| Login loops or lost sessions | Session persistence (stickiness) missing for a stateful app |
| Wrong certificate | LB serves a different certificate than the backend; check SNI configuration |

Isolate the LB by calling a backend directly with the same name:

```bash
curl -v --resolve app.example.com:443:192.0.2.21 https://app.example.com/health   # backend 1
curl -v --resolve app.example.com:443:192.0.2.22 https://app.example.com/health   # backend 2
curl -v https://app.example.com/health                                           # through the VIP
```

If every backend works directly and the VIP fails, the problem is the LB: health checks, pool membership, timeouts, or TLS settings. If one backend fails, take it out of the pool and fix it.

Source address: backends see the LB address unless the LB preserves the client address (transparent mode) or adds `X-Forwarded-For` or the PROXY protocol. Backend allow-lists and logs must account for that.

## HAProxy

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg        # configuration check; run before every reload
systemctl status haproxy
journalctl -u haproxy --since '15 min ago'
ss -ltnp | grep haproxy                       # bound frontends
```

Runtime state through the stats socket. The path comes from the `stats socket` line in the `global` section:

```bash
grep -E '^\s*stats socket' /etc/haproxy/haproxy.cfg
echo 'show info' | socat stdio /run/haproxy/admin.sock
echo 'show stat' | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18,19,37 | column -s, -t   # proxy, server, status, weight, check status
echo 'show servers state' | socat stdio /run/haproxy/admin.sock
```

```bash
echo 'disable server be_app/app01' | socat stdio /run/haproxy/admin.sock   # CHANGE: needs an admin-level socket
echo 'enable server be_app/app01'  | socat stdio /run/haproxy/admin.sock   # CHANGE
systemctl reload haproxy                                                   # RESTART: graceful reload after config change
```

### HAProxy log termination state

HTTP log lines include a two-character termination state, such as `----` (normal) or `sC--`. The first character says who ended the session; the second says at which stage.

| First char | Meaning |
| --- | --- |
| `C` | Client aborted |
| `S` | Server aborted or refused |
| `P` | Proxy (HAProxy) aborted, for example by a deny rule |
| `R` | Resource exhausted |
| `I` | Internal error |
| `D` | Server marked down |
| `c` | Client-side timeout |
| `s` | Server-side timeout |
| `-` | Normal completion |

| Second char | Stage |
| --- | --- |
| `R` | Waiting for the client request |
| `Q` | Waiting in the queue for a server slot |
| `C` | Connecting to the server |
| `H` | Waiting for server response headers |
| `D` | Data transfer |
| `L` | Last data sent |
| `-` | Normal |

Examples: `sC` = timeout connecting to the backend; `SC` = backend refused the connection; `sH` = backend accepted but did not send headers in time (slow application); `cD` = client went idle during transfer.

On RHEL with SELinux, HAProxy connecting to backends on non-standard ports needs `haproxy_connect_any` or the port labeled. See [linux/selinux.md](../linux/selinux.md#booleans).

## Proxies

### Environment variables

| Variable | Used by | Notes |
| --- | --- | --- |
| `https_proxy` / `HTTPS_PROXY` | curl, Python requests, many CLIs | Proxy for HTTPS URLs |
| `http_proxy` | curl, Python requests | curl ignores uppercase `HTTP_PROXY` for security reasons |
| `no_proxy` / `NO_PROXY` | Most clients | Comma-separated hosts or domains to reach directly. Wildcard and CIDR support varies by tool. |

```bash
env | grep -i _proxy
curl -v https://api.example.com/ 2>&1 | grep -i proxy     # shows when curl picks up a proxy
```

Common mistakes:

- Internal names missing from `no_proxy`, so internal traffic goes to an internet proxy and fails.
- `no_proxy=.example.com` matches subdomains but some tools do not match `example.com` itself. List both.
- A proxy set for your shell is not set for systemd services, cron, containers, or AAP jobs. Set it where the process runs.

### Proxy responses

| Response | Meaning |
| --- | --- |
| `407 Proxy Authentication Required` | The proxy wants credentials. Not the target API's 401. |
| `403` with proxy branding in the body | Proxy policy denied the URL or category |
| `CONNECT` to `host:443` fails | Proxy does not allow tunneling to that destination or port |
| Certificate issued by an internal "proxy CA" | TLS inspection; see [tls-openssl.md](tls-openssl.md#tls-inspecting-proxies) |
| `502` or `504` from the proxy | Proxy could not reach the target |

### Windows

Windows has separate WinHTTP, user, and PowerShell 7 proxy settings. See [windows/networking-firewall.md](../windows/networking-firewall.md#proxies).

## VPN troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Tunnel up, nothing passes | Routes not installed, or the remote side lacks a return route | `ip route get <remote-ip>`; `Find-NetRoute` |
| Some subnets work | Split-tunnel route list incomplete, or the remote side's encryption domain or policy excludes the subnet | Compare both sides' configured networks |
| Names do not resolve over VPN | VPN DNS servers or search domains not applied | `/etc/resolv.conf`; `Get-DnsClientServerAddress` |
| Small requests work, large ones hang | MTU and MSS: tunnel overhead plus blocked ICMP | `ping -M do -s <size>`; MSS clamping on the tunnel |
| Local network unreachable while connected | Full tunnel, or the remote network overlaps a local range | Address plans on both sides |
| Drops after a fixed time | Rekey or idle timeout mismatch between peers | Logs on both ends at the drop time |

Linux IPsec (Libreswan) and WireGuard state:

```bash
ipsec status                 # Libreswan connections
ipsec trafficstatus          # bytes in and out per tunnel
ip xfrm state                # kernel IPsec security associations
ip xfrm policy               # which traffic is selected for IPsec
wg show                      # WireGuard peers, last handshake, transfer
```

`wg show` with no recent `latest handshake` means the peers are not talking: keys, endpoint, or UDP port blocked.

## Cautions

- Disabling a pool member, reloading HAProxy, or changing proxy settings affects live traffic. Schedule it.
- The HAProxy admin socket can change running state. Restrict who can use it.
- Do not put proxy credentials in `http_proxy` URLs in shared scripts or this repository.
