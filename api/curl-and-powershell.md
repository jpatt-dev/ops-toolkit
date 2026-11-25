# API calls with curl, Invoke-RestMethod, and Invoke-WebRequest

Side-by-side recipes for Linux and PowerShell. GET examples are read-only. POST, PATCH, PUT, and DELETE examples change data and are marked `CHANGE`. Hosts are placeholders.

For a single sanitized diagnostic call from PowerShell, use [Invoke-ApiDiagnostic.ps1](Invoke-ApiDiagnostic.ps1). For a layered network check from Linux, use [network/check-endpoint.sh](../network/check-endpoint.sh).

## Which PowerShell cmdlet

| | `Invoke-RestMethod` | `Invoke-WebRequest` |
| --- | --- | --- |
| Returns | Parsed body (JSON becomes objects) | Response object: `StatusCode`, `Headers`, `Content` |
| Use when | You want the data | You need the status code or headers |
| On HTTP errors | Throws (unless `-SkipHttpErrorCheck` in PS 7) | Throws (unless `-SkipHttpErrorCheck` in PS 7) |

PowerShell 7 adds options that Windows PowerShell 5.1 does not have:

| Option | PS 7 | Windows PowerShell 5.1 equivalent |
| --- | --- | --- |
| `-Authentication Basic/Bearer` | Yes | Build the `Authorization` header |
| `-SkipHttpErrorCheck` | Yes | `try/catch` and read the exception's response |
| `-StatusCodeVariable sc` | Yes | Use `Invoke-WebRequest` and `.StatusCode` |
| `-ResponseHeadersVariable h` | Yes (6+) | Use `Invoke-WebRequest` and `.Headers` |
| `-MaximumRetryCount`, `-RetryIntervalSec` | Yes | Write your own loop (never for POST) |
| `-SkipCertificateCheck` | Yes | Do not use either way |
| `-UseBasicParsing` | Default; switch is ignored | Use it: avoids the Internet Explorer engine |

## GET

```bash
curl -sS -H 'Accept: application/json' -u "$API_USER" https://api.example.com/v1/items?limit=5 | jq .
curl -sS -o /dev/null -w '%{http_code}\n' https://api.example.com/v1/health
curl -sS -D - -o /dev/null https://api.example.com/v1/health          # response headers only
```

```powershell
$cred = Get-Credential
Invoke-RestMethod -Uri 'https://api.example.com/v1/items?limit=5' -Credential $cred -Headers @{ Accept = 'application/json' }

$r = Invoke-WebRequest -Uri https://api.example.com/v1/health -UseBasicParsing
$r.StatusCode; $r.Headers['Content-Type']
```

## POST, PATCH, PUT, DELETE (`CHANGE`)

Put JSON in a file outside the repository to avoid quoting problems.

```bash
curl -sS -X POST https://api.example.com/v1/items \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -u "$API_USER" --data @/tmp/example-item.json                          # CHANGE

curl -sS -X PATCH https://api.example.com/v1/items/<id> \
  -H 'Content-Type: application/json' -u "$API_USER" \
  --data '{"state":"closed"}'                                           # CHANGE
```

```powershell
$body = @{ name = 'example'; tags = @('a') } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri https://api.example.com/v1/items -Credential $cred `
    -ContentType 'application/json; charset=utf-8' -Body $body          # CHANGE

Invoke-RestMethod -Method Patch -Uri https://api.example.com/v1/items/<id> -Credential $cred `
    -ContentType 'application/json' -Body '{"state":"closed"}'          # CHANGE
```

`curl --json @file` (curl 7.82+) sets both headers and the body. RHEL 9 ships curl 7.76 and lacks it; use the explicit form.

## Reading errors

curl does not fail on HTTP errors by default. Choose how you want them:

```bash
curl -sS -w '\nHTTP %{http_code}\n' https://api.example.com/v1/items/missing          # body plus status
curl -sS --fail-with-body https://api.example.com/v1/items/missing; echo "rc=$?"     # exit 22 on 4xx/5xx and keep the body (curl 7.76+; not on RHEL 8)
```

Windows PowerShell 5.1:

```powershell
try {
    Invoke-RestMethod -Uri https://api.example.com/v1/items/missing -Credential $cred -ErrorAction Stop
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    "HTTP status: $status"
    if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message }            # the response body, when there is one
    else { $_.Exception.Message }                                       # DNS, TCP, TLS errors have no body
}
```

PowerShell 7:

```powershell
$resp = Invoke-WebRequest -Uri https://api.example.com/v1/items/missing -Credential $cred -SkipHttpErrorCheck
$resp.StatusCode
$resp.Content | ConvertFrom-Json
```

An exception with no response object means the request did not get an HTTP answer: DNS, connection, TLS, or timeout. See [network/workflows.md](../network/workflows.md).

## Headers and tokens

```bash
curl -sS -H @/run/user/$UID/api-auth-header.txt https://api.example.com/v1/items     # header from a file; keeps the token off the command line
```

```powershell
$token = Read-Host -AsSecureString 'Token'
Invoke-RestMethod -Uri https://api.example.com/v1/items -Authentication Bearer -Token $token     # PowerShell 7
```

For Windows PowerShell 5.1, convert the secure string only at the moment of use and clear the variable afterwards. See [authentication.md](authentication.md).

## Encoding

- Query strings: encode values. `curl -G --data-urlencode 'q=name=example' https://...` builds `?q=name%3Dexample`. In PowerShell, use `[Uri]::EscapeDataString($value)`.
- Bodies: Windows PowerShell 5.1 can send a string body in a non-UTF-8 encoding. For non-ASCII data, send bytes:

  ```powershell
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  Invoke-RestMethod -Method Post -Uri $uri -Credential $cred -ContentType 'application/json; charset=utf-8' -Body $bytes   # CHANGE
  ```

- `ConvertTo-Json` defaults to a depth of 2 and silently flattens deeper objects into type names. Always pass `-Depth`.
- `ConvertTo-Json` unwraps single-element arrays when piped. Use `ConvertTo-Json -InputObject @($items) -Depth 10`.

## TLS and certificate validation

Leave validation on. When a call fails with a certificate error:

```bash
curl -v https://api.example.com/ 2>&1 | grep -Ei 'SSL|certificate|subject|issuer|expire'
curl -v --cacert /path/to/internal-ca.pem https://api.example.com/      # does trusting the internal CA fix it?
```

```powershell
# Windows PowerShell 5.1 on older servers may default to TLS 1.0/1.1 for this process.
[Net.ServicePointManager]::SecurityProtocol                               # current protocols
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # this session only
```

| PowerShell error | Meaning |
| --- | --- |
| `The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.` (5.1) | Certificate not trusted, name mismatch, or expired |
| `The SSL connection could not be established, see inner exception.` (7) | Same family; read `$_.Exception.InnerException` |
| `The request was aborted: Could not create SSL/TLS secure channel.` (5.1) | Protocol or cipher mismatch, often TLS 1.2 not enabled for the process |
| `No such host is known` / `Name or service not known` | DNS |
| `Unable to connect to the remote server` / `No connection could be made because the target machine actively refused it` | TCP refused or blocked |
| `The operation has timed out` | No response within the timeout |

Fix trust by importing the issuing CA into `Cert:\LocalMachine\Root` (or the intermediate into `CA`) through your normal process. See [network/tls-openssl.md](../network/tls-openssl.md) and [windows/ad-auth-certificates.md](../windows/ad-auth-certificates.md#certificates).

## Proxies

```bash
curl -v -x http://proxy.example.com:8080 https://api.example.com/
curl -v --noproxy api.example.com https://api.example.com/
```

```powershell
Invoke-RestMethod -Uri https://api.example.com/ -Proxy http://proxy.example.com:8080 -ProxyUseDefaultCredentials
```

## Response troubleshooting checklist

1. **Status code.** 2xx, 4xx, or 5xx? See [http-error-troubleshooting.md](http-error-troubleshooting.md).
2. **Who answered.** `Server` and `Via` headers; JSON from the API or HTML from a proxy?
3. **Content type.** `application/json` expected; HTML usually means a login page, proxy, or error page.
4. **Body message.** Read the API's `message` or `error` field.
5. **Shape.** Expected keys present? `jq 'keys'` or `$r | Get-Member`.
6. **Paging.** More results behind `Link` or an offset?
7. **Timing.** `curl -w` timings; slow `ttfb` means a slow server.

## Cautions

- `-k`, `--insecure`, and `-SkipCertificateCheck` disable server authentication. Do not use them in scripts or as a fix.
- `curl -v`, `--trace`, PowerShell `-Verbose`, and `-Debug` can print credentials and bodies.
- Do not loop retries around POST requests.
