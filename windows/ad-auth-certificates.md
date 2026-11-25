# Active Directory basics, Windows authentication, and certificates

Commands are read-only unless marked `CHANGE`. The `ActiveDirectory` module comes with RSAT or the AD DS role. `nltest`, `klist`, `setspn`, `w32tm`, and `certutil` are built in.

## Domain membership and domain controllers

```powershell
(Get-CimInstance Win32_ComputerSystem) | Select-Object Name, Domain, PartOfDomain
nltest /dsgetdc:example.com                       # which DC this host uses, and its site
nltest /sc_query:example.com                      # secure channel state
Test-ComputerSecureChannel -Verbose               # Windows PowerShell 5.1 only
nltest /dclist:example.com
Resolve-DnsName _ldap._tcp.dc._msdcs.example.com -Type SRV
w32tm /query /status                              # time source and last sync
w32tm /stripchart /computer:dc01.example.com /samples:3 /dataonly   # offset to a DC
```

| Symptom | Likely cause |
| --- | --- |
| `The trust relationship between this workstation and the primary domain failed` | Computer account password out of sync |
| `nltest /dsgetdc` fails | DNS points at non-AD servers, or SRV records not reachable |
| Kerberos errors on one host only | Time skew over 5 minutes from the DC |

```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)   # CHANGE: resets the machine account password
```

## Users, groups, and lockouts

```powershell
Get-ADUser svc-ansible -Properties Enabled, LockedOut, PasswordExpired, PasswordLastSet, LastLogonDate, BadLogonCount, 'msDS-UserPasswordExpiryTimeComputed' |
    Select-Object Name, Enabled, LockedOut, PasswordExpired, PasswordLastSet, LastLogonDate, BadLogonCount,
        @{n='PasswordExpires';e={ if ($_.'msDS-UserPasswordExpiryTimeComputed' -gt 0 -and $_.'msDS-UserPasswordExpiryTimeComputed' -lt [long]::MaxValue) { [datetime]::FromFileTime($_.'msDS-UserPasswordExpiryTimeComputed') } }}
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName
Get-ADPrincipalGroupMembership svc-ansible | Select-Object Name
Get-ADGroupMember 'Server Admins' -Recursive | Select-Object Name, ObjectClass
Get-ADComputer win01 -Properties OperatingSystem, LastLogonDate, ServicePrincipalNames
net user svc-ansible /domain                      # works without the AD module
whoami /groups                                    # groups in the current token
```

`BadLogonCount` and `LockedOut` are per-DC in some cases. Lockout events (4740) are logged on the DC that processed the lockout, usually the PDC emulator: `Get-ADDomain | Select-Object PDCEmulator`.

Find the source of lockouts on the PDC emulator:

```powershell
Get-WinEvent -ComputerName <pdc> -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = (Get-Date).AddHours(-4) } |
    Select-Object TimeCreated, @{n='User';e={$_.Properties[0].Value}}, @{n='Source';e={$_.Properties[1].Value}}
```

A service, scheduled task, mapped drive, or AAP credential still using an old password is the usual source.

```powershell
Unlock-ADAccount svc-ansible                      # CHANGE
```

## Kerberos

```powershell
klist                                             # tickets for the current logon session
klist -li 0x3e7                                   # tickets for SYSTEM (elevated)
setspn -L win01                                   # SPNs registered on the computer account
setspn -Q HTTP/win01.example.com                  # which account owns an SPN
setspn -X                                         # duplicate SPNs in the forest (slow)
```

Kerberos requires:

- A name that maps to an SPN. Connecting by IP address or an alias without an SPN falls back to NTLM or fails.
- Clocks within 5 minutes (default) of the DC.
- The client can reach a DC on TCP/UDP 88.
- No duplicate SPNs. Duplicates cause `KRB_AP_ERR_MODIFIED` or intermittent failures.

```powershell
klist purge                                       # CHANGE: clears the session's tickets; next access requests new ones
setspn -S HTTP/app.example.com svc-app            # CHANGE: adds an SPN after checking for duplicates
```

## Failed logon status codes

Security event 4625 on the target, or 4771/4776 on a DC.

| Status or Sub Status | Meaning |
| --- | --- |
| `0xC000006D` with sub `0xC000006A` | Wrong password |
| `0xC000006D` with sub `0xC0000064` | User name does not exist |
| `0xC0000234` | Account locked out |
| `0xC0000072` | Account disabled |
| `0xC000006F` | Outside allowed logon hours |
| `0xC0000070` | Workstation restriction |
| `0xC0000071` | Password expired |
| `0xC0000193` | Account expired |
| `0xC0000224` | Password must change at next logon |
| `0xC0000133` | Clock skew between client and DC |
| `0xC000015B` | Logon type not granted (for example, "Access this computer from the network" denied) |

4771 failure code `0x18` means bad password during Kerberos pre-authentication. `0x25` means clock skew.

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddHours(-1) } -MaxEvents 20 |
    ForEach-Object { $x = [xml]$_.ToXml(); [pscustomobject]@{
        Time = $_.TimeCreated
        User = ($x.Event.EventData.Data | Where-Object Name -eq 'TargetUserName').'#text'
        LogonType = ($x.Event.EventData.Data | Where-Object Name -eq 'LogonType').'#text'
        Status = ($x.Event.EventData.Data | Where-Object Name -eq 'Status').'#text'
        SubStatus = ($x.Event.EventData.Data | Where-Object Name -eq 'SubStatus').'#text'
        Source = ($x.Event.EventData.Data | Where-Object Name -eq 'IpAddress').'#text'
    } }
```

## Authentication versus authorization

| Signal | It is | Fix area |
| --- | --- | --- |
| 4625 on the target, HTTP 401 from WinRM | Authentication: who you are was not accepted | Password, account state, transport, SPN, time |
| 4624 succeeds, then "Access is denied" | Authorization: you are known but not allowed | Group membership, user rights, session configuration permissions, UAC token filtering |

## Group Policy

```powershell
gpresult /r /scope computer                       # applied computer GPOs
gpresult /h C:\Temp\gp.html                       # CHANGE: writes a detailed report; contains environment detail
gpupdate /force                                   # CHANGE: reapplies policy
```

## Certificates

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Select-Object Subject, Thumbprint, NotBefore, NotAfter, HasPrivateKey, @{n='SAN';e={$_.DnsNameList.Unicode -join ','}}, @{n='EKU';e={$_.EnhancedKeyUsageList.FriendlyName -join ','}}
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.NotAfter -lt (Get-Date).AddDays(30) } | Select-Object Subject, NotAfter, Thumbprint
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Example Root*'
Test-Certificate -Cert (Get-Item Cert:\LocalMachine\My\<thumbprint>) -Policy SSL -DNSName win01.example.com   # chain, revocation, name
certutil -verify -urlfetch C:\Temp\server.cer     # chain building and CRL/OCSP retrieval in detail
certutil -store My                                # store contents, including key provider
netsh http show sslcert                           # certificate bindings on HTTP.sys ports, such as IIS sites
```

Common certificate problems:

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Client says name mismatch | Name used by the client not in the SAN | `DnsNameList` |
| Chain cannot be built | Intermediate CA missing on the server or not trusted by the client | `certutil -verify -urlfetch` |
| Revocation check fails | CRL or OCSP URL unreachable from the client | `certutil -verify -urlfetch` output for each URL |
| Service cannot use the certificate | No private key, or the service account cannot read the key | `HasPrivateKey`; key permissions in the Certificates MMC (Manage Private Keys) |
| Works for some clients | Clients have different trust stores, or old clients lack the intermediate | Serve the full chain |

Export a public certificate for inspection elsewhere (safe; no private key):

```powershell
Export-Certificate -Cert Cert:\LocalMachine\My\<thumbprint> -FilePath C:\Temp\server.cer   # CHANGE: writes a file
```

Then inspect with `openssl x509 -inform der -in server.cer -noout -text`. See [network/tls-openssl.md](../network/tls-openssl.md).

## Cautions

- Never export a certificate with its private key (`.pfx`) to a shared location or this repository.
- `klist purge` on a service's session can break that service until it re-authenticates.
- AD queries against all users or all computers are heavy on large domains. Filter with `-Filter` and `-SearchBase`.
