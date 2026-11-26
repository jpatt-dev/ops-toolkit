# Windows networking, DNS, proxy, and firewall

Host-side view. For protocol-level workflows (refused vs timeout, TLS handshakes), see [network/workflows.md](../network/workflows.md). Commands are read-only unless marked `CHANGE`.

## Addresses and routes

```powershell
Get-NetIPConfiguration                         # per interface: IPv4, gateway, DNS servers
Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MacAddress
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin
Get-NetRoute -AddressFamily IPv4 | Sort-Object RouteMetric | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric
Find-NetRoute -RemoteIPAddress 192.0.2.10      # route and source address for a destination
Get-NetAdapterStatistics                       # errors and discards
ipconfig /all
route print
arp -a
```

`Find-NetRoute` is the Windows equivalent of `ip route get`. Use it on multi-homed servers.

## Name resolution

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix, RegisterThisConnectionsAddress
Get-DnsClientGlobalSetting                      # suffix search list
Resolve-DnsName host01.example.com              # uses the DNS client: hosts file, cache, then DNS
Resolve-DnsName host01.example.com -Server 192.0.2.53 -DnsOnly   # ask one server, skip hosts file and cache
Resolve-DnsName host01.example.com -Type A -NoHostsFile
Resolve-DnsName _ldap._tcp.dc._msdcs.example.com -Type SRV       # domain controller records
Get-DnsClientCache | Where-Object Entry -like '*example*'
Get-Content C:\Windows\System32\drivers\etc\hosts
nslookup host01.example.com 192.0.2.53
```

`nslookup` talks to DNS directly and ignores the hosts file and client cache. `Resolve-DnsName` without `-DnsOnly` resolves the way applications do. When they disagree, check the hosts file and cache.

```powershell
Clear-DnsClientCache                            # CHANGE
ipconfig /flushdns                              # CHANGE: same effect
ipconfig /registerdns                           # CHANGE: re-register this host's A/PTR records
```

## Connectivity tests

```powershell
Test-NetConnection host01.example.com -Port 443                 # DNS + TCP; TcpTestSucceeded True/False
Test-NetConnection host01.example.com -Port 5986 -InformationLevel Detailed
Test-NetConnection host01.example.com -TraceRoute
Test-Connection host01.example.com -Count 2                     # ICMP; often blocked, so failure proves little
Get-NetTCPConnection -State Listen -LocalPort 5985, 5986 -ErrorAction SilentlyContinue
Get-NetTCPConnection -RemotePort 443 -State Established
Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Process';e={(Get-Process -Id $_.OwningProcess).Name}}
netstat -ano | findstr :5986
```

`Test-NetConnection` reports `TcpTestSucceeded : False` for both a refusal and a timeout. It waits several seconds on a timeout and returns quickly on a refusal; the warning text also differs. For a clear distinction, use the .NET client:

```powershell
$c = New-Object System.Net.Sockets.TcpClient
try { $c.Connect('host01.example.com', 443); 'connected' } catch { $_.Exception.InnerException.Message } finally { $c.Dispose() }
```

A message like "actively refused" is a refusal (nothing listening, or a firewall reject). "A connection attempt failed because the connected party did not properly respond" is a timeout (packets dropped).

## Proxies

Windows has more than one proxy setting:

| Consumer | Setting | Check |
| --- | --- | --- |
| Services, Windows Update, WinHTTP clients | WinHTTP proxy | `netsh winhttp show proxy` |
| Interactive user apps, Windows PowerShell 5.1 web cmdlets | User (WinINET) proxy | `Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' \| Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL` |
| PowerShell 7 web cmdlets | Environment variables, then system settings | `$env:HTTPS_PROXY`, `$env:NO_PROXY` |

A WinRM session from Ansible runs without the user's interactive proxy settings. A web request that works in your desktop session can fail in a job. Pass `-Proxy` explicitly, or set the WinHTTP proxy for services.

```powershell
netsh winhttp set proxy proxy-server="proxy.example.com:8080" bypass-list="*.example.com;<local>"   # CHANGE
netsh winhttp reset proxy                                                                           # CHANGE
```

## Windows Firewall

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogFileName, LogBlocked
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory    # Domain, Private, or Public
Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' | Select-Object Name, DisplayName, Enabled, Profile, Direction, Action
Get-NetFirewallPortFilter -Protocol TCP | Where-Object LocalPort -eq 5986 | Get-NetFirewallRule | Select-Object DisplayName, Enabled, Profile, Action
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' | Get-NetFirewallAddressFilter   # which remote addresses are allowed
```

The active profile depends on the network category. A server whose interface is `Public` instead of `Domain` gets the Public rules, which are often stricter. The built-in WinRM rule for the Public profile allows only the local subnet by default.

Firewall rules can come from Group Policy. Local changes to a GPO-managed setting are overwritten or ignored. Check `gpresult /r` and the rule's `PolicyStoreSource` with `Get-NetFirewallRule -PolicyStore ActiveStore`.

Changes:

```powershell
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Domain -RemoteAddress 192.0.2.0/24   # CHANGE
Set-NetFirewallProfile -Profile Domain -LogBlocked True -LogFileName '%systemroot%\system32\LogFiles\Firewall\pfirewall.log'   # CHANGE: log drops
```

Then read `pfirewall.log` for `DROP` lines while the client retries. Turn logging off afterwards.

## Workflow: a client cannot connect to this server

1. Is the service listening? `Get-NetTCPConnection -State Listen -LocalPort <p>`.
2. Does a local connection work? `Test-NetConnection localhost -Port <p>`.
3. Which firewall profile is active? `Get-NetConnectionProfile`.
4. Is there an enabled allow rule for that port, profile, and remote address?
5. Enable drop logging and retry from the client.
6. If the server allows it, check network firewalls and load balancers between them.

## Cautions

- Do not disable a firewall profile to test. Add a narrow rule and remove it after.
- `ipconfig /release` on a remote server disconnects you.
- WinHTTP proxy changes affect every service on the host, including Windows Update.
