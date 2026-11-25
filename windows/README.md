# Windows

Troubleshooting references for Windows Server administration and Ansible-managed Windows hosts. Start with the [cheat sheet](cheatsheet.md).

| File | Covers |
| --- | --- |
| [cheatsheet.md](cheatsheet.md) | Quick tables for every topic below, plus an Ansible error map |
| [powershell-services-events.md](powershell-services-events.md) | PowerShell session checks, system information, processes, services, event logs and IDs, unexpected reboots, disk space |
| [networking-firewall.md](networking-firewall.md) | Addresses and routes, DNS client, connectivity tests, proxies, Windows Firewall |
| [winrm-remote-admin.md](winrm-remote-admin.md) | WinRM listeners and configuration, HTTPS listener certificates, local accounts, authentication problems, remote PowerShell |
| [updates-wsus-reboot.md](updates-wsus-reboot.md) | Update source and WSUS, missing updates, pending reboot detection, `win_updates`, HRESULTs, repair |
| [ad-auth-certificates.md](ad-auth-certificates.md) | Domain membership, users and lockouts, Kerberos and SPNs, 4625 status codes, Group Policy, certificates |

Related: [ansible/connectivity-ssh-winrm.md](../ansible/connectivity-ssh-winrm.md) for WinRM errors from the Ansible side, [api/curl-and-powershell.md](../api/curl-and-powershell.md) for `Invoke-RestMethod` and `Invoke-WebRequest`, [network/](../network/README.md) for protocol workflows.

## Conventions

- Commands are read-only unless marked `CHANGE` (modifies configuration or data) or `RESTART` (restarts a service or the host).
- Examples target Windows PowerShell 5.1, which is what Ansible Windows modules use. Commands that need PowerShell 7 say so.
- Names use `example.com` and addresses use `192.0.2.0/24`. Do not commit real hostnames, accounts, or thumbprints.
