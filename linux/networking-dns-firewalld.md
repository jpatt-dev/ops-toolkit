# Networking, DNS, and firewalld on RHEL

Host-side view. For protocol-level workflows (refused vs timeout, TLS, proxies), see [network/](../network/README.md). Commands are read-only unless marked `CHANGE`.

## Interfaces, addresses, and routes

```bash
ip -br addr                        # one line per interface: state and addresses
ip -br link                        # link state and MAC
ip route                           # routing table
ip route get 192.0.2.10            # which route, interface, and source address a destination uses
ip -s link show eth0               # RX/TX counters, errors, drops
ip neigh                           # ARP/neighbor table; FAILED or INCOMPLETE means no layer-2 answer
nmcli -f GENERAL,IP4,IP6 device show eth0
nmcli connection show              # profiles; the active one is colored or listed under DEVICE
nmcli connection show '<profile>'  # every setting of one profile
ethtool eth0                       # speed, duplex, link detected (physical or virtual NIC)
ethtool -S eth0 | grep -Ei 'err|drop|miss'   # driver error counters
```

`ip route get` answers "which way will this traffic go" without sending anything. Use it first when a host has several interfaces or a VPN.

### Where configuration lives

| Release | Profiles |
| --- | --- |
| RHEL 8 | `ifcfg` files in `/etc/sysconfig/network-scripts/` by default; keyfiles supported |
| RHEL 9 | New profiles are keyfiles in `/etc/NetworkManager/system-connections/`; existing `ifcfg` files still work |
| RHEL 10 | Keyfiles only. `ifcfg` profiles are not supported and are ignored. The team driver and `dhclient` were removed. |

Before upgrading RHEL 9 to 10, migrate `ifcfg` profiles with `nmcli connection migrate` (`CHANGE`) and convert teams to bonds.

Changes:

```bash
nmcli connection modify '<profile>' ipv4.dns '192.0.2.53 192.0.2.54'   # CHANGE
nmcli connection up '<profile>'                                         # CHANGE: reapplies; can drop your SSH session
nmcli device reapply eth0                                               # CHANGE: apply without a full down/up where supported
```

Apply network changes on a remote host only with console access or a scheduled rollback.

## Listening sockets and connections

```bash
ss -ltnp                           # listening TCP with process
ss -lunp                           # listening UDP with process
ss -tnp state established '( dport = :443 or sport = :443 )'
ss -s                              # summary counts by state
ss -tn state time-wait | wc -l     # TIME-WAIT count
ss -ti dst 192.0.2.10              # per-connection RTT, retransmits, congestion window
```

A service listening on `127.0.0.1:8080` is not reachable from other hosts. It must listen on `0.0.0.0`, `[::]`, or the interface address.

## DNS on the host

```bash
cat /etc/resolv.conf               # nameservers and search domains actually used
nmcli dev show | grep -i dns       # DNS NetworkManager pushed into resolv.conf
grep hosts /etc/nsswitch.conf      # lookup order: files, dns, myhostname, sss
getent hosts host01.example.com    # resolves the way applications do (includes /etc/hosts)
getent ahosts host01.example.com   # all addresses, IPv4 and IPv6
dig host01.example.com +short      # DNS only; ignores /etc/hosts (bind-utils)
dig @192.0.2.53 host01.example.com # ask one specific server
```

`getent` and `dig` disagreeing usually means `/etc/hosts`, nsswitch order, or a search domain. See [network/dns.md](../network/dns.md) for record-level troubleshooting.

On RHEL, NetworkManager writes `/etc/resolv.conf`. Manual edits are overwritten unless NetworkManager is configured not to manage it. `systemd-resolved` is not enabled by default.

## firewalld

```bash
firewall-cmd --state
firewall-cmd --get-active-zones                    # which zone each interface and source uses
firewall-cmd --get-default-zone
firewall-cmd --list-all                            # default zone: services, ports, rich rules
firewall-cmd --list-all --zone=public
firewall-cmd --list-all-zones | less
firewall-cmd --info-service=https                  # ports a service name opens
firewall-cmd --get-log-denied                      # whether denied packets are logged
nft list ruleset | less                            # what the kernel actually enforces (RHEL 8+ backend)
```

Reading `--list-all`: an interface or source listed under a zone gets that zone's rules. Traffic from a source in `sources:` matches that zone before interface zones.

Changes. Runtime changes are lost on reload unless made permanent:

```bash
firewall-cmd --zone=public --add-service=https                  # CHANGE: runtime only, for testing
firewall-cmd --zone=public --add-service=https --permanent      # CHANGE: persistent
firewall-cmd --reload                                           # CHANGE: applies permanent config; drops runtime-only rules
firewall-cmd --zone=public --add-port=8443/tcp --permanent      # CHANGE
firewall-cmd --set-log-denied=all                               # CHANGE: log drops to the journal; turn off afterwards
firewall-cmd --runtime-to-permanent                             # CHANGE: save tested runtime rules
```

Firewall workflow:

1. Is the service listening on the right address? `ss -ltnp`.
2. Does a local connection work? `curl -v http://127.0.0.1:<port>`.
3. Which zone handles the traffic? `firewall-cmd --get-active-zones`.
4. Is the port or service allowed in that zone? `firewall-cmd --list-all --zone=<zone>`.
5. Temporarily log denies and retry from the client: `firewall-cmd --set-log-denied=unicast` (`CHANGE`), then `journalctl -k -f | grep -i reject`. Turn it off afterwards with `firewall-cmd --set-log-denied=off` (`CHANGE`).
6. If the host allows it and it still fails, look upstream: network firewalls, security groups, load balancers.

Remember SELinux port labels too. A service on a non-standard port can be allowed by firewalld and still be blocked by SELinux. See [selinux.md](selinux.md#ports).

## Cautions

- `nmcli connection up` or `down` on the interface you are connected through can disconnect you.
- `firewall-cmd --reload` drops runtime rules you added for testing.
- Do not stop firewalld to "test." Use targeted runtime rules and remove them.
