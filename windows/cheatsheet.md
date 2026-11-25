# Windows Server cheat sheet

PowerShell, Windows Server 2016 through 2025. Read-only unless marked `CHANGE` or `RESTART`. Details are in the linked guides.

## First two minutes

| Check | Command | What to look for |
| --- | --- | --- |
| OS and last boot | `Get-CimInstance Win32_OperatingSystem \| Select Caption, BuildNumber, LastBootUpTime` | Recent unexpected reboot |
| Stopped auto services | `Get-Service \| ? { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }` | Critical services down |
| Recent errors | `Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddHours(-24)} -MaxEvents 30` | Repeating sources |
| Disk | `Get-Volume` | Low `SizeRemaining` on C: |
| Pending reboot | See [pending reboot](updates-wsus-reboot.md#pending-reboot-detection) | Any strong signal `True` |
| Time | `w32tm /query /status` | Source and last sync |
| Domain | `nltest /sc_query:<domain>` | `NERR_Success` |

## Services and events

| Problem | Command | What to look for |
| --- | --- | --- |
| Service detail | `Get-CimInstance Win32_Service -Filter "Name='<svc>'" \| Select Name,State,StartMode,StartName,PathName` | Account, path |
| Why it failed | System log, `ProviderName='Service Control Manager'`, IDs 7000, 7023, 7031, 7034, 7038 | Logon failure, crash |
| Unexpected reboot | System IDs 41, 1074, 6005, 6006, 6008 | Who or what restarted |
| Logon failures | Security ID 4625 | `Status`, `SubStatus`, `LogonType` |
| WinRM errors | `Get-WinEvent -LogName Microsoft-Windows-WinRM/Operational -MaxEvents 30` | Listener and auth errors |
| `RESTART` | `Restart-Service <svc>` | WinRM restart drops all sessions |

## Network and firewall

| Problem | Command | What to look for |
| --- | --- | --- |
| IP, gateway, DNS | `Get-NetIPConfiguration` | Correct DNS servers |
| Route to a host | `Find-NetRoute -RemoteIPAddress <ip>` | Interface and source |
| Resolve like apps | `Resolve-DnsName <name>` | Hosts file or cache effects |
| Resolve via one server | `Resolve-DnsName <name> -Server <dns> -DnsOnly` | Server disagreement |
| TCP port | `Test-NetConnection <host> -Port <p>` | `TcpTestSucceeded` |
| Listening | `Get-NetTCPConnection -State Listen -LocalPort <p>` | Owning process |
| Firewall profile | `Get-NetConnectionProfile` | `Domain` vs `Public` |
| Rule for a port | `Get-NetFirewallPortFilter -Protocol TCP \| ? LocalPort -eq <p> \| Get-NetFirewallRule` | Enabled, profile, action |
| Proxy for services | `netsh winhttp show proxy` | Direct vs proxy |
| `CHANGE` | `Clear-DnsClientCache` | Stale cache |

## WinRM

| Problem | Command | What to look for |
| --- | --- | --- |
| Listeners | `winrm enumerate winrm/config/listener` | HTTPS on 5986, valid thumbprint |
| Auth settings | `winrm get winrm/config/service/auth` | Basic false; Kerberos/Negotiate true |
| Quotas | `winrm get winrm/config/winrs` | `MaxMemoryPerShellMB` |
| Remote test | `Test-WSMan <host> -UseSSL` | Response vs TLS error |
| Endpoint permissions | `Get-PSSessionConfiguration \| Select Name, Permission` | Your group allowed |
| SPNs | `setspn -L <computer>` | `HTTP/` or `HOST/` with FQDN |
| `CHANGE` | `New-Item WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint <t> -Force` | Creates HTTPS listener |

## Updates

| Problem | Command | What to look for |
| --- | --- | --- |
| Update source | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `WUServer`; `AU\UseWUServer = 1` |
| Installed | `Get-HotFix \| Sort InstalledOn -Desc \| Select -First 10` | Latest KB date |
| Update events | System log, provider `Microsoft-Windows-WindowsUpdateClient` | 20 = failed, with HRESULT |
| Error code | [HRESULT table](updates-wsus-reboot.md#common-hresults) | Meaning and first check |
| Component store | `Dism /Online /Cleanup-Image /ScanHealth` | Corruption reported |
| `CHANGE` | `Dism /Online /Cleanup-Image /RestoreHealth`; `sfc /scannow` | Repairs |

## Identity and certificates

| Problem | Command | What to look for |
| --- | --- | --- |
| Account state | `Get-ADUser <u> -Properties LockedOut,Enabled,PasswordExpired,PasswordLastSet` | Locked, disabled, expired |
| Lockout source | Event 4740 on the PDC emulator | Caller computer |
| Groups in token | `whoami /groups` | Expected group present (re-logon after changes) |
| Kerberos tickets | `klist` | Ticket for the target SPN |
| Time vs DC | `w32tm /stripchart /computer:<dc> /samples:3 /dataonly` | Offset under 5 minutes |
| Certs expiring | `Get-ChildItem Cert:\LocalMachine\My \| ? NotAfter -lt (Get-Date).AddDays(30)` | Upcoming expiries |
| Chain and revocation | `certutil -verify -urlfetch <file.cer>` | Failed URLs, missing intermediates |
| `CHANGE` | `Unlock-ADAccount <u>`; `klist purge` | After fixing the cause |

## Ansible-managed Windows quick map

| Ansible error contains | Check on Windows |
| --- | --- |
| `Connection refused` / `timed out` | Listener and firewall rule for 5985/5986 |
| `certificate verify failed` | Listener certificate SAN, expiry, chain |
| `credentials were rejected` | Security 4625 `SubStatus`; transport; remote UAC for local accounts |
| `Server not found in Kerberos database` | SPN for the FQDN; inventory uses FQDN not IP |
| `0x80070005` from updates or scripts | Use `become: true`, `become_method: runas` |
| Module out-of-memory | `MaxMemoryPerShellMB` |
