# Network troubleshooting cheat sheet

Read-only unless marked `CHANGE`. Run checks from the host that makes the real connection. Details are in the linked guides.

## Layer by layer

| Layer | Linux | Windows | Pass looks like |
| --- | --- | --- | --- |
| All of it | `./check-endpoint.sh <host> [port]` | | Every step `[ OK ]` |
| DNS (like apps) | `getent hosts <name>` | `Resolve-DnsName <name>` | Expected address |
| DNS (one server) | `dig @<server> <name> +short` | `Resolve-DnsName <name> -Server <s> -DnsOnly` | Same answer from every server |
| Route | `ip route get <ip>` | `Find-NetRoute -RemoteIPAddress <ip>` | Expected interface and source |
| TCP | `timeout 5 bash -c '</dev/tcp/<h>/<p>'` | `Test-NetConnection <h> -Port <p>` | Connects |
| TLS | `openssl s_client -connect <h>:443 -servername <h> </dev/null` | `Test-WSMan <h> -UseSSL` (WinRM) | `Verify return code: 0 (ok)` |
| HTTP | `curl -sS -o /dev/null -w '%{http_code}\n' https://<h>/` | `(Invoke-WebRequest https://<h>/ -UseBasicParsing).StatusCode` | Any HTTP status = network OK |

## Symptom to cause

| Symptom | Most likely | Next step |
| --- | --- | --- |
| `Name or service not known`, `NXDOMAIN` | DNS | [dns.md](dns.md) |
| Refused, immediately | Nothing listening, or reject rule | `ss -ltnp` on the server |
| Timeout | Firewall drop, routing, host down | Capture on the server: SYN arriving? |
| `No route to host` | Reject rule or missing route | `ip route get`; firewall rules |
| Reset after connect | TLS mismatch, proxy policy, app crash | `openssl s_client`; proxy logs |
| `Verify return code: 20/21` | Missing intermediate or untrusted CA | [tls-openssl.md](tls-openssl.md#verify-return-codes) |
| `hostname mismatch` / curl (60) "no alternative certificate subject name" | Name not in SAN | Use the SAN name or reissue |
| Handshake hangs after connect | MTU | `ping -M do -s 1472` |
| HTTP 401 | Authentication | [api/http-error-troubleshooting.md](../api/http-error-troubleshooting.md) |
| HTTP 403 | Authorization, or a proxy denial | Check the response source |
| HTTP 407 | Proxy wants credentials | Proxy configuration |
| HTTP 502/503/504 | Gateway or LB backend problem | [lb-proxy-vpn.md](lb-proxy-vpn.md#load-balancers) |
| Works from A, not B | DNS, proxy, route, firewall source, trust store, clock | [workflows.md](workflows.md#works-from-one-host-but-not-another) |

## curl

| Goal | Command |
| --- | --- |
| Verbose handshake and headers | `curl -v https://<h>/` |
| Status and timings | `curl -sS -o /dev/null -w 'code=%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' https://<h>/` |
| Bypass DNS, keep SNI | `curl -v --resolve <h>:443:<ip> https://<h>/` |
| Trust a CA file | `curl -v --cacert ca.pem https://<h>/` |
| Use / skip proxy | `curl -v -x http://proxy:8080 https://<h>/` / `curl -v --noproxy '*' https://<h>/` |
| Force TLS 1.2 | `curl -v --tlsv1.2 --tls-max 1.2 https://<h>/` |
| Timeouts | `--connect-timeout 5 --max-time 20` |

## OpenSSL

| Goal | Command |
| --- | --- |
| Chain the server sends | `openssl s_client -connect <h>:443 -servername <h> -showcerts </dev/null` |
| Leaf summary | `... \| openssl x509 -noout -subject -issuer -dates -ext subjectAltName` |
| Check the name | add `-verify_hostname <h>` to `s_client` |
| Use a CA file | add `-CAfile ca.pem` |
| Certificate file | `openssl x509 -in c.pem -noout -text` |
| DER file | `openssl x509 -inform der -in c.cer -noout -text` |
| Chain offline | `openssl verify -untrusted int.pem -CAfile root.pem leaf.pem` |
| Key matches cert | compare `openssl x509 -in c.pem -noout -pubkey \| sha256sum` and `openssl pkey -in k.pem -pubout \| sha256sum` |
| Expires within 30 days | `openssl x509 -in c.pem -noout -checkend 2592000` (exit 1 = yes) |

## DNS

| Goal | Command |
| --- | --- |
| Short answer | `dig <name> +short` |
| Status and TTL | `dig <name>` (read `status:` and the TTL column) |
| Reverse | `dig -x <ip> +short` |
| AD DCs | `dig _ldap._tcp.dc._msdcs.<domain> SRV` |
| Over TCP | `dig <name> +tcp` |
| Windows | `Resolve-DnsName <name> -Type A -Server <dns>` |

## Path and performance

| Goal | Command |
| --- | --- |
| TCP traceroute | `traceroute -n -T -p 443 <h>` (root) |
| Per-hop loss | `mtr -rwc 50 -T -P 443 <h>` |
| Path MTU | `tracepath -n <h>`; `ping -M do -s 1472 <h>` |
| Retransmits | `nstat -az \| grep -i retrans`; `ss -ti dst <ip>` |
| Windows trace | `Test-NetConnection <h> -TraceRoute`; `pathping -n <h>` |
| `CHANGE` Capture | `tcpdump -i any -nn -w /tmp/x.pcap host <ip> and port 443 -c 2000` |

## Proxies

| Goal | Command |
| --- | --- |
| Linux env | `env \| grep -i _proxy` |
| Windows services | `netsh winhttp show proxy` |
| Did curl use one? | `curl -v ... 2>&1 \| grep -i proxy` |
