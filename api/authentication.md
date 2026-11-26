# API authentication: Basic, OAuth 2.0, and tokens

How each method works, how to test it without exposing secrets, and how it fails. Examples use placeholders. Keep real credentials in a credential store, an AAP credential, or an interactive prompt; never in a script, a command line, or this repository.

## Basic authentication

The client sends `Authorization: Basic base64(username:password)` on every request. Base64 is encoding, not encryption. Basic is acceptable only over HTTPS with certificate validation.

```bash
curl -sS -u "$API_USER" https://api.example.com/v1/status      # curl prompts for the password
```

```powershell
$cred = Get-Credential
Invoke-RestMethod -Uri https://api.example.com/v1/status -Credential $cred                                 # waits for a 401 challenge first
Invoke-RestMethod -Uri https://api.example.com/v1/status -Credential $cred -Authentication Basic           # PowerShell 7: sends immediately
```

For Windows PowerShell 5.1 without a challenge, build the header, use it, and clear it. The [ServiceNow recipe](recipes/servicenow.md) and [Invoke-ApiDiagnostic.ps1](Invoke-ApiDiagnostic.ps1) do this safely.

Failure signs:

| Symptom | Cause |
| --- | --- |
| 401 every time | Wrong password, locked or disabled account, or the API does not accept Basic for this user (SSO-only accounts, MFA enforced) |
| 401 on the first request only, then success (PowerShell `-Credential`) | Normal challenge-response |
| 401 with `WWW-Authenticate: Bearer` | The API wants a token, not Basic |
| Works in a browser, fails in a script | Browser used SSO or a session cookie, not Basic |

## Bearer tokens and API keys

The client sends `Authorization: Bearer <token>`. Some APIs use a custom header such as `X-API-Key`.

```bash
# Read the token from a file with tight permissions, so it does not appear in the process list or shell history.
curl -sS -H @/run/user/$UID/api-auth-header.txt https://api.example.com/v1/status
# where the file contains one line: Authorization: Bearer <token>
```

`-H @file` reads headers from a file (curl 7.55+). A token passed with `-H "Authorization: Bearer $TOKEN"` is visible to other local users in `ps` output while the command runs.

```powershell
$token = Read-Host -AsSecureString 'Token'
Invoke-RestMethod -Uri https://api.example.com/v1/status -Authentication Bearer -Token $token    # PowerShell 7
```

### JWT tokens

Many bearer tokens are JSON Web Tokens: three base64url parts separated by dots. The middle part holds claims you can read without the signing key:

```bash
p=$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+'); while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
base64 -d <<<"$p" | jq '{iss, aud, exp, scope, scp, roles}'
```

| Claim | Check |
| --- | --- |
| `exp` | Expiry as Unix time. `date -d @<exp>` |
| `aud` | Audience: must match the API you call |
| `iss` | Issuer: the identity provider the API trusts |
| `scope`, `scp`, `roles` | Permissions in the token |

Decoding a token does not validate it. Do it only on your own machine; do not paste tokens into websites.

## OAuth 2.0

OAuth separates getting a token from using it. Troubleshoot the two steps separately.

```text
1. Client ──(credentials, grant)──► Token endpoint ──► access_token (+ refresh_token, expires_in)
2. Client ──(Authorization: Bearer access_token)──► API
```

| Grant type | Who uses it | What it sends to the token endpoint |
| --- | --- | --- |
| `client_credentials` | Service-to-service automation | `client_id`, `client_secret`, sometimes `scope` |
| `password` (resource owner) | Legacy integrations | `client_id`, `client_secret`, `username`, `password`. Deprecated by OAuth best practice; some platforms still support it. |
| `refresh_token` | Renewing an expired access token | `refresh_token`, `client_id`, `client_secret` |
| `authorization_code` | Interactive apps with a browser | A code from the login redirect |

Token request example (`client_credentials`). Read the secret from a prompt, and pass it to curl on stdin (`client_secret@-`) so it never appears in curl's arguments:

```bash
read -rs -p 'Client secret: ' CLIENT_SECRET; echo
printf '%s' "$CLIENT_SECRET" |
  curl -sS -X POST https://idp.example.com/oauth2/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode 'client_secret@-' \
    --data-urlencode 'scope=api.read' | jq '{token_type, expires_in, scope, error, error_description}'
unset CLIENT_SECRET
```

`printf` is a shell built-in, so the secret is not passed as a process argument. The `jq` filter shows the outcome without printing the token itself.

ServiceNow's token endpoint is `https://<instance>/oauth_token.do`. Which grant types it accepts depends on the release and the OAuth application registry entry. See [servicenow-rest-concepts.md](servicenow-rest-concepts.md).

### OAuth errors

Token endpoint errors (RFC 6749) come back as JSON with `error` and `error_description`:

| `error` | Meaning |
| --- | --- |
| `invalid_client` | Client ID or secret wrong, or client disabled |
| `invalid_grant` | Username/password wrong, refresh token expired or revoked, or code reused |
| `unauthorized_client` | This client is not allowed to use that grant type |
| `unsupported_grant_type` | The server does not support that grant |
| `invalid_scope` | Requested scope not allowed for this client |
| `invalid_request` | Missing or duplicated parameter; often a wrong `Content-Type` |

API errors with a token:

| Symptom | Cause |
| --- | --- |
| 401 with `WWW-Authenticate: Bearer error="invalid_token"` | Token expired, revoked, malformed, or for another issuer |
| 401 shortly after it worked | Token expired; refresh it |
| 403 with `insufficient_scope` | Token valid but lacks the scope or role |
| Works with one API, 401 on another | `aud` does not match the second API |
| Intermittent 401 across a cluster | Clock skew on servers validating `exp` and `nbf` |

## Mutual TLS (client certificates)

The client proves its identity with a certificate during the TLS handshake. Failures appear as TLS errors or 401/403, not as bad passwords.

```bash
curl -v --cert client.pem --key client.key https://api.example.com/v1/status
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null | grep -A5 'Acceptable client certificate CA names'
```

The server lists which CAs it accepts. Your client certificate must chain to one of them and be within its validity dates.

## Choosing and storing credentials in automation

| Where it runs | Store credentials in |
| --- | --- |
| AAP job | An AAP credential (built-in or custom type) injected as env vars or a file |
| Interactive troubleshooting | `Get-Credential`, `read -s`, or curl's password prompt |
| Linux service | A root-only file referenced by the service, or a secrets manager |
| Windows service | Windows Credential Manager or a secrets manager; not plain text |

Never print `Authorization` headers, tokens, client secrets, or cookies. `curl -v` and PowerShell `-Verbose` and `-Debug` output can show them; strip them before sharing.
