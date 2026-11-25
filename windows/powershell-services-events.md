# PowerShell administration, services, and event logs

Windows Server 2016 through 2025. Examples work in Windows PowerShell 5.1 unless noted. Commands are read-only unless marked `CHANGE` or `RESTART`. Run an elevated session for system-wide information.

## Know your session

```powershell
$PSVersionTable.PSVersion                 # 5.1 = Windows PowerShell; 7.x = PowerShell 7
$PSVersionTable.PSEdition                 # Desktop or Core
whoami /all                               # user, groups, privileges, integrity level
[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
Get-ExecutionPolicy -List                 # policy at each scope
$env:PSModulePath -split ';'
Get-Module -ListAvailable ActiveDirectory, DnsServer
```

Ansible Windows modules run in Windows PowerShell 5.1 on the target, not PowerShell 7. Test commands in 5.1 when they will be used from `ansible.windows.win_shell` or `win_powershell`.

## System information

```powershell
Get-ComputerInfo -Property OsName, OsVersion, OsBuildNumber, CsDomain, CsTotalPhysicalMemory, OsLastBootUpTime
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, FreePhysicalMemory
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain, Model, TotalPhysicalMemory
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, LoadPercentage
Get-Volume | Select-Object DriveLetter, FileSystemLabel, SizeRemaining, Size
Get-PSDrive -PSProvider FileSystem
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10
systeminfo                                  # one-shot summary; slower
```

## Processes and performance

```powershell
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, CPU, WS
Get-Process | Sort-Object WS -Descending | Select-Object -First 10 Name, Id, @{n='WS_MB';e={[int]($_.WS/1MB)}}
Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" | Select-Object ProcessId, CommandLine
Get-Counter '\Processor(_Total)\% Processor Time','\Memory\Available MBytes','\PhysicalDisk(_Total)\Avg. Disk sec/Transfer' -SampleInterval 2 -MaxSamples 3
```

`Avg. Disk sec/Transfer` is latency in seconds. Values consistently above 0.025 (25 ms) usually mean slow storage.

```powershell
Stop-Process -Id 1234                       # CHANGE: ends the process
```

## Services

```powershell
Get-Service WinRM
Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }   # auto services that are stopped
Get-CimInstance Win32_Service -Filter "Name='WinRM'" | Select-Object Name, State, StartMode, StartName, ProcessId, PathName
Get-Service WinRM -DependentServices; Get-Service WinRM -RequiredServices
sc.exe qc WinRM                             # configuration, including dependencies and account
sc.exe queryex WinRM                        # state and PID
sc.exe qfailure WinRM                       # recovery actions
```

`StartName` is the service account. A service running as a domain account fails to start when that account's password changes or the account is locked. Check System log event 7000 or 7038.

Use `sc.exe`, not `sc`. In PowerShell, `sc` is an alias for `Set-Content`.

Changes:

```powershell
Restart-Service WinRM                                   # RESTART
Start-Service Spooler                                   # CHANGE
Set-Service -Name Spooler -StartupType Disabled         # CHANGE
sc.exe failure MyService reset= 86400 actions= restart/60000   # CHANGE: restart after 60 s on failure
```

Restarting WinRM drops every remote session, including the Ansible connection that ran the command.

### Service failure events (System log, source Service Control Manager)

| Event ID | Meaning |
| --- | --- |
| 7000 | Service failed to start (often logon failure or missing executable) |
| 7001 | Service depends on a service that failed to start |
| 7009 | Timeout waiting for the service to connect |
| 7011 | Timeout waiting for a transaction response |
| 7023 | Service terminated with an error |
| 7031 | Service terminated unexpectedly; recovery action taken |
| 7034 | Service terminated unexpectedly |
| 7036 | Service entered the running or stopped state |
| 7038 | Service could not log on with the configured password |
| 7045 | A new service was installed |

## Event logs

```powershell
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object RecordCount -gt 0 | Sort-Object LogName | Select-Object LogName, RecordCount
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 50
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7031, 7034 } -MaxEvents 20
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 2 } -MaxEvents 20 | Format-List TimeCreated, ProviderName, Id, Message
Get-WinEvent -LogName 'Microsoft-Windows-WinRM/Operational' -MaxEvents 30
wevtutil qe System /c:20 /rd:true /f:text                # newest 20 System events as text
```

Use `-FilterHashtable` rather than `Where-Object`. The filter runs in the event log service and is much faster on large logs.

Levels: `1` Critical, `2` Error, `3` Warning, `4` Information, `5` Verbose.

Remote query: `Get-WinEvent -ComputerName <host> -FilterHashtable @{...}` uses RPC, not WinRM, and needs the Remote Event Log Management firewall rule. Inside a WinRM session, query locally instead.

### Event IDs worth knowing

| Log | ID | Meaning |
| --- | --- | --- |
| System | 41 (Kernel-Power) | Rebooted without a clean shutdown |
| System | 1074 (User32) | Shutdown or restart initiated by a process or user; message names which |
| System | 6005, 6006 | Event log service started, stopped (boot and clean shutdown markers) |
| System | 6008 | Previous shutdown was unexpected |
| System | 19, 20, 43 (WindowsUpdateClient) | Update installed, install failed, install started |
| System | 1014 (DNS Client Events) | Name resolution timed out |
| System | 5719 (NETLOGON) | No domain controller available for a secure session |
| Security | 4624 | Successful logon (check `Logon Type`) |
| Security | 4625 | Failed logon (check `Status` and `Sub Status`) |
| Security | 4634, 4647 | Logoff |
| Security | 4648 | Logon with explicit credentials (runas) |
| Security | 4672 | Special privileges assigned (admin logon) |
| Security | 4740 | Account locked out (on a domain controller) |
| Security | 4771 | Kerberos pre-authentication failed (on a domain controller) |
| Security | 4776 | NTLM credential validation |
| Application | 1000, 1001 | Application crash, Windows Error Reporting |
| Application | 1026 (.NET Runtime) | Unhandled .NET exception |

Logon types in 4624 and 4625: `2` interactive, `3` network (WinRM, SMB), `4` batch, `5` service, `7` unlock, `8` network cleartext, `10` remote desktop.

For 4625 status codes, see [ad-auth-certificates.md](ad-auth-certificates.md#failed-logon-status-codes).

## Unexpected reboot

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1074, 6005, 6006, 6008 } -MaxEvents 20 |
    Select-Object TimeCreated, Id, ProviderName, Message | Format-List
```

1074 with a process name such as `TrustedInstaller.exe` or `MoUsoCoreWorker.exe` means an update-driven restart. 41 without 1074 means power loss, a crash, or a hard reset; check for a dump in `C:\Windows\MEMORY.DMP` or `C:\Windows\Minidump`.

## Disk space

```powershell
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}
Get-ChildItem C:\Windows\Temp, $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore    # size of WinSxS and whether cleanup is recommended
```

```powershell
Dism.exe /Online /Cleanup-Image /StartComponentCleanup   # CHANGE: removes superseded components; cannot be undone
```

## Running commands remotely

See [winrm-remote-admin.md](winrm-remote-admin.md#remote-administration).

## Cautions

- `Get-WmiObject` is removed in PowerShell 7. Use `Get-CimInstance`.
- Security log queries need administrator rights or Event Log Readers membership.
- Event messages can contain usernames, IP addresses, and paths. Review before sharing.
