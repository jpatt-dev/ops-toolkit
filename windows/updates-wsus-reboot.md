# Windows Update, WSUS, pending reboots, and patch failures

Windows Server 2016 through 2025. Commands are read-only unless marked `CHANGE` or `RESTART`. Run elevated.

## Where is this server getting updates?

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue |
    Select-Object WUServer, WUStatusServer, TargetGroup, TargetGroupEnabled, DoNotConnectToWindowsUpdateInternetLocations
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue |
    Select-Object UseWUServer, NoAutoUpdate, AUOptions
(New-Object -ComObject Microsoft.Update.ServiceManager).Services | Select-Object Name, IsDefaultAUService, ServiceID
netsh winhttp show proxy
```

| Value | Meaning |
| --- | --- |
| `UseWUServer = 1` and `WUServer` set | Client uses that WSUS server |
| `UseWUServer` missing or 0 | Client uses Microsoft Update or Windows Update directly |
| `TargetGroup` | Client-side targeting group name in WSUS |
| `NoAutoUpdate = 1` | Automatic updates disabled; scans still work on demand |

These keys come from Group Policy. Change the GPO, not the registry, or the next policy refresh reverts your edit.

Test the WSUS endpoint from the client:

```powershell
$wsus = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate').WUServer
$uri = [Uri]$wsus
Test-NetConnection $uri.Host -Port $uri.Port
Invoke-WebRequest -Uri "$wsus/selfupdate/wuident.cab" -Method Head -UseBasicParsing | Select-Object StatusCode
```

WSUS commonly listens on 8530 (HTTP) or 8531 (HTTPS). The port is part of `WUServer`.

## What is installed and what is missing

```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 15 HotFixID, Description, InstalledOn
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient' } -MaxEvents 30 |
    Select-Object TimeCreated, Id, Message
```

Search for applicable updates without installing (read-only, can take minutes):

```powershell
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
$result.Updates | Select-Object Title, @{n='KB';e={$_.KBArticleIDs -join ','}}, IsDownloaded, RebootRequired
```

Run that in a local or `runas` session. Over a plain WinRM network logon, the Windows Update API returns `0x80070005` (access denied). `ansible.windows.win_updates` handles this itself; your own scripts need Ansible `become`.

Recent update history:

```powershell
$s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$s.QueryHistory(0, [Math]::Min(20, $s.GetTotalHistoryCount())) |
    Select-Object Date, Title, @{n='Result';e={ @{1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'}[[int]$_.ResultCode] }}, @{n='HResult';e={ '0x{0:X8}' -f $_.HResult }}
```

## Pending reboot detection

No single flag covers every case. Check each source and report which one is set. This block only reads:

```powershell
$pending = [ordered]@{
    CBS_RebootPending      = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    WU_RebootRequired      = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    WUA_SystemInfo         = (New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
    PendingFileRename      = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    ComputerRenamePending  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName -ne
                             (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
}
[pscustomobject]$pending
```

| Source | Set by | Reliability |
| --- | --- | --- |
| CBS `RebootPending` | Servicing stack: cumulative updates, features, roles | Strong signal |
| WU `RebootRequired` | Windows Update agent after installing | Strong signal |
| `Microsoft.Update.SystemInfo.RebootRequired` | Windows Update agent | Strong signal; matches WU state |
| `PendingFileRenameOperations` | Any installer that replaces in-use files, including antivirus and drivers | Noisy. Often set by non-patch software and sometimes never cleared. Report it separately; do not treat it alone as a patch reboot. |
| Computer rename | Rename not yet applied | Strong signal |
| Configuration Manager client | SCCM/MECM deployments | Query `root\ccm\ClientSDK` `CCM_ClientUtilities.DetermineIfRebootPending` when the client is installed |

In Ansible, `ansible.windows.win_updates` returns `reboot_required` for the updates it installed. Use your own probe when you need the state before patching or after other software installs.

## Installing updates with Ansible

```yaml
- name: Search only (no changes)
  ansible.windows.win_updates:
    category_names:
      - SecurityUpdates
      - CriticalUpdates
    state: searched
  register: search

# CHANGE: installs updates and may reboot the host.
- name: Install, reboot if needed
  ansible.windows.win_updates:
    category_names:
      - SecurityUpdates
      - CriticalUpdates
    state: installed
    reboot: true
    reboot_timeout: 3600
  register: install
```

Useful return values: `found_update_count`, `installed_update_count`, `failed_update_count`, `reboot_required`, and `updates` (per-update detail, including failure HRESULTs). Check `ansible-doc ansible.windows.win_updates` for your installed version's options, such as `accept_list`, `reject_list`, `server_selection`, and `skip_optional`.

## Patch installation failures

### Where to look

| Source | Command or path |
| --- | --- |
| Update client events | System log, provider `Microsoft-Windows-WindowsUpdateClient` (19 success, 20 failure, 43 started) |
| Update operational log | `Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 50` |
| Windows Update log | `Get-WindowsUpdateLog -LogPath C:\Temp\WindowsUpdate.log` (`CHANGE`: writes a file; converts ETL traces on 2016+) |
| Servicing (CBS) log | `C:\Windows\Logs\CBS\CBS.log` |
| DISM log | `C:\Windows\Logs\DISM\dism.log` |
| Setup events | `Get-WinEvent -LogName Setup -MaxEvents 30` |

### Common HRESULTs

| Code | Meaning | First check |
| --- | --- | --- |
| `0x80070005` | Access denied | Running over WinRM without `become`; antivirus blocking |
| `0x8024402C` | Proxy or server name could not be resolved | DNS for WSUS host; WinHTTP proxy |
| `0x80072EE2` | Connection timed out | Firewall and proxy to WSUS or Microsoft Update |
| `0x80072F8F` | TLS or certificate error, often clock skew | System time; WSUS certificate trust |
| `0x80244019` | Server returned 404 | `WUServer` URL wrong, or WSUS IIS site problem |
| `0x80244022` | Server returned 503 | WSUS application pool stopped or overloaded |
| `0x80240017` | Update not applicable to this system | Wrong update for this OS or build |
| `0x8024001E` | Operation did not complete because the service or system was shutting down | Reboot in progress; retry after restart |
| `0x800F081F` | Source files not found | Component store repair needed; see below |
| `0x800F0922` | Install failed, often reserved partition or servicing stack | CBS.log; free space on system and reserved partitions |
| `0x80073712` | Component store corrupt | DISM repair |
| `0x80070643` | Fatal error during installation (often .NET or Defender) | Product-specific setup logs |

### Repair sequence

Each step is a `CHANGE`. Run them in a maintenance window.

```powershell
Dism.exe /Online /Cleanup-Image /ScanHealth          # read-only scan; can take a long time
Dism.exe /Online /Cleanup-Image /RestoreHealth       # CHANGE: repairs the component store (needs a source if offline)
sfc.exe /scannow                                     # CHANGE: repairs protected system files
```

Resetting the Windows Update cache (`CHANGE`, `RESTART`) is a last resort: stop `wuauserv` and `bits`, rename `C:\Windows\SoftwareDistribution`, start the services. It discards update history shown in the UI and forces a full rescan.

### Stuck or slow installs

- `TrustedInstaller` running for a long time after a cumulative update is normal on older servers. Watch CPU and `CBS.log` growth before acting.
- Low disk space on `C:` makes installs fail late. Keep several GB free.
- A pending reboot from a previous update blocks new servicing operations. Reboot first.
- Antivirus scanning `SoftwareDistribution` and `WinSxS` slows installs. Follow the vendor's exclusion guidance.

## Cautions

- Do not clear `PendingFileRenameOperations` by hand to avoid a reboot. The pending operations then never run.
- `Restart-Computer` (`RESTART`) on a remote server ends your session. In Ansible, use `ansible.windows.win_reboot`, which waits for the host to return.
- Changing WSUS policy keys locally is overwritten by Group Policy.
