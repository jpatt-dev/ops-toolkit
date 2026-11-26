# Operations Troubleshooting Toolkit

A practical troubleshooting and cheat-sheet library for enterprise operations: Ansible and Ansible Automation Platform, RHEL, Windows Server, networking, and REST APIs including ServiceNow. It also contains portable diagnostic scripts you can copy into a restricted environment.

Nothing in this repository should identify a client, a real environment, or a real credential. Examples use `example.com` names, documentation address ranges such as `192.0.2.0/24`, and placeholders such as `<sys_id>`.

## Start here

| Situation | Go to |
| --- | --- |
| On a call, need a command now | The cheat sheet for the area: [ansible](ansible/cheatsheet.md), [linux](linux/cheatsheet.md), [windows](windows/cheatsheet.md), [network](network/cheatsheet.md), [api](api/cheatsheet.md) |
| An AAP job failed | [ansible/cheatsheet.md](ansible/cheatsheet.md#first-five-minutes-on-a-failing-job) |
| Something cannot reach an endpoint | [network/workflows.md](network/workflows.md) |
| Got an HTTP error code | [api/http-error-troubleshooting.md](api/http-error-troubleshooting.md) |
| Ansible cannot connect to a Windows host | [ansible/connectivity-ssh-winrm.md](ansible/connectivity-ssh-winrm.md#windows-and-winrm), then [windows/winrm-remote-admin.md](windows/winrm-remote-admin.md) |
| Patching problems | [windows/updates-wsus-reboot.md](windows/updates-wsus-reboot.md), [linux/packages-dnf-rpm.md](linux/packages-dnf-rpm.md) |
| A RHEL host misbehaves | [linux/rhel-scenarios.md](linux/rhel-scenarios.md) |
| A TLS or certificate error | [network/tls-openssl.md](network/tls-openssl.md) |
| ServiceNow integration | [ansible/servicenow-integration.md](ansible/servicenow-integration.md), [api/servicenow-rest-concepts.md](api/servicenow-rest-concepts.md) |

## Index

### ansible/

| File | Covers |
| --- | --- |
| [README.md](ansible/README.md) | Index and the ServiceNow API diagnostic job documentation |
| [cheatsheet.md](ansible/cheatsheet.md) | Quick reference and error-message map |
| [cli-config-debugging.md](ansible/cli-config-debugging.md) | CLI, `ansible.cfg`, pre-flight checks, verbosity, check mode, debugger |
| [inventory-and-variables.md](ansible/inventory-and-variables.md) | Inventory, host patterns, AAP inventory sources, variable precedence |
| [collections-and-execution-environments.md](ansible/collections-and-execution-environments.md) | Collections, EEs, `ansible-builder`, `ansible-navigator`, registry auth, image pulls, internal CAs |
| [aap-platform-and-controller.md](ansible/aap-platform-and-controller.md) | AAP 2.6/2.7 architecture, gateway API, job states, templates, surveys, credentials, project sync |
| [connectivity-ssh-winrm.md](ansible/connectivity-ssh-winrm.md) | SSH and WinRM failures, privilege escalation, Kerberos, PSRP |
| [common-failures.md](ansible/common-failures.md) | YAML, Jinja2, module, and partial-failure messages |
| [servicenow-integration.md](ansible/servicenow-integration.md) | `servicenow.itsm`, change lifecycle, CMDB inventory |
| [servicenow_api_diagnostic.yml](ansible/servicenow_api_diagnostic.yml) | AAP job that checks ServiceNow API access |

### linux/

| File | Covers |
| --- | --- |
| [README.md](linux/README.md) | Index |
| [cheatsheet.md](linux/cheatsheet.md) | Quick reference |
| [rhel-scenarios.md](linux/rhel-scenarios.md) | Step-by-step workflows for common RHEL problems |
| [rhel-snapshot.sh](linux/rhel-snapshot.sh) | Read-only health snapshot |
| [system-files-users.md](linux/system-files-users.md) | System info, files, permissions, users and groups |
| [systemd-journal.md](linux/systemd-journal.md) | Services and logs |
| [networking-dns-firewalld.md](linux/networking-dns-firewalld.md) | Interfaces, routes, NetworkManager, DNS, firewalld |
| [selinux.md](linux/selinux.md) | SELinux denials and fixes |
| [packages-dnf-rpm.md](linux/packages-dnf-rpm.md) | DNF, RPM, repositories, errata |
| [storage-lvm.md](linux/storage-lvm.md) | Disk space, LVM, mounts, filesystems |
| [performance-processes.md](linux/performance-processes.md) | CPU, memory, I/O, processes |
| [ssh-tls-certificates.md](linux/ssh-tls-certificates.md) | sshd, trust store, certificates, crypto policies |
| [podman.md](linux/podman.md) | Podman and containers |

### windows/

| File | Covers |
| --- | --- |
| [README.md](windows/README.md) | Index |
| [cheatsheet.md](windows/cheatsheet.md) | Quick reference and Ansible error map |
| [powershell-services-events.md](windows/powershell-services-events.md) | PowerShell, system info, services, event logs |
| [networking-firewall.md](windows/networking-firewall.md) | Networking, DNS, proxies, Windows Firewall |
| [winrm-remote-admin.md](windows/winrm-remote-admin.md) | WinRM listeners, auth, certificates, remote administration |
| [updates-wsus-reboot.md](windows/updates-wsus-reboot.md) | Windows Update, WSUS, pending reboot, patch failures |
| [ad-auth-certificates.md](windows/ad-auth-certificates.md) | Active Directory, Kerberos, logon failures, certificates |

### network/

| File | Covers |
| --- | --- |
| [README.md](network/README.md) | Index |
| [cheatsheet.md](network/cheatsheet.md) | Quick reference |
| [workflows.md](network/workflows.md) | API unreachable, DNS OK but connect fails, refused vs timeout, TLS failures, auth vs connectivity |
| [check-endpoint.sh](network/check-endpoint.sh) | Read-only DNS, TCP, TLS, and HTTP check for one endpoint |
| [fundamentals.md](network/fundamentals.md) | TCP/IP, TCP vs UDP, ports, routing, firewalls, MTU |
| [dns.md](network/dns.md) | dig, nslookup, Resolve-DnsName |
| [connectivity-testing.md](network/connectivity-testing.md) | TCP tests, curl, traceroute, mtr |
| [tls-openssl.md](network/tls-openssl.md) | OpenSSL, verify codes, certificate files, handshake failures |
| [lb-proxy-vpn.md](network/lb-proxy-vpn.md) | Load balancers, HAProxy, proxies, VPNs |
| [performance-packet-capture.md](network/performance-packet-capture.md) | Latency, throughput, MTU, packet captures |

### api/

| File | Covers |
| --- | --- |
| [README.md](api/README.md) | Index and `Invoke-ApiDiagnostic.ps1` documentation |
| [cheatsheet.md](api/cheatsheet.md) | Quick reference |
| [rest-http-fundamentals.md](api/rest-http-fundamentals.md) | Methods, status codes, headers, JSON payloads |
| [authentication.md](api/authentication.md) | Basic, tokens, OAuth 2.0, mutual TLS |
| [curl-and-powershell.md](api/curl-and-powershell.md) | curl, `Invoke-RestMethod`, `Invoke-WebRequest`, TLS validation |
| [http-error-troubleshooting.md](api/http-error-troubleshooting.md) | 400, 401, 403, 404, 409, 429, 5xx |
| [servicenow-rest-concepts.md](api/servicenow-rest-concepts.md) | ServiceNow Table, Change, CMDB, and Import Set APIs |
| [recipes/servicenow.md](api/recipes/servicenow.md) | PowerShell ServiceNow Change Management tests |
| [Invoke-ApiDiagnostic.ps1](api/Invoke-ApiDiagnostic.ps1) | Sanitized single-request diagnostic, with [offline tests](api/tests/Invoke-ApiDiagnostic.Tests.ps1) |

## Conventions

- Commands are read-only unless labeled `CHANGE` (modifies configuration or data) or `RESTART` (restarts or reloads a service or host). Run read-only checks first.
- Certificate validation stays on. Commands that disable it (`curl -k`, `validate_certs: false`, `-SkipCertificateCheck`) appear only in warnings, never as the fix.
- Commands that take credentials prompt for them or read them from a file or credential store. None take a password on the command line.
- Each topic lives in one place. Guides link to each other rather than repeating content.

## Scripts

| Script | Platform | Changes anything? |
| --- | --- | --- |
| [api/Invoke-ApiDiagnostic.ps1](api/Invoke-ApiDiagnostic.ps1) | Windows PowerShell 5.1, PowerShell 7 | GET by default; POST only with `-AllowWrite` and confirmation |
| [ansible/servicenow_api_diagnostic.yml](ansible/servicenow_api_diagnostic.yml) | AAP 2.7 job | GET by default; POST only with explicit confirmation |
| [linux/rhel-snapshot.sh](linux/rhel-snapshot.sh) | RHEL 8, 9, 10 | No |
| [network/check-endpoint.sh](network/check-endpoint.sh) | Linux with bash, openssl, curl | No; one unauthenticated GET |

## Layout

```text
ops-toolkit/
├── README.md
├── .gitignore
├── .markdownlint.json
├── ansible/      Ansible, AAP, EEs, ServiceNow from Ansible
├── api/          REST, HTTP, auth, ServiceNow APIs, PowerShell diagnostic
│   ├── recipes/
│   └── tests/
├── linux/        RHEL administration and troubleshooting
├── network/      DNS, TCP, TLS, proxies, load balancers, captures
└── windows/      Windows Server, WinRM, updates, AD, certificates
```

## Validation

Documentation is checked with `markdownlint` using `.markdownlint.json` (line length is not enforced). Shell scripts are checked with `bash -n` and exercised against local test servers. The PowerShell diagnostic has offline tests; see [Offline tests](#offline-tests).

## Requirements for the PowerShell diagnostic

- Windows PowerShell 5.1 or PowerShell 7
- No extra modules, no package install, and no administrative rights
- No network access while loading the script

Certificate validation is left at the process default. The script does not turn it off.

## Keep client data out of this repository

Client URLs, usernames, tokens, payloads, exports, and local settings stay outside the repository. Do not add them to a script, a README, or a commit. The `.gitignore` file excludes credential files, `.env` files, local configuration, captured HTTP traffic, private JSON payloads, logs, transcripts, and temporary files. Ignoring a file is not a substitute for keeping that file out of the working tree.

Do not redirect diagnostic output into this repository. If you save a report, put it in a location your client already approves for troubleshooting notes, and review it first.

## REST API diagnostic

`api/Invoke-ApiDiagnostic.ps1` sends one GET or one POST and prints a sanitized report. It does not save the raw request or response.

- GET is the default.
- POST requires `-AllowWrite`.
- POST also requires `-ConfirmPost`, or you must type `POST` when prompted.
- A POST is not retried. Redirects are not followed for POST, so the body is not submitted again.
- Basic authentication uses `Get-Credential` or a `PSCredential` already in the session. The password is not printed.
- Authorization, cookie, and other secret-bearing request headers are refused. Use `-UseBasicAuth` for Basic authentication.
- A POST with no body, a POST of `{}`, and a POST of a JSON payload are different requests. The report names which one was sent.

Run these examples from a PowerShell session so that `-Body (Get-Content ...)` is evaluated by PowerShell. Do not put secrets in a saved command file.

```powershell
# GET with Basic authentication. Get-Credential prompts and does not save the password.
.\api\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/status -UseBasicAuth

# POST with no request body.
.\api\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost

# POST with exactly {}.
.\api\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -EmptyJson `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost

# POST with a JSON payload.
.\api\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -Body '{"action":"validate","id":"example"}' `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost
```

Omit `-ConfirmPost` to confirm interactively. The POST is sent only when you type `POST`.

More detail, including HTTP 400, 401, 403, and TLS interpretation, is in [api/README.md](api/README.md). A ServiceNow Change Management walkthrough is in [api/recipes/servicenow.md](api/recipes/servicenow.md).

## Copying into a disconnected environment

1. Copy `api/Invoke-ApiDiagnostic.ps1`. Copy `api/README.md` as well if you want the examples offline.
2. Use the file transfer your client already allows. The script does not download modules or contact source control.
3. Leave `.git`, `.env`, credential files, logs, captures, and client payloads behind.
4. If Windows marks the file as downloaded, unblock that copy. This removes the mark of the web. It does not change TLS validation.

   ```powershell
   Unblock-File .\Invoke-ApiDiagnostic.ps1
   ```

5. If execution policy blocks the file, bypass policy for that process only:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/status
   ```

6. Run it as a normal user. No install step is required, and loading the file does not send a request.

## Offline tests

The tests simulate HTTP results in-process. They do not call a live API.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\api\tests\Invoke-ApiDiagnostic.Tests.ps1
```

PowerShell 7 can run the same file with `pwsh -NoProfile -File .\api\tests\Invoke-ApiDiagnostic.Tests.ps1`.
