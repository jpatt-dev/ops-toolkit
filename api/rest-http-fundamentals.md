# REST and HTTP fundamentals for troubleshooting

What you need to read an API exchange correctly: methods, status codes, headers, and JSON payloads. For tools, see [curl-and-powershell.md](curl-and-powershell.md). For errors, see [http-error-troubleshooting.md](http-error-troubleshooting.md).

## Anatomy of a request

```text
POST /api/now/table/incident?sysparm_fields=number HTTP/1.1      <- method, path, query string, version
Host: dev.example.com                                             <- which site (and the TLS SNI name)
Accept: application/json                                          <- format you want back
Content-Type: application/json                                    <- format of the body you send
Authorization: Basic <redacted>                                   <- credentials
Content-Length: 39

{"short_description":"Example incident"}                          <- body
```

And the response:

```text
HTTP/1.1 201 Created                                              <- status code
Content-Type: application/json;charset=UTF-8
Location: https://dev.example.com/api/now/table/incident/<sys_id> <- new resource
X-Total-Count: 1

{"result":{"number":"INC0000000"}}
```

## Methods

| Method | Purpose | Safe (no changes) | Idempotent (same result if repeated) | Body |
| --- | --- | --- | --- | --- |
| GET | Read | Yes | Yes | No |
| HEAD | Read headers only | Yes | Yes | No |
| OPTIONS | Ask what is allowed (CORS preflight) | Yes | Yes | No |
| POST | Create, or run an action | No | **No** | Usually |
| PUT | Replace a resource | No | Yes | Yes |
| PATCH | Change part of a resource | No | Not guaranteed | Yes |
| DELETE | Remove | No | Yes | Rarely |

**Never retry a POST automatically.** A POST that timed out may have succeeded on the server. Retrying creates a duplicate change request, ticket, or job. Query for the record first. The diagnostic in this folder never retries a POST and does not follow redirects for POST.

## Status codes

| Range | Meaning | Who should act |
| --- | --- | --- |
| 1xx | Informational | Nobody, usually |
| 2xx | Success | |
| 3xx | Redirect | Client follows, or fix the URL |
| 4xx | The request was wrong for this server | Client: fix the request, credentials, or permissions |
| 5xx | The server or a gateway failed | Server owner, or retry later when the method is safe |

| Code | Name | Common meaning in practice |
| --- | --- | --- |
| 200 | OK | Success with a body |
| 201 | Created | POST created a resource; see `Location` |
| 202 | Accepted | Queued for asynchronous processing; check status later |
| 204 | No Content | Success, empty body (common for DELETE) |
| 301, 308 | Moved permanently | Update the URL. 308 keeps the method and body. |
| 302, 303, 307 | Temporary redirect | Often a login page or a load balancer. 303 turns POST into GET. |
| 304 | Not Modified | Cache validation |
| 400 | Bad Request | Malformed JSON, missing field, invalid value |
| 401 | Unauthorized | Not authenticated: missing, wrong, or expired credentials |
| 403 | Forbidden | Authenticated but not allowed, or blocked by policy (WAF, proxy, IP allow-list) |
| 404 | Not Found | Wrong path, missing resource, or hidden by permissions |
| 405 | Method Not Allowed | Right path, wrong method |
| 406 | Not Acceptable | Server cannot produce the `Accept` format |
| 407 | Proxy Authentication Required | Your proxy wants credentials |
| 408 | Request Timeout | Server gave up waiting for the request |
| 409 | Conflict | State conflict: duplicate, version mismatch, resource locked |
| 410 | Gone | Endpoint or resource removed |
| 412 | Precondition Failed | `If-Match` ETag no longer matches |
| 413 | Payload Too Large | Body exceeds a server or gateway limit |
| 415 | Unsupported Media Type | Wrong or missing `Content-Type` |
| 422 | Unprocessable Entity | Valid JSON, but semantically invalid |
| 429 | Too Many Requests | Rate limited; honor `Retry-After` |
| 500 | Internal Server Error | Unhandled server error |
| 502 | Bad Gateway | Proxy or load balancer got a bad response from the backend |
| 503 | Service Unavailable | Overloaded, in maintenance, or no healthy backend |
| 504 | Gateway Timeout | Proxy or load balancer timed out waiting for the backend |

A 4xx or 5xx proves the network and TLS worked. See [network/workflows.md](../network/workflows.md#authentication-failure-versus-connectivity-failure).

Check **who** sent the status. A 403 or 502 can come from a proxy, a WAF, or a load balancer, not the API. Look at the `Server` header and the body: an HTML page from a proxy vendor is not the API's JSON error.

## Headers that matter

| Header | Direction | Notes |
| --- | --- | --- |
| `Accept` | Request | Ask for `application/json`. Without it, some APIs return XML or HTML. |
| `Content-Type` | Request and response | `application/json` for JSON bodies. A wrong value gives 415 or a 400 that looks like a parsing error. |
| `Authorization` | Request | `Basic <base64>` or `Bearer <token>`. Never log it. |
| `User-Agent` | Request | Some WAFs block unknown or empty agents |
| `X-Request-Id`, `X-Correlation-Id` | Both | Send one and quote it to the API owner for log searches |
| `Location` | Response | URL of a created resource, or a redirect target |
| `Retry-After` | Response | Seconds (or a date) to wait after 429 or 503 |
| `WWW-Authenticate` | Response | With 401: which auth scheme the server wants, sometimes why the token failed |
| `ETag` / `If-Match` | Both | Optimistic concurrency; mismatch gives 412 or 409 |
| `Link`, `X-Total-Count` | Response | Pagination |
| `Set-Cookie` | Response | Session cookies. Treat as secrets. |
| `Server`, `Via` | Response | Which software or proxy answered |

## JSON payload troubleshooting

### Validate before sending

```bash
jq . payload.json                          # parse and pretty-print; error shows line and column
jq -e '.short_description' payload.json    # exits non-zero if the field is missing or null
python3 -m json.tool payload.json          # alternative without jq
```

```powershell
Get-Content -Raw .\payload.json | ConvertFrom-Json      # throws on invalid JSON
$obj = Get-Content -Raw .\payload.json | ConvertFrom-Json; $obj.PSObject.Properties.Name   # top-level keys
```

### Common payload mistakes

| Mistake | Effect | Fix |
| --- | --- | --- |
| Trailing comma, single quotes, comments | 400, parse error | JSON allows none of these |
| Numbers or booleans sent as strings (`"true"`) | 400 or silently wrong type | Match the API schema |
| Missing `Content-Type: application/json` | 415, or body ignored | Set the header |
| Body sent with GET | Ignored or rejected | Use query parameters |
| Field name case (`Short_Description`) | Field ignored | Use exact names from the API docs |
| Nested objects flattened by PowerShell `ConvertTo-Json` | Deep values become `"System.Collections.Hashtable"` | Use `-Depth 10` |
| Single-item array becomes an object | Schema mismatch | `ConvertTo-Json -InputObject @($items)` or `,$items` |
| Non-ASCII characters corrupted | Wrong encoding | Send UTF-8 bytes; see [curl-and-powershell.md](curl-and-powershell.md#encoding) |
| Empty body vs `{}` | Different requests; APIs may treat them differently | Send exactly what the API documents |
| Shell quoting breaks the JSON | Truncated or invalid body | Put the JSON in a file and send it with `--data @file` or `Get-Content -Raw` |

### Compare what you sent with what was expected

1. Print the exact body you are sending (without secrets): `jq -c . payload.json` or `$body`.
2. Compare it against the API documentation or a known-good example.
3. Send the smallest valid body first, then add fields one at a time until the error appears.

## REST conventions you will meet

- Resources are nouns in the path (`/change_request/<id>`); the method is the verb.
- Collection `GET`s are paged. Do not assume one response has everything; follow `Link` or use offsets.
- Filters and field lists are query parameters. Encode them: spaces as `%20`, `=` inside a value as `%3D`, `^` as `%5E` when your client does not encode it.
- Errors usually come back as JSON with a message field. Read it before changing anything.
- Versioned paths (`/v1/`, `/v2/`) can behave differently. Pin the version your automation was tested with.
