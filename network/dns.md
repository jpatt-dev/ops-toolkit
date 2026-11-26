# DNS troubleshooting with dig and nslookup

Read-only throughout. `dig` is in the `bind-utils` package on RHEL. On Windows, use `Resolve-DnsName` (preferred) or `nslookup`.

## Resolver path

Applications do not ask DNS directly. They ask the operating system resolver:

- **Linux:** `/etc/nsswitch.conf` decides the order (`files` = `/etc/hosts`, `dns`, `sss`, `myhostname`). `/etc/resolv.conf` lists nameservers and search domains.
- **Windows:** hosts file, then the DNS client cache, then the configured DNS servers, with suffix search lists and LLMNR/NetBIOS fallbacks.

`dig` and `nslookup` bypass the hosts file and the search order logic. Use `getent hosts` (Linux) or `Resolve-DnsName` without `-DnsOnly` (Windows) to see what applications see.

## dig essentials

```bash
dig host01.example.com                     # A record with full output
dig host01.example.com +short              # just the answer
dig host01.example.com AAAA +short         # IPv6
dig @192.0.2.53 host01.example.com         # ask a specific server
dig -x 192.0.2.10 +short                   # reverse (PTR) lookup
dig example.com SOA                        # zone authority and serial
dig example.com NS +short                  # authoritative nameservers
dig app.example.com CNAME +short
dig _ldap._tcp.dc._msdcs.example.com SRV   # AD domain controllers
dig _kerberos._tcp.example.com SRV         # Kerberos KDCs
dig example.com TXT +short
dig host01.example.com +trace              # follow delegation from the root (needs outbound DNS to the internet)
dig host01.example.com +norecurse @<authoritative-server>   # what the authority itself says
dig host01.example.com +tcp                # force TCP; tests whether TCP 53 is allowed
```

### Reading the header

```text
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
```

| Status | Meaning |
| --- | --- |
| `NOERROR` with answers | Name exists and resolved |
| `NOERROR` with `ANSWER: 0` | Name exists, but has no record of that type (for example, no AAAA) |
| `NXDOMAIN` | Name does not exist in that zone |
| `SERVFAIL` | The resolver could not get an answer: upstream failure, DNSSEC validation failure, or broken delegation |
| `REFUSED` | The server will not answer you: recursion not allowed for your address, or not authoritative |
| `connection timed out; no servers could be reached` | Network to the DNS server, or the server is down |

| Flag | Meaning |
| --- | --- |
| `aa` | Authoritative answer |
| `rd` | Recursion desired (set by the client) |
| `ra` | Recursion available (the server will recurse) |
| `tc` | Truncated; the client should retry over TCP |

The number after the name in the answer section is the TTL in seconds. A resolver keeps that answer for up to that long. A recently changed record can be stale until the TTL expires.

## nslookup and Resolve-DnsName

```text
nslookup host01.example.com
nslookup host01.example.com 192.0.2.53
nslookup -type=SRV _ldap._tcp.dc._msdcs.example.com
```

`Non-authoritative answer` from `nslookup` is normal: the answer came from a recursive resolver's cache.

```powershell
Resolve-DnsName host01.example.com
Resolve-DnsName host01.example.com -Server 192.0.2.53 -DnsOnly -NoHostsFile
Resolve-DnsName 192.0.2.10 -Type PTR
```

## Failure patterns

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Short name fails, FQDN works | Search domain missing | `search` line in `/etc/resolv.conf`; Windows suffix search list |
| FQDN works with `dig`, fails in the application | `/etc/hosts` entry, nsswitch order, or application-level DNS cache (Java) | `getent hosts`; hosts file |
| Different answers from different servers | Split-horizon DNS, replication delay, or a stale secondary | `dig @each-server`; compare SOA serials |
| Works on one host, fails on another | Different resolvers or search domains | Compare `resolv.conf` or `Get-DnsClientServerAddress` |
| Old address returned after a change | TTL cache on resolvers or clients | TTL in the answer; flush the client cache (`CHANGE`) |
| Intermittent failures | One of several nameservers is down or slow | `dig @each-server` and timing (`Query time:`) |
| `SERVFAIL` for one zone | Broken delegation or DNSSEC | `dig +trace`; `dig +cd` (checking disabled) succeeding points to DNSSEC |
| Reverse lookup fails | No PTR record | `dig -x`. Some services (SSH `UseDNS`, Kerberos, SMTP) are slow or fail without PTR. |
| Kerberos fails, NTLM works | SRV records for `_kerberos` not resolvable, or the name used is a CNAME without an SPN | `dig SRV`; see [windows/ad-auth-certificates.md](../windows/ad-auth-certificates.md#kerberos) |
| Container or EE resolves differently than the host | Container has its own `resolv.conf` | `podman exec <c> cat /etc/resolv.conf` |

## DNS resolves but the connection fails

DNS succeeded; the problem is later. Confirm the address is the one you expect, then go to [workflows.md](workflows.md#dns-resolves-but-the-connection-fails).

## Cautions

- `dig +trace` sends queries to root and TLD servers. It may be blocked in restricted networks and is not needed for internal zones.
- Do not paste internal zone contents or record names into public tickets.
- Flushing caches (`ipconfig /flushdns`, restarting `nscd` or `sssd`) is a `CHANGE` with brief impact.
