# ServiceNow troubleshooting

## Quick Start — PowerShell Only

Paste the blocks below into the PowerShell window you already have open. Do not save a `.ps1` file and do not install a module. Windows PowerShell 5.1 and PowerShell 7 both work.

Edit the two placeholders, then paste this block once. It asks for a ServiceNow account and defines one command. It does not call ServiceNow.

A POST to the Standard Change API can create a real change record. Test 2 and Test 3 each ask you to type `POST` before that one request is sent. Neither test retries a POST.

```powershell
$devUrl = 'https://dev.example.com'
$templateId = 'example-template-id'

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $protocols = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
}

$credential = Get-Credential -Message 'ServiceNow DEV account. The password is not saved or displayed.'
if (-not $credential) {
    Write-Output 'Credential prompt was cancelled.'
}

function Invoke-ServiceNowCheck {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [switch]$EmptyJson
    )

    if (-not $credential) {
        Write-Output 'No credential is available. No request was sent.'
        return
    }
    if (-not $Uri.ToLowerInvariant().StartsWith('https://')) {
        Write-Output 'Only an https URL is accepted. No request was sent.'
        return
    }
    if ($EmptyJson -and $Method -ne 'POST') {
        Write-Output 'Empty JSON applies only to POST. No request was sent.'
        return
    }

    $encoded = $null
    $headers = @{ Accept = 'application/json' }
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $password = $credential.GetNetworkCredential().Password
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($credential.UserName + ':' + $password)
        )
        $password = $null
        $headers['Authorization'] = 'Basic ' + $encoded

        $request = @{
            Uri             = $Uri
            Method          = $Method
            Headers         = $headers
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        if ($Method -eq 'POST') {
            $request['MaximumRedirection'] = 0
        }
        if ($EmptyJson) {
            $request['Body'] = '{}'
            $request['ContentType'] = 'application/json; charset=utf-8'
        }

        $response = Invoke-WebRequest @request
        Write-Output ('HTTP Status: ' + [int]$response.StatusCode)
        Write-Output 'Message: Request succeeded. The response body is not displayed.'
        Write-Output 'No automatic retry performed.'
    } catch {
        $caught = $_
        $status = $null
        $body = ''
        $webResponse = $null
        if ($caught.Exception.PSObject.Properties['Response']) {
            $webResponse = $caught.Exception.Response
        }
        if ($webResponse -and $webResponse.PSObject.Properties['StatusCode']) {
            $status = [int]$webResponse.StatusCode
        }
        if ($caught.ErrorDetails -and $caught.ErrorDetails.Message) {
            $detailText = [string]$caught.ErrorDetails.Message
            if ($detailText -and $detailText -ne [string]$caught.Exception.Message) {
                $body = $detailText
            }
        }
        if (-not $body -and $webResponse -is [System.Net.HttpWebResponse]) {
            $reader = $null
            try {
                $stream = $webResponse.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                }
            } catch {
                $body = ''
            } finally {
                if ($reader) { $reader.Dispose() }
            }
        }
        if ($null -eq $status -and $caught.Exception.Message -match '\((\d{3})\)') {
            $status = [int]$Matches[1]
        }
        if ($body.Length -gt 8000) { $body = '' }

        $message = Get-ServiceNowErrorText -Body $body -Encoded $encoded
        if (-not $message) {
            $safeFailure = Protect-ServiceNowText -Text $caught.Exception.Message -Encoded $encoded
            if ($safeFailure) {
                $message = $safeFailure
            } elseif ($null -ne $status) {
                $message = 'The server returned an error. The response text was omitted.'
            } else {
                $message = 'The request failed before an HTTP status was returned.'
            }
        }

        if ($null -eq $status) {
            Write-Output 'HTTP Status: Not available'
        } else {
            Write-Output ('HTTP Status: ' + $status)
        }
        Write-Output ('Message: ' + $message)
        Write-Output 'No automatic retry performed.'

        try {
            if ($Error.Count -gt 0 -and $Error[0].Exception -and $caught.Exception -and $Error[0].Exception.Message -eq $caught.Exception.Message) {
                $Error.RemoveAt(0)
            }
        } catch { }
    } finally {
        if ($headers.Contains('Authorization')) {
            $headers['Authorization'] = $null
            [void]$headers.Remove('Authorization')
        }
        $encoded = $null
        $ProgressPreference = $previousProgress
    }
}

function Get-ServiceNowErrorText {
    param(
        [AllowEmptyString()][string]$Body,
        [AllowEmptyString()][string]$Encoded
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $text = $Body.Trim()
    if ($text.Length -gt 8000 -or $text -match '(?i)<!DOCTYPE|<!ENTITY|<!\[CDATA\[') { return $null }

    $extracted = $null
    if ($text.StartsWith('{') -or $text.StartsWith('[')) {
        try {
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
            foreach ($item in @($parsed)) {
                $extracted = Get-ServiceNowJsonText -Object $item
                if ($extracted) { break }
            }
        } catch {
            $extracted = $null
        }
    } elseif ($text -match '(?i)^\s*<\?xml\b' -or $text.StartsWith('<')) {
        if ($text -match '(?i)<\s*(?:!DOCTYPE\s+html|html)(?:\s|>)') { return $null }
        $xmlMessage = Get-ServiceNowXmlValue -Text $text -ElementName 'message'
        if (-not $xmlMessage) { $xmlMessage = Get-ServiceNowXmlValue -Text $text -ElementName 'error_message' }
        $xmlDetail = Get-ServiceNowXmlValue -Text $text -ElementName 'detail'
        if ($xmlMessage -and $xmlDetail -and $xmlDetail -ne $xmlMessage -and $xmlDetail.Length -le 400) {
            if ($xmlMessage.EndsWith('.')) { $extracted = $xmlMessage + ' ' + $xmlDetail }
            else { $extracted = $xmlMessage + '. ' + $xmlDetail }
        } elseif ($xmlMessage) {
            $extracted = $xmlMessage
        } elseif ($xmlDetail -and $xmlDetail.Length -le 400) {
            $extracted = $xmlDetail
        }
    }

    if (-not $extracted) { return $null }
    return Protect-ServiceNowText -Text $extracted -Encoded $Encoded
}

function Get-ServiceNowJsonText {
    param($Object, [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 3) { return $null }
    if ($Object -is [string] -or $Object -is [System.ValueType] -or $Object -is [System.Array]) { return $null }

    $message = $null
    foreach ($name in @('message', 'error_message', 'error_description', 'faultstring')) {
        $property = $Object.PSObject.Properties[$name]
        if ($property -and $property.Value -is [string] -and $property.Value.Trim()) {
            $message = $property.Value.Trim()
            break
        }
    }
    $detail = $null
    $detailProperty = $Object.PSObject.Properties['detail']
    if ($detailProperty -and $detailProperty.Value -is [string] -and $detailProperty.Value.Trim()) {
        $detail = $detailProperty.Value.Trim()
        if ($detail.Length -gt 400) { $detail = $null }
    }
    if ($message) {
        if ($detail -and $detail -ne $message) {
            if ($message.EndsWith('.')) { return $message + ' ' + $detail }
            return $message + '. ' + $detail
        }
        return $message
    }

    foreach ($name in @('error', 'result')) {
        $child = $Object.PSObject.Properties[$name]
        if (-not $child -or $null -eq $child.Value) { continue }
        if ($child.Value -is [string] -or $child.Value -is [System.ValueType]) { continue }
        foreach ($item in @($child.Value)) {
            $nested = Get-ServiceNowJsonText -Object $item -Depth ($Depth + 1)
            if ($nested) { return $nested }
        }
    }
    return $detail
}

function Get-ServiceNowXmlValue {
    param([string]$Text, [string]$ElementName)
    $name = [regex]::Escape($ElementName)
    $pattern = '(?i)<(?:[\w.-]+:)?' + $name + '(?:\s[^>]*)?>([^<]{1,400})</(?:[\w.-]+:)?' + $name + '>'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    $decoded = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value.Trim())
    if ([string]::IsNullOrWhiteSpace($decoded) -or $decoded -match '[<>]') { return $null }
    return $decoded.Trim()
}

function Protect-ServiceNowText {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$Encoded
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $working = $Text
    $secrets = @()
    if ($Encoded) { $secrets += $Encoded }
    if ($credential) {
        if ($credential.UserName) { $secrets += [string]$credential.UserName }
        $password = $credential.GetNetworkCredential().Password
        if ($password) { $secrets += $password }
        $password = $null
    }
    foreach ($secret in $secrets) {
        if ([string]::IsNullOrEmpty($secret)) { continue }
        if ($secret.Length -lt 4) {
            if ($working.IndexOf($secret, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $null }
            continue
        }
        $working = [regex]::Replace($working, [regex]::Escape($secret), '[REDACTED]', 'IgnoreCase')
    }
    $working = [regex]::Replace($working, '(?i)\b(Bearer|Basic)\s+(?=[A-Za-z0-9\-._~+/]{8,})(?=[^\s]*[0-9+/=])[A-Za-z0-9\-._~+/]+', '$1 [REDACTED]')
    $working = [regex]::Replace($working, '(?i)\b(password|passwd|token|authorization|api[_-]?key)\s*[:=]\s*\S+', '$1=[REDACTED]')
    $working = [regex]::Replace($working, '\b[A-Fa-f0-9]{32,}\b', '[REDACTED]')
    if ($working -match '(?i)\b(bearer|basic)\s+(?=[A-Za-z0-9\-._~+/]{8,})(?=[^\s]*[0-9+/=])[A-Za-z0-9\-._~+/]+') { return $null }
    if ($working.Length -gt 500) { $working = $working.Substring(0, 500) }
    return $working.Trim()
}
```

The credential window is the only prompt. No HTTP status is printed yet. Do not display `$credential` or an authorization header. When you are finished, run `Remove-Variable credential`.

On Windows PowerShell, the block selects TLS 1.2 or TLS 1.3 for this session. Certificate checks stay enabled.

## Test 1 — Read-only GET

This call does not create a change. It checks the DEV URL, TLS, and Basic authentication.

```powershell
if (-not (Get-Command Invoke-ServiceNowCheck -ErrorAction SilentlyContinue) -or -not $credential) {
    Write-Output 'Paste the Quick Start block first. No request was sent.'
} else {
    $uri = $devUrl.TrimEnd('/') + '/api/now/table/change_request?sysparm_limit=1&sysparm_fields=number'
    Invoke-ServiceNowCheck -Method GET -Uri $uri
}
```

HTTP 200 means the workstation reached the instance and the account was accepted. The record is not printed. HTTP 401 means authentication failed. A DNS or TLS failure shows `HTTP Status: Not available` instead of an HTTP code.

## Test 2 — POST with no body

This can create a real standard change. Paste it only when that one request is authorized. Type `POST` when asked. Any other response sends nothing. The request is not retried.

```powershell
if (-not (Get-Command Invoke-ServiceNowCheck -ErrorAction SilentlyContinue) -or -not $credential) {
    Write-Output 'Paste the Quick Start block first. No request was sent.'
} else {
    $answer = Read-Host 'Type POST to send one Standard Change request with no body. Any other response cancels'
    if ($answer -cne 'POST') {
        Write-Output 'Cancelled. No request was sent.'
        Write-Output 'No automatic retry performed.'
    } else {
        $uri = $devUrl.TrimEnd('/') + '/api/sn_chg_rest/change/standard/' + [Uri]::EscapeDataString($templateId)
        Invoke-ServiceNowCheck -Method POST -Uri $uri
    }
}
```

HTTP 400 means the API rejected the call. The Message line includes the ServiceNow message and detail when those fields are short enough to show safely. HTTP 401 or 403 is an account or permission problem, not a missing JSON field.

## Test 3 — POST with `{}`

Use this only if Test 2 did not explain the HTTP 400. A POST with no body and a POST of `{}` are different requests. This can also create a real change, and it is not retried.

```powershell
if (-not (Get-Command Invoke-ServiceNowCheck -ErrorAction SilentlyContinue) -or -not $credential) {
    Write-Output 'Paste the Quick Start block first. No request was sent.'
} else {
    $answer = Read-Host 'Type POST to send one Standard Change request with {}. Any other response cancels'
    if ($answer -cne 'POST') {
        Write-Output 'Cancelled. No request was sent.'
        Write-Output 'No automatic retry performed.'
    } else {
        $uri = $devUrl.TrimEnd('/') + '/api/sn_chg_rest/change/standard/' + [Uri]::EscapeDataString($templateId)
        Invoke-ServiceNowCheck -Method POST -EmptyJson -Uri $uri
    }
}
```

Compare this status and Message with Test 2. If both return the same 401 or 403, stop changing the body. If the messages differ, the API is treating the missing body and `{}` differently.

## How to read the result

| HTTP Status | Meaning |
| --- | --- |
| 200 | The GET reached ServiceNow and authentication succeeded. |
| 400 | The API rejected the content or the template id. Use the Message line. |
| 401 | The account or password was not accepted. |
| 403 | The account authenticated, but it is not allowed to perform this action. |
| 404 | The path or template resource was not found. Some releases report a bad template id as 400 instead. |
| 405 | This URL does not allow that method. The standard-change action is a POST. |
| Not available | DNS, the connection, or TLS failed before an HTTP response. |

The commands print the status and a short message. They do not print the password, the authorization header, or the raw response. Do not run `$credential.GetNetworkCredential().Password`.

## Optional script

The tests above do not use a script file. If you later copy `Invoke-ApiDiagnostic.ps1` from this folder onto the workstation, it can run the same kind of single GET or POST. It is optional. Do not download modules for either approach.
