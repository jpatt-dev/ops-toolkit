# Network troubleshooting workflows

Step-by-step paths for the failures seen most often. Each starts with the cheapest read-only check. Run every check from the host that makes the real connection (an AAP execution node or EE, a Windows service host, a container), not your workstation.

Fast path on Linux: [check-endpoint.sh](check-endpoint.sh) runs steps 1 to 4 of the first workflow.

## Server cannot reach an API endpoint

```text
DNS ──► TCP ──► TLS ──► HTTP status ──► response body
 │       │       │          │
 NXDOMAIN refused  untrusted  401/403/4xx/5xx
 wrong IP timeout  mismatch
```

1. **Resolve the name.**
   `getent hosts api.example.com` or `Resolve-DnsName api.example.com`.
   Fails: [dns.md](dns.md). Resolves to an unexpected address: check split DNS and `/etc/hosts`.
2. **Check for a proxy.**
   `env | grep -i _proxy`, `netsh winhttp show proxy`. If the host must use a proxy, every later test goes through it.
3. **Connect TCP.**
   `timeout 5 bash -c '</dev/tcp/api.example.com/443'` or `Test-NetConnection api.example.com -Port 443`.
   Refused or timeout: see [refused versus timeout](#connection-refused-versus-timeout).
4. **Handshake TLS.**
   `openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null`.
   Fails: see [TLS handshake fails](#tls-handshake-fails).
5. **Send the request.**
   `curl -sS -o /dev/null -w '%{http_code}\n' https://api.example.com/health`.
   An HTTP status means the network works. Go to [api/http-error-troubleshooting.md](../api/http-error-troubleshooting.md).
6. **Compare with a host that works.** Same name, same port, same time. Differences in DNS answer, route (`ip route get`), proxy, or source address explain most cases.

## DNS resolves but the connection fails

The name is fine; the address or the path is not.

1. Confirm the address is correct. Compare `dig +short` from this host with the expected address. A stale record or wrong view gives a reachable-looking but wrong IP.
2. IPv6 first? `getent ahosts` lists AAAA records. A client that prefers IPv6 can fail where IPv4 works. Test with `curl -4` and `curl -6`.
3. Which route and source address? `ip route get <ip>` or `Find-NetRoute -RemoteIPAddress <ip>`. A VPN or second interface may take the traffic.
4. Test TCP to the IP directly: `timeout 5 bash -c '</dev/tcp/<ip>/443'`. Same result as the name means the issue is the path, not DNS.
5. Refused or timeout? Follow the next workflow.
6. Behind a load balancer? Test each backend with `curl --resolve`. See [lb-proxy-vpn.md](lb-proxy-vpn.md#load-balancers).

## Connection refused versus timeout

| | Refused | Timeout |
| --- | --- | --- |
| How fast | Immediately | After the client's timeout (seconds) |
| What came back | TCP RST (or ICMP reject) | Nothing |
| Network path | Works to the host or to a rejecting firewall | Unknown: dropped somewhere |
| Typical cause | Service down, wrong port, listening on `127.0.0.1` only, firewall `REJECT` | Firewall `DROP`, wrong address, host down, routing, missing return route |
| Where to look | The server | The path between client and server |

### Refused workflow

1. On the server: `ss -ltnp | grep :<port>` or `Get-NetTCPConnection -State Listen -LocalPort <port>`.
2. Not listening: start or fix the service. See [linux/systemd-journal.md](../linux/systemd-journal.md) or [windows/powershell-services-events.md](../windows/powershell-services-events.md#services).
3. Listening on `127.0.0.1` only: change the bind address.
4. Listening on all addresses: a host firewall reject rule. `firewall-cmd --list-all`, or Windows firewall rules.
5. Through a load balancer: the LB may refuse when no backend is healthy.

### Timeout workflow

1. Is the address right and the host up? Check from a host on the same network as the server.
2. Host firewall: is the port allowed in the active zone or profile?
3. Capture on the server while the client retries: `tcpdump -i any -nn port <port> and host <client-ip>`.
   - No SYN arrives: blocked or misrouted before the server. Network firewall, security group, or routing.
   - SYN arrives, no SYN-ACK leaves: host firewall or the service backlog.
   - SYN-ACK leaves, client never sees it: return path or asymmetric routing.
4. `traceroute -T -p <port>` from the client to see where packets stop.
5. Request a firewall rule with source, destination, port, and protocol.

## TLS handshake fails

1. Confirm TCP connects first. A TLS error after a TCP timeout is a network problem.
2. Run `openssl s_client -connect host:443 -servername host -showcerts </dev/null`.
3. Read `Verify return code`. Look it up in [tls-openssl.md](tls-openssl.md#verify-return-codes).
4. Common results and fixes:

   | Result | Fix |
   | --- | --- |
   | 20 or 21 and only one certificate in the chain | Server must send its intermediate |
   | 19 or 20 with an internal or proxy CA as the issuer | Add that CA to the client trust store, or the EE |
   | 10 | Renew the certificate; check client time |
   | Name mismatch | Use a name in the SAN, or reissue the certificate |
   | `handshake failure` alert | Protocol, cipher, or client-certificate requirement; try `-tls1_2` and `-tls1_3` |
   | `wrong version number` | Not TLS on that port |
   | Hangs after `CONNECTED` | MTU; see [performance-packet-capture.md](performance-packet-capture.md#mtu-problems) |

5. Works in `curl`, fails in the application: the application uses a different trust store (Python `certifi`, Java `cacerts`, container image). Fix that store.
6. Never set verification off as the resolution.

## Authentication failure versus connectivity failure

Decide which one you have before changing credentials or firewall rules.

| Evidence | Connectivity | Authentication | Authorization |
| --- | --- | --- | --- |
| DNS error, refused, timeout, reset, TLS error | Yes | | |
| HTTP status returned at all | No: the network works | | |
| HTTP 401, WinRM "credentials were rejected", SSH "Permission denied (publickey)" | | Yes | |
| HTTP 407 | Proxy wants credentials | (proxy) | |
| HTTP 403, "Access is denied" after logon, ServiceNow ACL denial | | | Yes |
| Server log shows a failed logon (Linux `/var/log/secure`, Windows 4625) | | Yes | |
| Server log shows a successful logon, then denial | | | Yes |

Rules of thumb:

- If you got an HTTP response, stop testing the firewall.
- A 401 says "who are you?" A 403 says "I know who you are, and no."
- Changing the password will not fix a 403 or a timeout.
- Opening a firewall rule will not fix a 401.

For API status codes in detail, see [api/http-error-troubleshooting.md](../api/http-error-troubleshooting.md). For WinRM and SSH authentication, see [ansible/connectivity-ssh-winrm.md](../ansible/connectivity-ssh-winrm.md).

## Works from one host but not another

Compare these between the working and failing hosts, in this order:

1. DNS answer: `dig +short <name>` or `Resolve-DnsName`.
2. Proxy settings.
3. Route and source address: `ip route get`, `Find-NetRoute`.
4. Firewall rules that reference the source address or subnet.
5. Trust store contents for the issuing CA.
6. Clock: `chronyc tracking`, `w32tm /query /status`.
7. Client software versions (OpenSSL, curl, Python, PowerShell).
