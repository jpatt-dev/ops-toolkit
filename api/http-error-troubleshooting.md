# HTTP 400, 401, 403, 404, 409, 429, and 5xx troubleshooting

Each section: what the status means, how to confirm it from Linux and PowerShell, the usual causes, and what not to do. Status codes in general are in [rest-http-fundamentals.md](rest-http-fundamentals.md#status-codes). ServiceNow-specific messages are in [servicenow-rest-concepts.md](servicenow-rest-concepts.md#error-reference-for-servicenow).

## Capture the evidence once

Get the status, the response headers, and the error body in one read-only request.

```bash
# -i prints the status line and headers before the body. Cookies are filtered out.
curl -sS -i -u "$API_USER" -H 'Accept: application/json' https://api.example.com/v1/resource | grep -vi '^set-cookie:'
```

```powershell
# Windows PowerShell 5.1 and 7
try {
    $r = Invoke-WebRequest -Uri https://api.example.com/v1/resource -Credential $cred -Headers @{ Accept = 'application/json' } -UseBasicParsing -ErrorAction Stop
    "HTTP $($r.StatusCode)"
} catch {
    if ($_.Exception.Response) { "HTTP $([int]$_.Exception.Response.StatusCode)" }
    $_.ErrorDetails.Message
}
```

Or run the sanitized diagnostic: `.\api\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/resource -UseBasicAuth`.

Record: method, URL without secrets, status, `Content-Type`, `Server`, any request or correlation ID header, the error message, and the time. That is what an API owner needs.

## 400 Bad Request

The server read the request and rejected its content.

| Cause | Check |
| --- | --- |
| Invalid JSON | `jq . payload.json` or `ConvertFrom-Json` |
| Missing required field | Compare with the API docs; the message usually names it |
| Wrong type (`"5"` vs `5`, `"true"` vs `true`) | Schema |
| Invalid choice value or reference | Value exists in the target system? |
| Wrong `Content-Type` | Must match the body; some APIs return 400 instead of 415 |
| Empty body vs `{}` vs payload | They are different requests. Test each deliberately. |
| Query parameter syntax | URL encoding of `=`, `&`, `^`, spaces |
| Business rule or validation on the server | Message text from the API, not a JSON parser |

Steps:

1. Read the error message and detail. Most 400s say exactly what is wrong.
2. Send the smallest valid request documented by the API.
3. Add fields one at a time.
4. Do not retry the same request unchanged; it will fail the same way.

## 401 Unauthorized

The server does not accept who you are, or you did not say.

| Cause | Check |
| --- | --- |
| No credentials sent | `curl -v` shows no `Authorization` line; PowerShell `-Credential` without a challenge |
| Wrong password or secret | Test the account in a browser or another known-good client |
| Account locked, disabled, or expired | Identity provider or target system |
| Token expired | JWT `exp`; refresh the token |
| Token for the wrong audience or issuer | JWT `aud` and `iss` |
| Wrong scheme | `WWW-Authenticate` response header says which scheme the server expects |
| Clock skew | Token `nbf`/`exp` validation on servers with wrong time |
| Proxy stripped the header | Test without the proxy, or from a host that needs none |

`401` proves DNS, TCP, and TLS work. Do not request firewall changes for a 401.

## 403 Forbidden

You are authenticated (or authentication is not the issue) and the action is not allowed.

| Cause | Check |
| --- | --- |
| Role or permission missing | The account's roles for that resource and method |
| Object-level permission (ACL) | Can the account read the same record in the UI? |
| Write blocked by a business rule or policy | Error message names the rule |
| IP allow-list on the API | Source address the server sees (after NAT or proxy) |
| WAF or proxy block | HTML body or `Server` header from the security device |
| CSRF or session protection | Some APIs expect a token header with cookie sessions |
| OAuth scope missing | `WWW-Authenticate: Bearer error="insufficient_scope"`; token `scope` claim |

Changing the password does not fix a 403. Changing the JSON body rarely does. Compare the account's rights with the operation.

## 404 Not Found

| Cause | Check |
| --- | --- |
| Wrong path or API version | API documentation or explorer; trailing slash differences |
| Wrong base URL (missing `/api`, wrong context path) | Compare with a working call |
| Resource ID does not exist | Query for it |
| Resource exists but you cannot see it | Some APIs return 404 instead of 403 to avoid revealing existence (ServiceNow does for single records) |
| Wrong host via DNS or load balancer | `curl --resolve` to a known backend |
| Endpoint removed after an upgrade | Release notes. AAP 2.7 removed direct component APIs; use the gateway paths. |

## 409 Conflict

The request conflicts with the current state of the resource.

| Cause | Check |
| --- | --- |
| Resource already exists (duplicate name or unique key) | Query before create |
| Version or ETag mismatch | Re-read the resource, re-apply the change, send the new `If-Match` |
| Resource locked or in a state that forbids the change | Current state; wait or move it to an allowed state |
| Concurrent update by another client | Serialize writers; retry only after re-reading |

A 409 after a retried POST often means the first POST succeeded. Look for the record.

## 429 Too Many Requests

| Check | Action |
| --- | --- |
| `Retry-After` header | Wait at least that long |
| Rate-limit headers (`X-RateLimit-*` or vendor-specific) | Remaining budget and reset time |
| Request pattern | Parallel workers, tight loops, paging without delays |

Reduce concurrency (Ansible `forks`, `throttle`, or `serial` for API tasks; run API calls once with `run_once`), add backoff for safe methods, and cache reads.

## 500, 502, 503, 504

| Code | Who failed | Check |
| --- | --- | --- |
| 500 | The application | Error ID or correlation ID in the body; server logs; does a smaller request work? |
| 502 | Gateway got a bad answer from the backend | Backend health; TLS between gateway and backend; backend crashed mid-response |
| 503 | Service unavailable | Maintenance, overload, or no healthy backend behind the load balancer; `Retry-After` |
| 504 | Gateway timed out waiting for the backend | Slow query or large request; backend health; gateway timeout settings |

Steps:

1. Check whether the error page comes from the API or from a proxy or load balancer (`Server` header, HTML vs JSON).
2. Retry once later only for safe methods (GET). Never auto-retry POST.
3. Provide the API owner with the time, request ID, method, and path.
4. If only large requests fail, reduce page size or payload.

See [network/lb-proxy-vpn.md](../network/lb-proxy-vpn.md#load-balancers) for gateway-side checks.

## No status at all

No HTTP status means the request never got an HTTP response. It is a DNS, TCP, TLS, or timeout problem. Use [network/workflows.md](../network/workflows.md#server-cannot-reach-an-api-endpoint).

## Quick decision table

| You see | Look at | Not at |
| --- | --- | --- |
| No status, DNS or connect error | Network path | Credentials |
| TLS or certificate error | Trust store, certificate, protocol | Credentials, payload |
| 400 | Request content | Firewall, password |
| 401 | Credentials and token | Firewall, payload |
| 403 | Permissions, policy, allow-lists | Password (usually) |
| 404 | URL, ID, visibility | Firewall |
| 409 | Resource state, duplicates | Credentials |
| 429 | Request rate | Payload |
| 5xx | Server or gateway | Your payload (unless only large requests fail) |
