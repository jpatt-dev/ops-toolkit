# API troubleshooting cheat sheet

GET examples are read-only. Anything that writes is marked `CHANGE`. Credentials come from a prompt (`-u "$API_USER"` makes curl ask for the password; `Get-Credential` in PowerShell).

## First checks

| Step | Linux | PowerShell | What to look for |
| --- | --- | --- | --- |
| Network and TLS | `./network/check-endpoint.sh <host>` | `Test-NetConnection <host> -Port 443` | All layers pass |
| Status only | `curl -sS -o /dev/null -w '%{http_code}\n' <url>` | `(Invoke-WebRequest <url> -UseBasicParsing).StatusCode` | Any HTTP code = network OK |
| Status + headers + body | `curl -sS -i <url>` | try/catch with `$_.ErrorDetails.Message` | Who answered; error message |
| Sanitized report | | `.\api\Invoke-ApiDiagnostic.ps1 -Uri <url> -UseBasicAuth` | Category and message |
| Timings | `curl -sS -o /dev/null -w 'dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer}\n' <url>` | `Measure-Command { Invoke-WebRequest <url> -UseBasicParsing }` | Which phase is slow |

## Status code to action

| Code | Means | First action |
| --- | --- | --- |
| none | DNS, TCP, TLS, or timeout | [network/workflows.md](../network/workflows.md) |
| 400 | Bad request content | Read the message; validate JSON; minimal body |
| 401 | Not authenticated | Credentials, token expiry, `WWW-Authenticate` |
| 403 | Not allowed | Roles, ACLs, scopes, IP allow-list, WAF |
| 404 | Not found or hidden | Path, version, ID, permissions |
| 405 | Wrong method | API docs |
| 407 | Proxy wants credentials | Proxy settings |
| 409 | Conflict | Already exists? Re-read and retry with new version |
| 415 | Wrong content type | `Content-Type: application/json` |
| 429 | Rate limited | `Retry-After`; reduce concurrency |
| 500 | Server error | Request ID to the API owner |
| 502/503/504 | Gateway or backend | Who answered; backend health |

Details: [http-error-troubleshooting.md](http-error-troubleshooting.md).

## curl

| Goal | Command |
| --- | --- |
| GET JSON | `curl -sS -H 'Accept: application/json' -u "$API_USER" <url> \| jq .` |
| Headers only | `curl -sS -D - -o /dev/null <url>` |
| Body + status | `curl -sS -w '\nHTTP %{http_code}\n' <url>` |
| Fail on 4xx/5xx, keep body | `curl -sS --fail-with-body <url>` (7.76+) |
| Token from file | `curl -sS -H @auth-header.txt <url>` |
| Encode a query value | `curl -G --data-urlencode 'sysparm_query=active=true' <url>` |
| `CHANGE` POST JSON file | `curl -sS -X POST -H 'Content-Type: application/json' -u "$API_USER" --data @body.json <url>` |
| Trust a CA | `--cacert ca.pem` |
| Through a proxy | `-x http://proxy:8080` |

## PowerShell

| Goal | Command |
| --- | --- |
| GET objects | `Invoke-RestMethod <url> -Credential $cred -Headers @{Accept='application/json'}` |
| Status and headers | `$r = Invoke-WebRequest <url> -UseBasicParsing; $r.StatusCode; $r.Headers` |
| Error body (5.1) | `catch { [int]$_.Exception.Response.StatusCode; $_.ErrorDetails.Message }` |
| Error body (7) | `Invoke-WebRequest <url> -SkipHttpErrorCheck` |
| Basic auth now (7) | `-Authentication Basic -Credential $cred` |
| Bearer (7) | `-Authentication Bearer -Token (Read-Host -AsSecureString)` |
| JSON body | `$body = $obj \| ConvertTo-Json -Depth 10` |
| UTF-8 body (5.1) | `-Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'` |
| TLS 1.2 (5.1 session) | `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` |
| `CHANGE` POST | `Invoke-RestMethod -Method Post <url> -Credential $cred -ContentType 'application/json' -Body $body` |

## JSON

| Goal | Command |
| --- | --- |
| Validate | `jq . file.json` / `Get-Content -Raw file.json \| ConvertFrom-Json` |
| Top-level keys | `jq 'keys' file.json` |
| Required field present | `jq -e '.field' file.json` (exit 1 if missing or null) |
| Compact for comparison | `jq -cS . a.json; jq -cS . b.json` |

## Tokens

| Goal | Command |
| --- | --- |
| Read JWT claims | see [authentication.md](authentication.md#jwt-tokens) |
| Token expiry | `date -d @<exp>` |
| OAuth token request result without printing the token | `... \| jq '{token_type, expires_in, scope, error, error_description}'` |

## ServiceNow

| Goal | Request |
| --- | --- |
| Auth and read check | `GET /api/now/table/change_request?sysparm_limit=1&sysparm_fields=number` |
| Query safely | Always `sysparm_fields`, `sysparm_limit`; verify field names first |
| Display values | `sysparm_display_value=true` (or `all`) |
| One record | `GET /api/now/table/<table>/<sys_id>` (404 = missing or no read access) |
| List changes via Change API | `GET /api/sn_chg_rest/change?sysparm_query=...` |
| `CHANGE` Standard change | `POST /api/sn_chg_rest/change/standard/<template_sys_id>` |
| CI with relations | `GET /api/now/cmdb/instance/<class>/<sys_id>` |
| Affected CIs of a change | `GET /api/now/table/task_ci?sysparm_query=task=<change_sys_id>` |
| `CHANGE` Import one row | `POST /api/now/import/<staging_table>` (synchronous transform) |

Details: [servicenow-rest-concepts.md](servicenow-rest-concepts.md). PowerShell walkthrough: [recipes/servicenow.md](recipes/servicenow.md).
