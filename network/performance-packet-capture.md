# Network performance and packet captures

Measurement is read-only but can add load. Packet captures record traffic content; treat every capture file as sensitive. The repository `.gitignore` excludes `*.pcap`, `*.pcapng`, and `captures/`.

## Is it the network?

Before measuring the network, rule out the endpoints with `curl -w` timings ([connectivity-testing.md](connectivity-testing.md#curl-for-http-and-https)). Slow `ttfb` with fast `connect` is the application, not the network.

## Latency and loss

```bash
ping -c 20 192.0.2.10                     # RTT and loss (if ICMP is allowed)
mtr -rwc 100 -T -P 443 192.0.2.10         # loss and latency per hop, using TCP 443
ss -ti dst 192.0.2.10                     # per-connection rtt, retrans, cwnd for live connections
nstat -az | grep -Ei 'TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPSynRetrans'
ip -s link show eth0                      # interface errors and drops
ethtool -S eth0 | grep -Ei 'err|drop|discard|crc'
```

```powershell
Test-Connection 192.0.2.10 -Count 20
Get-NetAdapterStatistics | Select-Object Name, ReceivedDiscardedPackets, ReceivedPacketErrors, OutboundDiscardedPackets
netstat -s -p tcp                          # segments retransmitted
```

| Indicator | Points to |
| --- | --- |
| Rising `TcpRetransSegs` | Loss somewhere on the path |
| `rtt` in `ss -ti` far above `ping` RTT | Queueing, or a slow receiver |
| Interface `errors`, CRC errors | Cabling, NIC, or duplex problem on a physical link |
| `drops` on the interface | Host could not keep up, or ring buffer too small |
| Loss only at the last hop in `mtr` | Real loss near the destination |
| Loss at a middle hop only | ICMP rate limiting at that router; usually harmless |

## Throughput

`iperf3` measures throughput between two hosts you control. It needs a port open between them.

```bash
iperf3 -s -p 5201                         # on the server (CHANGE: opens a listener)
iperf3 -c 192.0.2.10 -p 5201 -t 10        # client to server
iperf3 -c 192.0.2.10 -p 5201 -t 10 -R     # reverse: server to client
iperf3 -c 192.0.2.10 -p 5201 -t 10 -P 4   # four parallel streams
```

One stream far below the link speed but four streams near it suggests latency and TCP window limits, not bandwidth. Throughput expected per stream is roughly window size divided by RTT.

## MTU problems

Symptom: TCP connects, small requests work, large responses or TLS handshakes hang.

```bash
ping -M do -s 1472 -c 3 192.0.2.10        # 1500-byte packets with Don't Fragment
ping -M do -s 1372 -c 3 192.0.2.10        # smaller; find the largest size that works
tracepath -n 192.0.2.10                   # reports pmtu
```

```powershell
ping -f -l 1472 192.0.2.10
```

`Message too long` or `Packet needs to be fragmented but DF set` means the local interface MTU is smaller. No reply at large sizes but replies at smaller sizes means a link on the path has a smaller MTU and ICMP "fragmentation needed" is not getting back. The fix is on the network: allow that ICMP type, or clamp TCP MSS on the tunnel or firewall.

## Packet captures

Capture only what you need: filter by host and port, limit the count or size, and capture for a short time.

### Linux tcpdump

```bash
tcpdump -D                                                 # list interfaces
tcpdump -i any -nn host 192.0.2.10 and port 443 -c 50      # print summary lines, no file
tcpdump -i any -nn 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0 and host 192.0.2.10'   # only SYN and RST: connection attempts and resets
tcpdump -i eth0 -nn -s 0 -w /tmp/case123.pcap host 192.0.2.10 and port 443 -c 2000   # CHANGE: writes a capture file
tcpdump -nn -r /tmp/case123.pcap | head                    # read it back
```

| Flag | Effect |
| --- | --- |
| `-nn` | No DNS or port name lookups (faster, no extra DNS traffic) |
| `-i any` | All interfaces (Linux cooked capture) |
| `-c N` | Stop after N packets |
| `-s 0` | Full packets (default in modern tcpdump) |
| `-w file` | Write raw packets |
| `-G 60 -W 5` | Rotate every 60 s, keep 5 files |

Reading tcpdump flags: `[S]` SYN, `[S.]` SYN-ACK, `[.]` ACK, `[P.]` data, `[F.]` FIN, `[R]` or `[R.]` reset.

| Pattern | Meaning |
| --- | --- |
| `[S]` repeated with no `[S.]` | SYN dropped or not answered: firewall or routing |
| `[S]` then `[R.]` | Port closed or rejected |
| Handshake completes, then `[R]` from the server | Application or middlebox closed: TLS rejection, proxy policy |
| Client Hello sent, no Server Hello | TLS blocked or the server cannot negotiate |
| Retransmissions of the same sequence | Loss |

### tshark

```bash
tshark -r /tmp/case123.pcap -Y 'tls.handshake.type == 1' -T fields -e ip.dst -e tls.handshake.extensions_server_name   # Client Hello and SNI
tshark -r /tmp/case123.pcap -Y 'tls.alert_message' -T fields -e ip.src -e tls.alert_message.desc   # TLS alerts
tshark -r /tmp/case123.pcap -Y 'tcp.analysis.retransmission' | wc -l
tshark -r /tmp/case123.pcap -q -z conv,tcp                  # conversations summary
```

### Windows

```powershell
pktmon filter add -i 192.0.2.10 -p 443          # CHANGE: add a capture filter
pktmon start --capture --pkt-size 0 -f C:\Temp\case123.etl   # CHANGE: start capture
pktmon stop
pktmon etl2pcap C:\Temp\case123.etl --out C:\Temp\case123.pcapng   # convert for Wireshark (newer Windows builds)
pktmon filter remove
```

On older builds, `netsh trace start capture=yes tracefile=C:\Temp\case123.etl maxsize=200` and `netsh trace stop` (`CHANGE`) produce an ETL file that needs conversion before Wireshark can read it.

## Handling capture files

- Captures can include credentials sent over HTTP, cookies, tokens, hostnames, and payloads.
- Store them outside this repository, in a location approved for diagnostics. Delete them when the case closes.
- Share filtered extracts (for example, only handshake packets) rather than full captures.
- TLS payloads are encrypted in captures. Do not export session keys from production systems to decrypt them.
