# ServiceNow API troubleshooting

Use `Invoke-ApiDiagnostic.ps1` to troubleshoot the ServiceNow Change Management API. This recipe does not replace the script and does not add a second client.

The examples use `https://instance.example.com` and `example-template-id`. Replace those placeholders in your PowerShell session. Do not write a real instance URL, template id, sys_id, username, or captured response into this repository.

The operation under test is:

```text
POST /api/sn_chg_rest/change/standard/{template_id}
```

Run the commands from a PowerShell session in the directory that contains `Invoke-ApiDiagnostic.ps1`. A POST is sent only when `-AllowWrite` is set and you also pass `-ConfirmPost` or type `POST` at the prompt. The script sends that POST once and does not follow a redirect.

## Transfer the script

The script is one file. It does not need this recipe, a module, an install, or administrative rights.

1. Copy `Invoke-ApiDiagnostic.ps1` into the restricted environment. Copy this file too if you want the steps offline.
2. Do not copy `.git`, `.env`, credential files, logs, or saved responses.
3. If Windows marks the copy as downloaded, run `Unblock-File .\Invoke-ApiDiagnostic.ps1`. That only removes the mark of the web.
4. If execution policy blocks the file, start one process with `-ExecutionPolicy Bypass`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ApiDiagnostic.ps1 -Uri https://instance.example.com/api/now/table/change_request?sysparm_limit=1
```

5. For the commands below, open PowerShell and run the script by name so that `-Headers` and `-Body` are evaluated in the session. Keep client payloads outside the repository.

Windows PowerShell 5.1 and PowerShell 7 can both run the file. On Windows PowerShell, the script asks for TLS 1.2 or TLS 1.3 for the duration of the call and then restores the previous setting. It does not disable certificate validation.

## 1. Test connectivity with a read-only GET

Start with a GET. The default method is GET, so a failed or successful read does not create a change.

```powershell
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/now/table/change_request?sysparm_limit=1&sysparm_fields=number' `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth
```

`Get-Credential` prompts for the ServiceNow user and password. The password is not printed or saved.

| Result | What it tells you |
| --- | --- |
| HTTP 200 | DNS, TCP, TLS, and Basic authentication worked. The response body is not displayed. |
| HTTP 401 | The account or password was rejected, or Basic authentication is not being accepted. |
| HTTP 403 | The account authenticated, but it cannot read this table. |
| DNS, Connection, or TLS | The request never received an HTTP status. This is not a change-template problem. |

The report's `HTTP Status` line is `Not available` when the failure is DNS, connection, TLS, or a timeout.

## 2. Authenticate with Basic authentication

Pass `-UseBasicAuth` on every call that should log in. To reuse one prompt:

```powershell
$credential = Get-Credential
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/now/table/change_request?sysparm_limit=1&sysparm_fields=number' `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth `
    -Credential $credential
```

A credential passed without `-UseBasicAuth` is refused and no request is sent. Do not put the user name or password in the URI. Do not pass `Authorization`, `Cookie`, or an API-key header. The script rejects those header names so the secret is not stored in the command line.

## 3. POST with no request body

This call omits the body. It is not the same request as a POST of `{}`.

```powershell
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/sn_chg_rest/change/standard/example-template-id' `
    -Method POST `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth `
    -Credential $credential `
    -AllowWrite `
    -ConfirmPost
```

The report should show `Request Body: Not supplied` and `Request Content Type: Not set`.

## 4. POST with `{}`

```powershell
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/sn_chg_rest/change/standard/example-template-id' `
    -Method POST `
    -EmptyJson `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth `
    -Credential $credential `
    -AllowWrite `
    -ConfirmPost
```

The report should show `Request Body: Empty JSON` and a JSON request content type. The bytes sent are exactly `{}`.

## 5. POST with a JSON payload

Supply the JSON yourself. This example uses a placeholder description, not a client payload.

```powershell
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/sn_chg_rest/change/standard/example-template-id' `
    -Method POST `
    -Body '{"short_description":"Example standard change"}' `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth `
    -Credential $credential `
    -AllowWrite `
    -ConfirmPost
```

The report should show `Request Body: JSON`. The script parses the text to confirm it is JSON, then sends that text unchanged. `-Body` and `-EmptyJson` together are rejected and nothing is sent.

For a payload file that lives outside this repository:

```powershell
$payload = Get-Content -Raw -Path C:\Temp\example-change.json
.\Invoke-ApiDiagnostic.ps1 `
    -Uri 'https://instance.example.com/api/sn_chg_rest/change/standard/example-template-id' `
    -Method POST `
    -Body $payload `
    -Headers @{ Accept = 'application/json' } `
    -UseBasicAuth `
    -Credential $credential `
    -AllowWrite `
    -ConfirmPost
```

## 6. Read HTTP 400, 401, 403, 404, and 405

Use the `Category` and `Message` lines together. Do not decide the cause from the status code alone. An unknown template id is reported as HTTP 400 by some releases and as HTTP 404 by others. The sanitized message distinguishes those cases.

| Status | Category | Likely meaning for this API | Next comparison |
| --- | --- | --- | --- |
| 400 | Bad Request | The request reached Change Management and failed validation. Typical causes are a missing field, a body the API does not accept, or a template id the API rejects as invalid input. | Compare no body, `{}`, and the JSON payload. Read `message` and `detail`. |
| 401 | Unauthorized | Authentication failed. The body was not the cause. | Repeat the read-only GET with the same credential. |
| 403 | Forbidden | The account authenticated, but it is not allowed to create this change. Changing the JSON will not grant the role or ACL. | Compare with the GET. A GET of 200 and a POST of 403 points at authorization for the write. |
| 404 | Not Found | The path, API, or template resource was not found. | Check the path and the template id placeholder. Then compare the message with a 400 from the same URL. |
| 405 | Method Not Allowed | That URL does not allow the method you sent. The standard-change action is a POST. A GET to that same path can return 405 even when the host and account are valid. | Use the read-only GET for connectivity, and POST only for the change action. |

DNS, connection, and TLS failures still have no HTTP status. Fix those before treating the template or the JSON as the problem.

## 7. Sanitized error details

On an HTTP error, the script looks for a short message and, when present, a short detail. It understands JSON fields named `message`, `error_message`, `detail`, and `error`, including an error nested under `result`. It also reads those element names from a simple XML error document. ServiceNow uses both shapes. Sending `Accept: application/json` keeps the response in JSON. Without that header, ServiceNow often returns XML. The same message and detail are still extracted from a simple XML body.

The rest of the body is not printed. Authorization headers, cookies, tokens, and long hexadecimal identifiers are redacted. A detail longer than 400 characters is not appended. If the text cannot be sanitized, including XML that contains a DTD or embedded markup, the report keeps the HTTP status and omits the body.

Copy the `Message` line into your notes only after you review it. Do not save the raw response, and do not commit either one to this repository.

## 8. Compare the three POST formats

Send the three POST commands to the same URL with the same account, and change only the body. Leave `-AllowWrite` and `-ConfirmPost` in place. Each command makes one attempt.

| Report line | No body | `{}` | JSON payload |
| --- | --- | --- | --- |
| Request Body | Not supplied | Empty JSON | JSON |
| Request Content Type | Not set, unless you set one | `application/json; charset=utf-8` | `application/json; charset=utf-8` |

If all three return the same 401 or 403, stop changing the JSON and fix authentication or authorization. If only one body returns 400, or the `detail` text names a field, the failure is in that body. If the message names the template and every body returns the same 400 or 404, check the template id and the path before editing the payload.
