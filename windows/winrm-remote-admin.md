# WinRM and remote administration

The Windows side of WinRM: listeners, authentication settings, certificates, quotas, and remote PowerShell. For errors as Ansible reports them, start with [ansible/connectivity-ssh-winrm.md](../ansible/connectivity-ssh-winrm.md#windows-and-winrm). Commands are read-only unless marked `CHANGE` or `RESTART`. Run elevated.

## Is WinRM running and listening?

```powershell
Get-Service WinRM | Select-Object Status, StartType
winrm enumerate winrm/config/listener                  # every listener: transport, port, address, certificate thumbprint
Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { Get-ChildItem $_.PSPath } | Format-Table Name, Value
Get-NetTCPConnection -State Listen -LocalPort 5985, 5986 -ErrorAction SilentlyContinue
Test-WSMan -ComputerName localhost                     # local HTTP listener answers
Test-WSMan -ComputerName win01.example.com -UseSSL     # from another host: HTTPS listener, TLS and trust
```

Reading a listener:

| Field | Meaning |
| --- | --- |
| `Transport = HTTPS`, `Port = 5986` | Encrypted listener |
| `Address = *` | Listens on all addresses |
| `Hostname` | Name the certificate must match for HTTPS |
| `CertificateThumbprint` | Certificate in `Cert:\LocalMachine\My` used by the listener |
| `Enabled = true` | Listener is active |
| `ListeningOn` | Actual IP addresses |

If the thumbprint points to a certificate that expired or was replaced, the HTTPS listener stops accepting TLS. Clients see a handshake or certificate error, not a refusal.

## Service configuration

```powershell
winrm get winrm/config/service                         # auth methods, AllowUnencrypted, IPv4/IPv6 filters
winrm get winrm/config/service/auth
winrm get winrm/config/winrs                           # MaxMemoryPerShellMB, MaxShellsPerUser, MaxProcessesPerShell
Get-Item WSMan:\localhost\Service\AllowUnencrypted
Get-Item WSMan:\localhost\Service\Auth\* | Select-Object Name, Value
Get-Item WSMan:\localhost\MaxEnvelopeSizekb
Get-PSSessionConfiguration | Select-Object Name, Permission   # who may connect to each endpoint
```

| Setting | Secure default | Notes |
| --- | --- | --- |
| `Auth\Basic` | `false` | Leave off. Basic sends the password with every request. |
| `Auth\Kerberos` | `true` | Domain accounts |
| `Auth\Negotiate` | `true` | NTLM and Kerberos negotiation |
| `Auth\CredSSP` | `false` | Enable only for approved second-hop needs |
| `Auth\Certificate` | `false` | Client certificate mapping |
| `AllowUnencrypted` | `false` | Keep `false`. Ansible with NTLM, Kerberos, or CredSSP encrypts messages over HTTP; HTTPS is still preferred. |
| `winrs\MaxMemoryPerShellMB` | Varies | Low values make large modules fail with out-of-memory or `Exception of type 'System.OutOfMemoryException'` |

Settings managed by Group Policy (Computer Configuration > Administrative Templates > Windows Components > Windows Remote Management) show `Source="GPO"` and cannot be changed locally.

## Create or repair an HTTPS listener

Use a certificate from your internal CA with the server FQDN in the Subject Alternative Name and the Server Authentication EKU. A self-signed certificate works only if every client is told to trust it.

```powershell
# Find a usable certificate
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.EnhancedKeyUsageList.FriendlyName -contains 'Server Authentication' } |
    Select-Object Thumbprint, Subject, NotAfter, @{n='SAN';e={$_.DnsNameList.Unicode -join ','}}
```

```powershell
# CHANGE: create the listener with that certificate
$thumb = '<thumbprint>'
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $thumb -Force

# CHANGE: replace the certificate on an existing listener
Get-ChildItem WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' } |
    ForEach-Object { Set-Item -Path "$($_.PSPath)\CertificateThumbprint" -Value $thumb -Force }

Restart-Service WinRM        # RESTART: drops existing sessions
```

Then open the firewall for 5986 on the right profile. See [networking-firewall.md](networking-firewall.md#windows-firewall).

`Enable-PSRemoting -Force` and `winrm quickconfig` (`CHANGE`) create an HTTP listener and firewall rules with defaults. They do not create an HTTPS listener.

## Local accounts over the network

By default, remote UAC filters the token of local administrator accounts (other than the built-in Administrator) for network logons. WinRM with a local admin account then fails with access denied even though the password is right.

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
```

Setting `LocalAccountTokenFilterPolicy` to `1` (`CHANGE`) removes that protection for every local admin account. Prefer a domain account for automation. If a local account is required, get the change approved and document it.

## Authentication problems

| Symptom | Check |
| --- | --- |
| `Access is denied` with a correct password | Account in local Administrators or `Remote Management Users`? `Get-PSSessionConfiguration` permissions; remote UAC for local accounts |
| Kerberos fails, NTLM works | Connecting by IP or by a name without an SPN. `setspn -Q HTTP/win01.example.com` and `setspn -L win01`; client clock skew |
| Works from one subnet, not another | Firewall rule remote address, or `IPv4Filter` in `winrm get winrm/config/service` |
| `The WinRM client cannot process the request ... TrustedHosts` (PowerShell client) | Client is not in a domain trust and uses NTLM to a name not in `TrustedHosts`. Prefer HTTPS with a trusted certificate. |
| Second hop fails (file share or SQL from inside the session) | Delegation needed: Kerberos delegation, CredSSP, or `become` in Ansible |

Security log on the target (event 4625) shows why a logon failed. See [ad-auth-certificates.md](ad-auth-certificates.md#failed-logon-status-codes).

## WinRM event log

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-WinRM/Operational' -MaxEvents 50 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

Errors here show listener, authentication, and plugin problems that the client only sees as a generic failure.

## Remote administration

```powershell
Enter-PSSession -ComputerName win01.example.com -UseSSL                 # interactive
Invoke-Command -ComputerName win01.example.com -UseSSL -ScriptBlock { Get-Service WinRM }
$s = New-PSSession -ComputerName win01.example.com, win02.example.com -UseSSL
Invoke-Command -Session $s -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
Remove-PSSession $s
Invoke-Command -ComputerName win01.example.com -UseSSL -Credential (Get-Credential) -ScriptBlock { whoami }
```

`Get-Credential` prompts and keeps the password in memory only. Do not store credentials in scripts or in this repository.

Tools that do not use WinRM, and the ports they need:

| Tool | Protocol and port |
| --- | --- |
| `Get-WinEvent -ComputerName`, Event Viewer remote | RPC (TCP 135 + dynamic ports) |
| Services MMC, `sc.exe \\host` | RPC and SMB |
| `\\host\c$` | SMB (TCP 445) |
| Remote Desktop | TCP/UDP 3389 |
| `Get-CimInstance -ComputerName` | WinRM by default (WSMan); DCOM with a `-CimSession` that uses DCOM options |

## Cautions

- Restarting WinRM drops every remote session, including the one you are using.
- Do not enable Basic authentication or `AllowUnencrypted` to make a connection work.
- `TrustedHosts = *` disables server identity checks for NTLM connections from that client.
- Keep at least one non-WinRM path (console or RDP) before changing listeners remotely.
