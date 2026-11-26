# API troubleshooting

REST API references and a single-file PowerShell diagnostic. Start with the [cheat sheet](cheatsheet.md).

| File | Covers |
| --- | --- |
| [cheatsheet.md](cheatsheet.md) | First checks, status-to-action table, curl, PowerShell, JSON, tokens, ServiceNow quick reference |
| [rest-http-fundamentals.md](rest-http-fundamentals.md) | Request and response anatomy, HTTP methods, status codes, headers, JSON payload troubleshooting |
| [authentication.md](authentication.md) | Basic authentication, bearer tokens and API keys, JWT claims, OAuth 2.0 grants and errors, mutual TLS |
| [curl-and-powershell.md](curl-and-powershell.md) | curl, `Invoke-RestMethod`, `Invoke-WebRequest`, reading errors, encoding, TLS validation, proxies, response checklist |
| [http-error-troubleshooting.md](http-error-troubleshooting.md) | 400, 401, 403, 404, 409, 429, and 5xx: causes and checks from Linux and PowerShell |
| [servicenow-rest-concepts.md](servicenow-rest-concepts.md) | ServiceNow Table API, dedicated APIs, Change Management API, CMDB and CI relationships, Import Set API, error reference |
| [recipes/servicenow.md](recipes/servicenow.md) | Copy-and-paste PowerShell tests for ServiceNow Change Management |
| [Invoke-ApiDiagnostic.ps1](Invoke-ApiDiagnostic.ps1) | Sanitized single-request diagnostic. Documented below. |

Related: [network/workflows.md](../network/workflows.md) for connectivity, [ansible/servicenow-integration.md](../ansible/servicenow-integration.md) for ServiceNow from AAP.

## REST API diagnostic

`Invoke-ApiDiagnostic.ps1` is a single-file PowerShell utility for one HTTPS request. It runs on Windows PowerShell 5.1 and PowerShell 7 with no extra modules.

Copy this file into a restricted environment. Do not add client hostnames, accounts, tokens, or payloads to it.

### What it does

The script sends one request and prints a report. It separates:

- HTTP responses, including 400, 401, and 403
- DNS failures
- TCP connection failures
- TLS and certificate failures
- Timeouts

GET is the default. POST is sent only when `-AllowWrite` is set and the request is confirmed with `-ConfirmPost` or by typing `POST` at the prompt. The script does not retry a POST. For POST, it does not follow redirects, because a redirect could submit the body again.

These three POST forms are not treated as the same request:

| Form | Parameters | Body that is sent |
| --- | --- | --- |
| No body | `-Method POST` | Nothing |
| Empty JSON | `-Method POST -EmptyJson` | `{}` |
| JSON payload | `-Method POST -Body '<json>'` | The text you supplied, after it parses as JSON |

The report's `Request Body` line says `Not supplied`, `Empty JSON`, or `JSON`.

### Security

- Credentials are not hardcoded, stored, or printed. Basic authentication uses `-UseBasicAuth` and `Get-Credential`, or a `PSCredential` you already created in the session.
- Passing `-Credential` without `-UseBasicAuth` does not send the request.
- Authorization and cookie headers are refused on input and redacted if a server returns them.
- The raw request and response are not written to disk.
- Query parameters that look like tokens, and secret values echoed by an error message, are redacted. If a value cannot be redacted safely, it is omitted.
- Certificate validation is not disabled. On Windows PowerShell, the process is set to TLS 1.2 or TLS 1.3 for the duration of the call, then the previous protocol setting is restored. That does not bypass certificate checks.
- JSON bodies larger than 256 KB are refused.
- Keep client-specific URLs and payload files outside the repository. See the root `.gitignore`.

### Examples

Run from a PowerShell prompt. The placeholder host below is not a real API.

```powershell
# GET with Basic authentication.
.\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/status -UseBasicAuth

# GET with a non-secret header.
.\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/status `
    -Headers @{ Accept = 'application/json'; 'X-Request-Id' = 'example-request' }

# POST with no body.
.\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost

# POST with {}.
.\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -EmptyJson `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost

# POST with a JSON payload.
.\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -Body '{"action":"validate","id":"example"}' `
    -UseBasicAuth `
    -AllowWrite `
    -ConfirmPost
```

Use a credential that is already in the session when you do not want a prompt:

```powershell
$credential = Get-Credential
.\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/status -UseBasicAuth -Credential $credential
```

For a payload file that lives outside this repository:

```powershell
$payload = Get-Content -Raw -Path C:\Temp\example-payload.json
.\Invoke-ApiDiagnostic.ps1 `
    -Uri https://api.example.com/v1/jobs `
    -Method POST `
    -Body $payload `
    -UseBasicAuth `
    -Credential $credential `
    -AllowWrite `
    -ConfirmPost
```

`-ConfirmPost` is the explicit confirmation. Leave it off to be prompted. Type `POST` to send. Any other response cancels the request before credentials are used and before any POST is sent.

### Reading the report

A completed HTTP call looks like this:

```text
API Diagnostic
----------------------------

Endpoint: https://api.example.com/v1/jobs
Method: POST
Authentication: Basic
Request Body: Empty JSON
Request Content Type: application/json; charset=utf-8
HTTP Status: 400
Content Type: application/json

Error:
Category: Bad Request
Message: name is required

Hint: Compare a POST with no body, a POST with {}, and a POST with the documented JSON payload. These requests are not equivalent.

Request completed.
No automatic retry performed.
```

The message is taken from a small set of JSON fields such as `message`, `detail`, and `error`. The rest of the body is not printed. Sensitive header values are shown as `[REDACTED]`.

#### HTTP 400

The server parsed the request and rejected it. Compare the three POST forms above, and compare the `Request Content Type` line. Do not assume an omitted body and `{}` produce the same result. The script does not retry.

#### HTTP 401

Category `Unauthorized` means authentication was rejected. Confirm the account and that this endpoint expects Basic authentication. The script will not print the password. A 401 is not a TLS failure.

#### HTTP 403

Category `Forbidden` means the server refused an authenticated request, often because of authorization rather than a bad password. Compare the account's permissions with the operation you sent. Changing the JSON body will not fix a permission denial.

#### TLS, DNS, and connection failures

These reports have `HTTP Status: Not available` because the server did not return an HTTP response.

| Category | Meaning |
| --- | --- |
| DNS | The hostname was not resolved |
| Connection | TCP failed. Check routing, firewalls, proxies, and port 443 |
| TLS | The handshake or certificate check failed. Validation was not disabled |
| Timeout | The server or a proxy did not answer. The request was not retried |

A certificate error stays a TLS error. Do not bypass validation to make the call succeed. Fix the trust chain, hostname, or protocol instead.

### Recipes

[ServiceNow](recipes/servicenow.md) is a copy-and-paste guide for an open PowerShell window. It does not require this script. `Invoke-ApiDiagnostic.ps1` is an optional single-file alternative.

### Disconnected use

This folder is self-contained. Copy `Invoke-ApiDiagnostic.ps1`. Copy this README or a recipe if you want the examples offline. No module installation is required. If Windows blocks the copied script, run `Unblock-File .\Invoke-ApiDiagnostic.ps1`. If execution policy blocks it, start one process with `-ExecutionPolicy Bypass`. Neither action disables certificate checks.

### Offline tests

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\api\tests\Invoke-ApiDiagnostic.Tests.ps1
```

The tests replace the web cmdlet and simulate status codes and connection failures. They do not contact an API.
