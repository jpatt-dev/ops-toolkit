# Operations Troubleshooting Toolkit

Portable, generic troubleshooting scripts for infrastructure and automation work. Copy the script you need into a restricted environment. Nothing in this repository should identify a client, a real environment, or a real credential.

The first utility diagnoses one HTTPS REST call. Other folders are reserved for later work and do not contain scripts yet.

## Layout

```text
ops-toolkit/
├── README.md
├── .gitignore
├── api/
│   ├── Invoke-ApiDiagnostic.ps1
│   ├── README.md
│   └── tests/Invoke-ApiDiagnostic.Tests.ps1
├── ansible/
├── linux/
├── windows/
└── network/
```

| Path | Contents |
| --- | --- |
| `api/` | REST connectivity, authentication, HTTP status, and TLS failure classification |
| `ansible/` | Reserved for Ansible and Ansible Automation Platform |
| `linux/` | Reserved for Linux administration |
| `windows/` | Reserved for Windows administration |
| `network/` | Reserved for network connectivity, TLS, and certificates |

## Requirements

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
