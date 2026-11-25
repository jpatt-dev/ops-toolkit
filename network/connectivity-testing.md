# Connectivity testing: curl, nc, traceroute, and PowerShell

All commands here are read-only. They send test traffic; ask first if the target is monitored by an intrusion detection team that will treat scans as an incident.

For a scripted layered check (DNS, TCP, TLS, HTTP), see [check-endpoint.sh](check-endpoint.sh).

## Test TCP reachability

```bash
# Bash built-in; no extra packages. 0 = connected.
timeout 5 bash -c '</dev/tcp/api.example.com/443' && echo open || echo "failed rc=$?"

nc -vz -w 5 api.example.com 443          # nmap-ncat on RHEL: "Connected to" or the error
```

Interpreting `bash /dev/tcp` with `timeout`:

| Result | Meaning |
| --- | --- |
| `open` quickly | TCP handshake completed |
| `Connection refused` quickly | RST received: nothing listening, or a reject rule |
| `rc=124` after 5 s | Timed out: dropped by a firewall, wrong address, or host down |
| `No route to host` | ICMP unreachable or no local route |
| `Name or service not known` | DNS failure; see [dns.md](dns.md) |

```powershell
Test-NetConnection api.example.com -Port 443
Test-NetConnection api.example.com -Port 443 -InformationLevel Detailed   # shows the source address and interface
```

See [windows/networking-firewall.md](../windows/networking-firewall.md#connectivity-tests) for telling refused from timeout in PowerShell.

## Test from the right place

The test must run from the host that will make the real connection:

- An AAP job runs on an **execution node**, inside an EE container. Test from that node, and when proxies or DNS differ, from inside the EE: `podman run --rm <ee> curl -v https://api.example.com/`.
- A Windows service runs as its service account with the WinHTTP proxy, not your interactive proxy.
- A container has its own DNS and may have its own proxy environment.

## curl for HTTP and HTTPS

```bash
curl -v https://api.example.com/health                  # full handshake and headers
curl -sS -o /dev/null -w 'http=%{http_code} ip=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' https://api.example.com/health
curl -I https://api.example.com/                         # HEAD request; headers only
curl -sS --connect-timeout 5 --max-time 20 https://api.example.com/health
curl -v --resolve api.example.com:443:192.0.2.10 https://api.example.com/health   # bypass DNS, keep SNI and Host correct
curl -v --connect-to api.example.com:443:backend01.example.com:443 https://api.example.com/   # route to another host, same name
curl -v -x http://proxy.example.com:8080 https://api.example.com/health   # through a proxy
curl -v --noproxy '*' https://api.example.com/health      # ignore proxy env vars
curl -v --cacert /path/to/ca.pem https://api.example.com/  # trust a specific CA bundle
curl -v --tlsv1.2 --tls-max 1.2 https://api.example.com/   # force TLS 1.2
```

The `-w` timings are cumulative from the start. `connect` minus `dns` is TCP time; `tls` minus `connect` is handshake time; `ttfb` minus `tls` is server processing time.

| Timing pattern | Points to |
| --- | --- |
| `dns` large | Slow or failing DNS server; a timeout on the first server before the second answers |
| `connect` large or timeout | Network path, firewall, or overloaded server accept queue |
| `tls` large | Slow handshake: OCSP or CRL fetch, large chain over a small MTU, overloaded TLS terminator |
| `ttfb` large | Application or backend slow |
| All fast, wrong result | Application-level; read the response |

Reading `curl -v`:

| Line | Meaning |
| --- | --- |
| `*   Trying 192.0.2.10:443...` | Address DNS returned |
| `* Connected to ...` | TCP succeeded |
| `* SSL connection using TLSv1.3 / ...` | Handshake succeeded |
| `*  subject: CN=...`, `*  subjectAltName: host "..." matched cert's "..."` | Certificate and name check |
| `*  SSL certificate verify ok.` | Chain trusted |
| `> GET /health HTTP/1.1` | Request sent |
| `< HTTP/1.1 200 OK` | Response status |
| `* Uses proxy env variable https_proxy == ...` | A proxy from the environment is in use |

`-v` prints request headers, including `Authorization`. Do not share `-v` output from authenticated calls without removing that line. `--trace` and `--trace-ascii` include bodies; use them only on test data.

Older curl versions on RHEL lack newer options such as `--json` (curl 7.82+). Check `curl --version`.

## Path tracing

```bash
tracepath -n api.example.com             # no root needed; shows path MTU
traceroute -n -T -p 443 api.example.com  # TCP SYN probes to port 443 (root); passes firewalls that drop UDP/ICMP probes
mtr -rwc 50 -T -P 443 api.example.com    # combined ping and traceroute report; loss per hop
```

```powershell
Test-NetConnection api.example.com -TraceRoute
tracert -d api.example.com
pathping -n api.example.com              # loss per hop over time; slow
```

Reading traces:

- `* * *` at one hop with later hops answering is normal: that router does not reply to probes.
- `* * *` from some hop onward means probes are dropped there or later. That can be the firewall in front of the destination.
- Loss shown at an intermediate hop but not at the final hop is usually ICMP rate limiting, not real loss.
- Default `traceroute` on Linux uses UDP; Windows `tracert` uses ICMP. Both can be blocked where TCP 443 is allowed. Prefer TCP mode.

## Listening and established connections

```bash
ss -ltnp                                  # what listens (Linux)
ss -tnp dst 192.0.2.10                    # connections to a host
```

```powershell
Get-NetTCPConnection -State Listen
Get-NetTCPConnection -RemoteAddress 192.0.2.10
```

A connection stuck in `SYN-SENT` on the client means no reply to the SYN. `SYN-RECV` on the server means the server replied but never got the final ACK: often asymmetric routing.

## Cautions

- Port scans (`nmap`, scripted loops over many ports) can trigger security alerts. Test only the ports you need.
- `-k` / `--insecure` in curl and `-SkipCertificateCheck` in PowerShell disable certificate checks. Use them only to confirm that a failure is a trust problem, against a test endpoint, and never in automation. See [tls-openssl.md](tls-openssl.md).
