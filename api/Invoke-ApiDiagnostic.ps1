#Requires -Version 5.1
<#
.SYNOPSIS
    Prints a sanitized diagnostic for one HTTPS GET or POST.

.DESCRIPTION
    Sends one HTTPS request and prints a short diagnostic report.
    Certificate validation is left unchanged. Credentials, authorization
    headers, cookies, and raw response bodies are not written to disk and
    are not printed.

    GET is the default. POST requires -AllowWrite and either -ConfirmPost
    or an interactive confirmation. POST is never retried and redirects are
    not followed for POST, so a POST is not resent automatically.

    A POST with no body, a POST with {}, and a POST with a JSON payload are
    different requests. The report states which one was sent.

.PARAMETER Uri
    Absolute https URI. User information embedded in the URI is refused.

.PARAMETER Method
    GET or POST. The default is GET.

.PARAMETER Credential
    Basic authentication credential. It is not stored. Ignored unless
    -UseBasicAuth is also specified.

.PARAMETER UseBasicAuth
    Send HTTP Basic authentication. Prompts with Get-Credential when
    -Credential is omitted.

.PARAMETER Headers
    Optional request headers. Authorization, cookie, and other secret-bearing
    header names are refused. Header values are not printed.

.PARAMETER Body
    JSON request body. Sent exactly as supplied after it parses as JSON.
    This is not the same as -EmptyJson.

.PARAMETER EmptyJson
    Send the two-character body {}.

.PARAMETER AllowWrite
    Required for POST. Without it, no request is sent.

.PARAMETER ConfirmPost
    Explicit confirmation for one POST. Without it, the script prompts and
    sends the POST only when the response is POST.

.EXAMPLE
    .\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/status -UseBasicAuth

    GET with Basic authentication. The credential is collected interactively.

.EXAMPLE
    .\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/jobs -Method POST -UseBasicAuth -AllowWrite -ConfirmPost

    POST with no request body.

.EXAMPLE
    .\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/jobs -Method POST -EmptyJson -UseBasicAuth -AllowWrite -ConfirmPost

    POST whose body is exactly {}.

.EXAMPLE
    .\Invoke-ApiDiagnostic.ps1 -Uri https://api.example.com/v1/jobs -Method POST -Body '{"action":"validate"}' -UseBasicAuth -AllowWrite -ConfirmPost

    POST with a JSON payload.

.NOTES
    Client URLs, payloads, and credentials do not belong in this repository.
    The script does not disable certificate validation and does not save
    the raw request or response.
#>
param(
    [Uri]$Uri,
    [ValidateSet('GET', 'POST')]
    [string]$Method = 'GET',
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UseBasicAuth,
    [hashtable]$Headers,
    [string]$Body,
    [switch]$EmptyJson,
    [switch]$AllowWrite,
    [switch]$ConfirmPost
)

function ConvertTo-SanitizedDiagnosticText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals,
        [int]$MaxLength = 500
    )

    $unreliable = [pscustomobject]@{
        Text      = ''
        Reliable  = $false
    }
    if ([string]::IsNullOrEmpty($Text)) {
        return [pscustomobject]@{
            Text     = ''
            Reliable = $true
        }
    }
    if ($Text.Length -gt 8192) {
        return $unreliable
    }
    if ($Text -match '(?i)BEGIN\s+(RSA\s+|OPENSSH\s+|EC\s+)?PRIVATE\s+KEY') {
        return $unreliable
    }

    $working = Remove-SensitiveLiterals -Text $Text -SensitiveLiterals $SensitiveLiterals
    if ($null -eq $working) {
        return $unreliable
    }

    $working = [regex]::Replace($working, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    $working = [regex]::Replace($working, '\s+', ' ').Trim()
    $working = Remove-SensitiveLiterals -Text $working -SensitiveLiterals $SensitiveLiterals
    if ($null -eq $working) {
        return $unreliable
    }

    $working = [regex]::Replace($working, '(?i)(https?://)[^/\s:@]+:[^/\s@]+@', '$1[REDACTED]@')
    $working = [regex]::Replace($working, '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/=]{8,}', '$1 [REDACTED]')
    $working = [regex]::Replace($working, '\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b', '[REDACTED]')
    $working = [regex]::Replace(
        $working,
        '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|session|cookie|credential|authorization)(\s*[:=]\s*)(["'']?)([^"''\s,}&]+)',
        '$1$2$3[REDACTED]'
    )
    $working = [regex]::Replace($working, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[REDACTED-EMAIL]')
    $working = [regex]::Replace($working, '\b[A-Fa-f0-9]{32,}\b', '[REDACTED]')
    $working = [regex]::Replace($working, '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b', '[REDACTED]')
    $working = [regex]::Replace($working, '\b[A-Za-z0-9+/]{40,}={0,2}\b', '[REDACTED]')
    $working = Remove-SensitiveLiterals -Text $working -SensitiveLiterals $SensitiveLiterals
    if ($null -eq $working) {
        return $unreliable
    }

    # A value that is already [REDACTED] is safe. Any other leftover assignment is not.
    if ($working -match '(?i)(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|client[_-]?secret|authorization)\s*[:=]\s*(?!\[REDACTED\])\S+') {
        return $unreliable
    }
    if ($working -match '(?i)\b(bearer|basic)\s+(?!\[REDACTED\])[A-Za-z0-9\-._~+/=]{8,}') {
        return $unreliable
    }
    if ($MaxLength -gt 0 -and $working.Length -gt $MaxLength) {
        $working = $working.Substring(0, $MaxLength) + '...'
    }
    return [pscustomobject]@{
        Text     = $working
        Reliable = $true
    }
}

function Remove-SensitiveLiterals {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals
    )

    if ([string]::IsNullOrEmpty($Text) -or -not $SensitiveLiterals) {
        return $Text
    }

    $working = $Text
    foreach ($literal in $SensitiveLiterals) {
        if ([string]::IsNullOrEmpty($literal)) {
            continue
        }
        if ($literal.Length -lt 4) {
            $shortPattern = '(?<![A-Za-z0-9])' + [regex]::Escape($literal) + '(?![A-Za-z0-9])'
            if ([regex]::IsMatch($working, $shortPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return $null
            }
            continue
        }
        $pattern = [regex]::Escape($literal)
        $updated = [regex]::Replace(
            $working,
            $pattern,
            '[REDACTED]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($updated.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $null
        }
        $working = $updated
    }
    return $working
}

function Test-SensitiveHeaderName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name -match '(?i)(authorization|proxy-authorization|cookie|set-cookie|api-key|apikey|token|secret|password|credential|session|signature)'
}

function Test-SensitiveQueryName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name -match '(?i)password|passwd|pwd|secret|token|api[-_]?key|session|cookie|credential|signature|authorization|^code$|^auth$'
}

function Test-PrintableAscii {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) {
        return $false
    }
    if ($Value.Length -eq 0) {
        return $true
    }
    return $Value -match '^[\x20-\x7E]+$'
}

function ConvertTo-SanitizedEndpoint {
    param(
        [AllowEmptyString()]
        [string]$AbsoluteUri,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals
    )

    if ([string]::IsNullOrWhiteSpace($AbsoluteUri)) {
        return '(not accepted)'
    }
    try {
        $uri = [Uri]$AbsoluteUri
    } catch {
        return '(not accepted)'
    }
    if (-not $uri.IsAbsoluteUri) {
        return '(not accepted)'
    }

    $hostName = $uri.Host
    $idn = $uri.PSObject.Properties['IdnHost']
    if ($idn -and -not [string]::IsNullOrWhiteSpace([string]$idn.Value)) {
        $hostName = [string]$idn.Value
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        return '(not accepted)'
    }

    $display = $uri.Scheme + '://' + $hostName
    if (-not $uri.IsDefaultPort) {
        $display += ':' + $uri.Port
    }
    $path = $uri.AbsolutePath
    if ($path -eq '/') {
        $path = ''
    }
    $display += $path

    if (-not [string]::IsNullOrEmpty($uri.Query)) {
        $safePairs = @()
        foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
            if ([string]::IsNullOrEmpty($pair)) {
                continue
            }
            $separator = $pair.IndexOf('=')
            if ($separator -lt 0) {
                $safePairs += $pair
                continue
            }
            $pairName = $pair.Substring(0, $separator)
            $pairValue = $pair.Substring($separator + 1)
            $decodedName = $pairName
            try {
                $decodedName = [Uri]::UnescapeDataString($pairName)
            } catch {
                $decodedName = $pairName
            }
            if (Test-SensitiveQueryName -Name $decodedName) {
                $safePairs += ($pairName + '=[REDACTED]')
                continue
            }
            try {
                $decodedValue = [Uri]::UnescapeDataString($pairValue)
            } catch {
                $safePairs += ($pairName + '=[REDACTED]')
                continue
            }
            $checked = ConvertTo-SanitizedDiagnosticText -Text $decodedValue -SensitiveLiterals $SensitiveLiterals -MaxLength 200
            if ((-not $checked.Reliable) -or ($checked.Text -ne $decodedValue)) {
                $safePairs += ($pairName + '=[REDACTED]')
            } else {
                $safePairs += $pair
            }
        }
        if ($safePairs.Count -gt 0) {
            $display += '?' + ($safePairs -join '&')
        }
    }

    $final = ConvertTo-SanitizedDiagnosticText -Text $display -SensitiveLiterals $SensitiveLiterals -MaxLength 2000
    if (-not $final.Reliable -or [string]::IsNullOrWhiteSpace($final.Text)) {
        return '(endpoint omitted)'
    }
    return $final.Text
}

function Get-HttpStatusCategory {
    param([int]$StatusCode)
    switch ($StatusCode) {
        200 { return 'Success' }
        201 { return 'Success' }
        202 { return 'Success' }
        204 { return 'Success' }
        301 { return 'Redirect' }
        302 { return 'Redirect' }
        303 { return 'Redirect' }
        307 { return 'Redirect' }
        308 { return 'Redirect' }
        400 { return 'Bad Request' }
        401 { return 'Unauthorized' }
        403 { return 'Forbidden' }
        404 { return 'Not Found' }
        405 { return 'Method Not Allowed' }
        408 { return 'Request Timeout' }
        409 { return 'Conflict' }
        415 { return 'Unsupported Media Type' }
        422 { return 'Unprocessable Entity' }
        429 { return 'Too Many Requests' }
        500 { return 'Internal Server Error' }
        502 { return 'Bad Gateway' }
        503 { return 'Service Unavailable' }
        504 { return 'Gateway Timeout' }
        default {
            if ($StatusCode -ge 200 -and $StatusCode -lt 300) { return 'Success' }
            if ($StatusCode -ge 300 -and $StatusCode -lt 400) { return 'Redirect' }
            if ($StatusCode -ge 400 -and $StatusCode -lt 500) { return 'Client Error' }
            if ($StatusCode -ge 500 -and $StatusCode -lt 600) { return 'Server Error' }
            return 'HTTP'
        }
    }
}

function Get-DiagnosticHint {
    param([string]$Label)
    switch ($Label) {
        'Bad Request' {
            return 'Compare a POST with no body, a POST with {}, and a POST with the documented JSON payload. These requests are not equivalent.'
        }
        'Unauthorized' {
            return 'The server rejected authentication. Confirm the account and that this endpoint expects Basic authentication.'
        }
        'Forbidden' {
            return 'The server refused the request. This is often an authorization or permission failure rather than a bad password.'
        }
        'Not Found' {
            return 'Check the path and whether this environment uses a different base URL.'
        }
        'Unsupported Media Type' {
            return 'Compare the request content type. A missing body, {}, and a JSON payload can be treated differently.'
        }
        'Redirect' {
            return 'The redirect was not followed, so the request was not resent.'
        }
        'TLS' {
            return 'Certificate validation was not disabled. Check the trust chain, hostname, and TLS protocol.'
        }
        'DNS' {
            return 'Check DNS and the hostname. No HTTP response was received.'
        }
        'Connection' {
            return 'Check routing, firewalls, proxies, and TCP port 443.'
        }
        'Timeout' {
            return 'The server or a proxy did not answer in time. The request was not retried.'
        }
        default { return '' }
    }
}

function Get-TransportFallbackMessage {
    param([string]$FailureKind)
    switch ($FailureKind) {
        'DNS' { return 'The hostname could not be resolved.' }
        'Connection' { return 'The connection to the server failed.' }
        'TLS' { return 'TLS negotiation or certificate validation failed. Certificate checks were not disabled.' }
        'Timeout' { return 'The connection timed out.' }
        'HTTP' { return 'The server returned an HTTP error.' }
        default { return 'The request failed before an HTTP status was returned.' }
    }
}

function Get-JsonPropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string] -or $Object -is [System.Array] -or $Object -is [System.ValueType]) {
        return $null
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -eq $Name) {
            return $property.Value
        }
    }
    return $null
}

function Get-JsonStringProperty {
    param($Object, [string]$Name)
    $value = Get-JsonPropertyValue -Object $Object -Name $Name
    if ($value -isnot [string]) { return $null }
    $text = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Join-DiagnosticMessage {
    param(
        [AllowEmptyString()]
        [string]$Primary,
        [AllowEmptyString()]
        [string]$Detail
    )
    if ([string]::IsNullOrWhiteSpace($Primary)) { return $null }
    $primaryText = $Primary.Trim()
    if ([string]::IsNullOrWhiteSpace($Detail)) { return $primaryText }
    $detailText = $Detail.Trim()
    # A long detail is often a record dump. Keep the short message instead.
    if ($detailText.Length -gt 400 -or $detailText -eq $primaryText) { return $primaryText }
    if ($primaryText.EndsWith('.')) { return ($primaryText + ' ' + $detailText) }
    return ($primaryText + '. ' + $detailText)
}

function Get-FirstJsonMessage {
    param($Object, [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 4) { return $null }
    if ($Object -is [string] -or $Object -is [System.ValueType] -or $Object -is [System.Array]) {
        return $null
    }

    $primary = $null
    foreach ($name in @('message', 'error_message', 'error_description', 'faultstring')) {
        $primary = Get-JsonStringProperty -Object $Object -Name $name
        if ($primary) { break }
    }
    $detail = Get-JsonStringProperty -Object $Object -Name 'detail'
    if ($primary) {
        return Join-DiagnosticMessage -Primary $primary -Detail $detail
    }

    $errorValue = Get-JsonPropertyValue -Object $Object -Name 'error'
    if ($errorValue -is [string] -and -not [string]::IsNullOrWhiteSpace($errorValue)) {
        return $errorValue.Trim()
    }
    if ($null -ne $errorValue -and $errorValue -isnot [string] -and $errorValue -isnot [System.ValueType]) {
        $nestedError = Get-FirstJsonMessage -Object $errorValue -Depth ($Depth + 1)
        if ($nestedError) { return $nestedError }
    }

    $errorsValue = Get-JsonPropertyValue -Object $Object -Name 'errors'
    if ($null -ne $errorsValue) {
        foreach ($item in @($errorsValue)) {
            if ($item -is [string] -and -not [string]::IsNullOrWhiteSpace($item)) {
                return $item.Trim()
            }
            $nestedItem = Get-FirstJsonMessage -Object $item -Depth ($Depth + 1)
            if ($nestedItem) { return $nestedItem }
        }
    }

    $resultValue = Get-JsonPropertyValue -Object $Object -Name 'result'
    if ($resultValue -is [System.Array]) {
        foreach ($item in @($resultValue)) {
            $nestedResult = Get-FirstJsonMessage -Object $item -Depth ($Depth + 1)
            if ($nestedResult) { return $nestedResult }
        }
    } elseif ($null -ne $resultValue -and $resultValue -isnot [string] -and $resultValue -isnot [System.ValueType]) {
        $nestedResult = Get-FirstJsonMessage -Object $resultValue -Depth ($Depth + 1)
        if ($nestedResult) { return $nestedResult }
    }

    if ($detail) { return $detail }
    foreach ($name in @('title', 'description')) {
        $text = Get-JsonStringProperty -Object $Object -Name $name
        if ($text) { return $text }
    }

    foreach ($name in @('code', 'error_code', 'status')) {
        $code = Get-JsonPropertyValue -Object $Object -Name $name
        if ($null -ne $code -and $code -is [System.ValueType] -and ([string]$code) -match '^\d+$') {
            return 'Error code: ' + [string]$code
        }
    }
    return $null
}

function Get-XmlElementText {
    param([string]$Text, [string]$ElementName)
    $name = [regex]::Escape($ElementName)
    $pattern = '(?i)<(?:[\w.-]+:)?' + $name + '(?:\s[^>]*)?>([^<]{1,400})</(?:[\w.-]+:)?' + $name + '>'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    $raw = $match.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $decoded = [System.Net.WebUtility]::HtmlDecode($raw)
    if ([string]::IsNullOrWhiteSpace($decoded) -or $decoded -match '[<>]') { return $null }
    return $decoded.Trim()
}

function Get-SafeXmlMessage {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 8192) { return $null }
    # DTD, entities, and CDATA are not expanded or displayed.
    if ($Text -match '(?i)<!DOCTYPE|<!ENTITY|<!\[CDATA\[') { return $null }

    $message = Get-XmlElementText -Text $Text -ElementName 'message'
    if (-not $message) { $message = Get-XmlElementText -Text $Text -ElementName 'error_message' }
    if (-not $message) { $message = Get-XmlElementText -Text $Text -ElementName 'faultstring' }
    $detail = Get-XmlElementText -Text $Text -ElementName 'detail'
    if ($message) { return Join-DiagnosticMessage -Primary $message -Detail $detail }
    if ($detail -and $detail.Length -le 400) { return $detail }
    return $null
}

function Get-SafeApiMessage {
    param(
        [AllowEmptyString()]
        [string]$ResponseBody,
        [AllowEmptyString()]
        [string]$ContentType
    )

    if ([string]::IsNullOrWhiteSpace($ResponseBody)) {
        return $null
    }
    $trimmed = $ResponseBody.Trim()
    $looksJson = $false
    if ($ContentType -match '(?i)json') { $looksJson = $true }
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) { $looksJson = $true }
    if ($looksJson) {
        try {
            $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return $null
        }
        foreach ($item in @($parsed)) {
            $message = Get-FirstJsonMessage -Object $item
            if ($message) { return $message }
        }
        return $null
    }
    if ($ContentType -match '(?i)html' -or $trimmed -match '(?i)^(?:\s*<\?xml[^>]*>\s*)?<\s*(?:!DOCTYPE\s+html|html)(?:\s|>)') {
        return $null
    }
    $looksXml = $false
    if ($ContentType -match '(?i)(^|[+/])xml\b') { $looksXml = $true }
    if ($trimmed -match '(?i)^\s*<\?xml\b') { $looksXml = $true }
    if ($looksXml) {
        return Get-SafeXmlMessage -Text $trimmed
    }
    if ($ContentType -match '(?i)text/plain' -and $trimmed.Length -le 400 -and $trimmed -notmatch '(?i)<\s*html') {
        return $trimmed
    }
    return $null
}

function Get-DisplayMessage {
    param(
        [AllowEmptyString()]
        [string]$Raw,
        [string]$Fallback,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $Fallback
    }
    $safe = ConvertTo-SanitizedDiagnosticText -Text $Raw -SensitiveLiterals $SensitiveLiterals -MaxLength 500
    if (-not $safe.Reliable -or [string]::IsNullOrWhiteSpace($safe.Text)) {
        return $Fallback + ' The response text was omitted because it could not be sanitized safely.'
    }
    return $safe.Text
}

function ConvertTo-HeaderValueText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $parts = @()
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $parts += [string]$item
        }
    }
    return ($parts -join ', ')
}

function ConvertTo-HeaderHashtable {
    param($Headers)
    $table = @{}
    if ($null -eq $Headers) { return $table }

    if ($Headers -is [System.Collections.Specialized.NameValueCollection]) {
        foreach ($key in @($Headers.AllKeys)) {
            if (-not [string]::IsNullOrEmpty([string]$key)) {
                $table[[string]$key] = [string]$Headers[$key]
            }
        }
        return $table
    }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in @($Headers.Keys)) {
            $table[[string]$key] = ConvertTo-HeaderValueText -Value $Headers[$key]
        }
        return $table
    }
    foreach ($item in @($Headers)) {
        if ($null -eq $item) { continue }
        $keyProp = $item.PSObject.Properties['Key']
        $valueProp = $item.PSObject.Properties['Value']
        if ($keyProp -and $valueProp) {
            $table[[string]$keyProp.Value] = ConvertTo-HeaderValueText -Value $valueProp.Value
        }
    }
    return $table
}

function Get-HeaderValue {
    param([hashtable]$Headers, [string]$Name)
    if (-not $Headers) { return $null }
    foreach ($key in @($Headers.Keys)) {
        if ([string]$key -eq $Name) {
            return [string]$Headers[$key]
        }
    }
    return $null
}

function Get-SafeResponseHeaderLines {
    param(
        [hashtable]$Headers,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals
    )

    $lines = @()
    if (-not $Headers) { return $lines }
    $allow = @(
        'Date', 'Server', 'Retry-After', 'WWW-Authenticate', 'Location', 'Warning',
        'X-Request-Id', 'X-Correlation-Id', 'Request-Id', 'Correlation-Id',
        'X-RateLimit-Limit', 'X-RateLimit-Remaining', 'X-RateLimit-Reset'
    )
    $count = 0
    foreach ($key in @($Headers.Keys)) {
        if ($count -ge 25) { break }
        $name = [string]$key
        if ($name -eq 'Content-Type') { continue }
        $safeName = ConvertTo-SanitizedDiagnosticText -Text $name -SensitiveLiterals $SensitiveLiterals -MaxLength 80
        $displayName = 'Header'
        if ($safeName.Reliable -and -not [string]::IsNullOrWhiteSpace($safeName.Text)) {
            $displayName = $safeName.Text
        }
        if (Test-SensitiveHeaderName -Name $name) {
            $lines += ($displayName + ': [REDACTED]')
            $count++
            continue
        }
        $allowed = $false
        foreach ($candidate in $allow) {
            if ($name -eq $candidate) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            $lines += ($displayName + ': [not displayed]')
            $count++
            continue
        }

        $rawValue = [string]$Headers[$key]
        $display = '[REDACTED]'
        if ($name -eq 'Location' -and $rawValue -match '(?i)^https?://') {
            $display = ConvertTo-SanitizedEndpoint -AbsoluteUri $rawValue -SensitiveLiterals $SensitiveLiterals
        } else {
            $safeValue = ConvertTo-SanitizedDiagnosticText -Text $rawValue -SensitiveLiterals $SensitiveLiterals -MaxLength 180
            if ($safeValue.Reliable -and -not [string]::IsNullOrWhiteSpace($safeValue.Text)) {
                $display = $safeValue.Text
            }
        }
        $lines += ($displayName + ': ' + $display)
        $count++
    }
    return $lines
}

function Format-ApiDiagnosticReport {
    param(
        [string]$Endpoint,
        [string]$Method,
        [string]$Authentication,
        [string]$BodyMode,
        [string]$RequestContentType,
        [string]$HttpStatus,
        [string]$ContentType,
        [string]$Category,
        [string]$Message,
        [AllowEmptyString()]
        [string]$Hint,
        [AllowEmptyCollection()]
        [string[]]$HeaderLines,
        [bool]$RequestSent
    )

    $lines = @()
    $lines += 'API Diagnostic'
    $lines += '----------------------------'
    $lines += ''
    $lines += 'Endpoint: ' + $Endpoint
    $lines += 'Method: ' + $Method
    $lines += 'Authentication: ' + $Authentication
    $lines += 'Request Body: ' + $BodyMode
    $lines += 'Request Content Type: ' + $RequestContentType
    $lines += 'HTTP Status: ' + $HttpStatus
    $lines += 'Content Type: ' + $ContentType
    if ($HeaderLines -and @($HeaderLines).Count -gt 0) {
        $lines += ''
        $lines += 'Response Headers:'
        foreach ($headerLine in @($HeaderLines)) {
            $lines += '  ' + $headerLine
        }
    }
    $lines += ''
    if ($Category -eq 'Success') {
        $lines += 'Result:'
    } else {
        $lines += 'Error:'
    }
    $lines += 'Category: ' + $Category
    $lines += 'Message: ' + $Message
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $lines += ''
        $lines += 'Hint: ' + $Hint
    }
    $lines += ''
    if ($RequestSent -and $HttpStatus -ne 'Not available') {
        $lines += 'Request completed.'
    } elseif ($RequestSent) {
        $lines += 'Request finished without an HTTP status.'
    } else {
        $lines += 'No request was sent.'
    }
    $lines += 'No automatic retry performed.'
    return ($lines -join [Environment]::NewLine)
}

function New-NotSentReport {
    param(
        [string]$Endpoint,
        [string]$Method,
        [string]$Authentication,
        [string]$BodyMode,
        [string]$Message,
        [string]$RequestContentType = 'Not set'
    )

    if ([string]::IsNullOrWhiteSpace($RequestContentType)) { $RequestContentType = 'Not set' }
    if ([string]::IsNullOrWhiteSpace($BodyMode)) { $BodyMode = 'None' }
    if ([string]::IsNullOrWhiteSpace($Authentication)) { $Authentication = 'None' }
    if ([string]::IsNullOrWhiteSpace($Method)) { $Method = 'GET' }
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { $Endpoint = '(not accepted)' }

    $format = @{
        Endpoint            = $Endpoint
        Method              = $Method
        Authentication      = $Authentication
        BodyMode            = $BodyMode
        RequestContentType  = $RequestContentType
        HttpStatus          = 'Not available'
        ContentType         = 'Not available'
        Category            = 'Not Sent'
        Message             = $Message
        Hint                = ''
        HeaderLines         = @()
        RequestSent         = $false
    }
    return (Format-ApiDiagnosticReport @format)
}

function Get-ApiDiagnosticReportText {
    param(
        [string]$Endpoint,
        [string]$Method,
        [string]$Authentication,
        [string]$BodyMode,
        [string]$RequestContentType,
        [string]$FailureKind,
        $StatusCode,
        [hashtable]$ResponseHeaders,
        [AllowEmptyString()]
        [string]$ResponseBody,
        [AllowEmptyString()]
        [string]$Detail,
        [AllowEmptyCollection()]
        [string[]]$SensitiveLiterals,
        [bool]$RequestSent
    )

    $safeEndpoint = ConvertTo-SanitizedEndpoint -AbsoluteUri $Endpoint -SensitiveLiterals $SensitiveLiterals
    if ([string]::IsNullOrWhiteSpace($RequestContentType)) {
        $RequestContentType = 'Not set'
    } else {
        $safeRequestType = ConvertTo-SanitizedDiagnosticText -Text $RequestContentType -SensitiveLiterals $SensitiveLiterals -MaxLength 120
        if ($safeRequestType.Reliable -and $safeRequestType.Text) {
            $RequestContentType = $safeRequestType.Text
        } else {
            $RequestContentType = '[REDACTED]'
        }
    }

    $headerTable = @{}
    if ($ResponseHeaders) {
        foreach ($key in @($ResponseHeaders.Keys)) {
            $headerTable[[string]$key] = [string]$ResponseHeaders[$key]
        }
    }

    $statusText = 'Not available'
    $category = $FailureKind
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Unknown' }
    $contentType = 'Not available'
    $rawContentType = Get-HeaderValue -Headers $headerTable -Name 'Content-Type'
    if ($rawContentType) {
        $safeContentType = ConvertTo-SanitizedDiagnosticText -Text $rawContentType -SensitiveLiterals $SensitiveLiterals -MaxLength 160
        if ($safeContentType.Reliable -and $safeContentType.Text) {
            $contentType = $safeContentType.Text
        } else {
            $contentType = '[REDACTED]'
        }
    }

    $numericStatus = $null
    if ($null -ne $StatusCode -and ([string]$StatusCode) -match '^\d{3}$') {
        $numericStatus = [int]$StatusCode
    }

    if ($null -ne $numericStatus) {
        $statusText = [string]$numericStatus
        $category = Get-HttpStatusCategory -StatusCode $numericStatus
        if ($numericStatus -ge 200 -and $numericStatus -lt 300) {
            $message = 'The server returned a success status. The response body is not displayed.'
        } elseif ($numericStatus -ge 300 -and $numericStatus -lt 400) {
            $message = 'The server returned a redirect. It was not followed, so the request was not resent.'
        } else {
            $extracted = Get-SafeApiMessage -ResponseBody $ResponseBody -ContentType $rawContentType
            $fallback = 'The server returned HTTP ' + $numericStatus + '.'
            $message = Get-DisplayMessage -Raw $extracted -Fallback $fallback -SensitiveLiterals $SensitiveLiterals
        }
    } else {
        $contentType = 'Not available'
        $fallback = Get-TransportFallbackMessage -FailureKind $category
        if ([string]::IsNullOrWhiteSpace($Detail)) {
            $message = $fallback
        } else {
            $safeDetail = ConvertTo-SanitizedDiagnosticText -Text $Detail -SensitiveLiterals $SensitiveLiterals -MaxLength 400
            if ($safeDetail.Reliable -and -not [string]::IsNullOrWhiteSpace($safeDetail.Text)) {
                $message = $fallback + ' ' + $safeDetail.Text
            } else {
                $message = $fallback + ' The response text was omitted because it could not be sanitized safely.'
            }
        }
    }

    $hint = Get-DiagnosticHint -Label $category
    if ([string]::IsNullOrWhiteSpace($hint)) {
        $hint = Get-DiagnosticHint -Label $FailureKind
    }
    $headerLines = @(Get-SafeResponseHeaderLines -Headers $headerTable -SensitiveLiterals $SensitiveLiterals)

    $format = @{
        Endpoint           = $safeEndpoint
        Method             = $Method
        Authentication     = $Authentication
        BodyMode           = $BodyMode
        RequestContentType = $RequestContentType
        HttpStatus         = $statusText
        ContentType        = $contentType
        Category           = $category
        Message            = $message
        Hint               = $hint
        HeaderLines        = $headerLines
        RequestSent        = $RequestSent
    }
    return (Format-ApiDiagnosticReport @format)
}

function Get-ExceptionChain {
    param($Exception)
    $chain = @()
    $current = $Exception
    $guard = 0
    while (($null -ne $current) -and ($guard -lt 8)) {
        $chain += $current
        $current = $current.InnerException
        $guard++
    }
    return $chain
}

function Get-KindFromExceptionType {
    param($Exception)
    if ($null -eq $Exception) { return 'Unknown' }
    $typeName = $Exception.GetType().FullName
    if ($typeName -eq 'System.Net.WebException') {
        switch ([string]$Exception.Status) {
            'NameResolutionFailure' { return 'DNS' }
            'ProxyNameResolutionFailure' { return 'DNS' }
            'ConnectFailure' { return 'Connection' }
            'ConnectionClosed' { return 'Connection' }
            'SendFailure' { return 'Connection' }
            'ReceiveFailure' { return 'Connection' }
            'PipelineFailure' { return 'Connection' }
            'Timeout' { return 'Timeout' }
            'TrustFailure' { return 'TLS' }
            'SecureChannelFailure' { return 'TLS' }
            'ProtocolError' { return 'HTTP' }
            default { return 'Unknown' }
        }
    }
    if ($typeName -eq 'System.Security.Authentication.AuthenticationException') { return 'TLS' }
    if ($typeName -eq 'System.Net.Sockets.SocketException') {
        $socketCode = ''
        $codeProperty = $Exception.PSObject.Properties['SocketErrorCode']
        if ($codeProperty) { $socketCode = [string]$codeProperty.Value }
        if ($socketCode -match 'HostNotFound|NoData|TryAgain|NoRecovery') { return 'DNS' }
        if ($socketCode -eq 'TimedOut') { return 'Timeout' }
        return 'Connection'
    }
    return 'Unknown'
}

function Get-KindFromMessage {
    param([AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'Unknown' }
    if ($Message -match '(?i)certificate|ssl|tls|trust relationship|secure channel') { return 'TLS' }
    if ($Message -match '(?i)name resolution|no such host|could not be resolved|nodename nor servname|temporary failure in name resolution') { return 'DNS' }
    if ($Message -match '(?i)timed out|timeout') { return 'Timeout' }
    if ($Message -match '(?i)connection refused|actively refused|unreachable|connection failed|unable to connect|established connection was aborted') { return 'Connection' }
    return 'Unknown'
}

function Get-FailureKindFromException {
    param($Exception)
    if ($null -eq $Exception) { return 'Unknown' }
    $chain = @(Get-ExceptionChain -Exception $Exception)
    $fallback = 'Unknown'
    foreach ($item in $chain) {
        $kind = Get-KindFromExceptionType -Exception $item
        if ($kind -eq 'HTTP') { return 'HTTP' }
        if ($kind -ne 'Unknown' -and $fallback -eq 'Unknown') { $fallback = $kind }
    }
    if ($fallback -ne 'Unknown') { return $fallback }
    foreach ($item in $chain) {
        $kind = Get-KindFromMessage -Message ([string]$item.Message)
        if ($kind -ne 'Unknown') { return $kind }
    }
    return 'Unknown'
}

function ConvertTo-StatusCode {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long]) { return [int]$Value }
    if ($Value -is [enum]) { return [int]$Value }
    $text = [string]$Value
    if ($text -match '^\d{3}$') { return [int]$text }
    return $null
}

function Get-StatusCodeFromMessage {
    param([AllowEmptyString()][string]$Message)
    if ($Message -match '\((\d{3})\)') {
        return [int]$Matches[1]
    }
    return $null
}

function Read-HttpWebResponseText {
    param($Response)
    if ($null -eq $Response) { return '' }
    if (-not ($Response -is [System.Net.HttpWebResponse])) { return '' }
    $reader = $null
    try {
        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) { return '' }
        $reader = New-Object System.IO.StreamReader($stream)
        $buffer = New-Object char[] 8192
        $count = $reader.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) { return '' }
        return New-Object System.String($buffer, 0, $count)
    } catch {
        return ''
    } finally {
        if ($reader) { $reader.Dispose() }
    }
}

function Get-WebFailureDetail {
    param($Exception, $ErrorRecord)

    $chain = @()
    if ($Exception) {
        $chain = @(Get-ExceptionChain -Exception $Exception)
    }
    $kind = Get-FailureKindFromException -Exception $Exception
    $statusCode = $null
    $headers = @{}
    $body = ''

    foreach ($item in $chain) {
        $responseProperty = $item.PSObject.Properties['Response']
        if (-not $responseProperty -or $null -eq $responseProperty.Value) { continue }
        $response = $responseProperty.Value
        $parsedStatus = ConvertTo-StatusCode -Value (Get-PropertyValue -Object $response -Name 'StatusCode')
        if ($null -ne $parsedStatus) { $statusCode = $parsedStatus }

        $responseHeaders = ConvertTo-HeaderHashtable -Headers (Get-PropertyValue -Object $response -Name 'Headers')
        foreach ($key in @($responseHeaders.Keys)) {
            $headers[$key] = $responseHeaders[$key]
        }
        $content = Get-PropertyValue -Object $response -Name 'Content'
        if ($content) {
            $contentHeaders = ConvertTo-HeaderHashtable -Headers (Get-PropertyValue -Object $content -Name 'Headers')
            foreach ($key in @($contentHeaders.Keys)) {
                if (-not $headers.ContainsKey($key)) {
                    $headers[$key] = $contentHeaders[$key]
                }
            }
            $mediaType = Get-PropertyValue -Object (Get-PropertyValue -Object $content -Name 'Headers') -Name 'ContentType'
            if ($mediaType -and -not (Get-HeaderValue -Headers $headers -Name 'Content-Type')) {
                $headers['Content-Type'] = [string]$mediaType
            }
        }
        $streamText = Read-HttpWebResponseText -Response $response
        if (-not [string]::IsNullOrEmpty($streamText)) {
            $body = $streamText
        }
    }

    if ([string]::IsNullOrEmpty($body) -and $ErrorRecord) {
        $details = $ErrorRecord.ErrorDetails
        if ($details -and $details.Message) {
            $detailMessage = [string]$details.Message
            $exceptionMessage = ''
            if ($Exception) { $exceptionMessage = [string]$Exception.Message }
            if (-not [string]::IsNullOrWhiteSpace($detailMessage) -and $detailMessage -ne $exceptionMessage) {
                $body = $detailMessage
            }
        }
    }
    if ($body.Length -gt 8192) {
        $body = $body.Substring(0, 8192)
    }

    if ($null -eq $statusCode -and $kind -eq 'HTTP') {
        foreach ($item in $chain) {
            $parsed = Get-StatusCodeFromMessage -Message ([string]$item.Message)
            if ($null -ne $parsed) {
                $statusCode = $parsed
                break
            }
        }
    }

    $detail = ''
    for ($index = $chain.Count - 1; $index -ge 0; $index--) {
        $candidate = [string]$chain[$index].Message
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $detail = $candidate
            break
        }
    }

    return @{
        FailureKind     = $kind
        StatusCode      = $statusCode
        ResponseHeaders = $headers
        ResponseBody    = $body
        Detail          = $detail
    }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-BasicAuthMaterial {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    $userName = [string]$Credential.UserName
    if ([string]::IsNullOrEmpty($userName)) {
        throw 'Basic authentication requires a username. No request was sent.'
    }
    $password = $Credential.GetNetworkCredential().Password
    if ($null -eq $password) { $password = '' }
    if (-not (Test-PrintableAscii -Value $userName) -or -not (Test-PrintableAscii -Value $password)) {
        throw 'Basic authentication in this utility supports printable ASCII credentials only. No request was sent.'
    }

    $encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::ASCII.GetBytes($userName + ':' + $password)
    )
    $headerValue = 'Basic ' + $encoded
    $literals = New-Object System.Collections.Generic.List[string]
    foreach ($literal in @($userName, $password, $encoded, $headerValue)) {
        if (-not [string]::IsNullOrEmpty($literal)) {
            [void]$literals.Add($literal)
        }
    }
    # Never write this object to the pipeline from a caller. It holds secrets.
    return [pscustomobject]@{
        HeaderValue = $headerValue
        Literals    = @($literals)
    }
}

function Enable-DiagnosticTls {
    # Windows PowerShell defaults can be older than TLS 1.2. This selects
    # TLS 1.2 or TLS 1.3 only. It does not change certificate validation.
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        return $null
    }
    $previous = [Net.ServicePointManager]::SecurityProtocol
    $selected = [Net.SecurityProtocolType]::Tls12
    foreach ($name in [enum]::GetNames([Net.SecurityProtocolType])) {
        if ($name -eq 'Tls13') {
            $selected = $selected -bor [Net.SecurityProtocolType]::Tls13
        }
    }
    [Net.ServicePointManager]::SecurityProtocol = $selected
    return $previous
}

function Clear-AuthorizationFromRequest {
    param($RequestParameters)
    if ($null -eq $RequestParameters) { return }
    if (-not ($RequestParameters -is [System.Collections.IDictionary])) { return }
    if (-not $RequestParameters.Contains('Headers')) { return }
    $headers = $RequestParameters['Headers']
    if ($null -eq $headers -or -not ($headers -is [System.Collections.IDictionary])) { return }
    if ($headers.Contains('Authorization')) {
        $headers['Authorization'] = $null
        [void]$headers.Remove('Authorization')
    }
    if ($RequestParameters.Contains('Body')) {
        $RequestParameters['Body'] = $null
        [void]$RequestParameters.Remove('Body')
    }
}

function Read-DiagnosticConfirmation {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    return Read-Host -Prompt $Prompt
}

function Invoke-DiagnosticWebRequest {
    param([Parameter(Mandatory = $true)][hashtable]$RequestParameters)
    # Verbose and debug output from the web cmdlet can include headers.
    return Invoke-WebRequest @RequestParameters -ErrorAction Stop -Verbose:$false -Debug:$false
}

function Invoke-ApiDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri,
        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$UseBasicAuth,
        [hashtable]$Headers,
        [string]$Body,
        [switch]$EmptyJson,
        [switch]$AllowWrite,
        [switch]$ConfirmPost
    )

    $sensitiveLiterals = New-Object System.Collections.Generic.List[string]
    $requestHeaders = @{}
    $previousProtocol = $null
    $invokeParams = $null
    $endpointDisplay = '(not accepted)'
    $methodDisplay = 'GET'
    $authentication = 'None'
    $bodyMode = 'None'
    $requestContentType = ''
    $bodyText = $null

    try {
        if ($PSBoundParameters.ContainsKey('Method') -and -not [string]::IsNullOrWhiteSpace($Method)) {
            $methodDisplay = $Method.ToUpperInvariant()
        }
        if ($methodDisplay -ne 'GET' -and $methodDisplay -ne 'POST') {
            return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'Only GET and POST are supported. No request was sent.'
        }
        if ($UseBasicAuth) { $authentication = 'Basic' }

        if ($null -eq $Uri -or -not $Uri.IsAbsoluteUri) {
            return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'An absolute HTTPS URI is required. No request was sent.'
        }
        if (-not [string]::IsNullOrEmpty($Uri.UserInfo)) {
            $withoutUserInfo = $Uri.Scheme + '://' + $Uri.Host
            if (-not $Uri.IsDefaultPort) { $withoutUserInfo += ':' + $Uri.Port }
            $withoutUserInfo += $Uri.AbsolutePath
            $endpointDisplay = ConvertTo-SanitizedEndpoint -AbsoluteUri $withoutUserInfo -SensitiveLiterals @()
            return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'The URI contains embedded user information. Use -UseBasicAuth instead. No request was sent.'
        }
        $endpointDisplay = ConvertTo-SanitizedEndpoint -AbsoluteUri $Uri.AbsoluteUri -SensitiveLiterals @()
        if ($Uri.Scheme -ne 'https') {
            return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'Only HTTPS endpoints are supported. No request was sent.'
        }
        if ([string]::IsNullOrWhiteSpace($Uri.Host)) {
            return New-NotSentReport -Endpoint '(not accepted)' -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'The URI does not contain a host. No request was sent.'
        }

        if ($PSBoundParameters.ContainsKey('Headers')) {
            if ($null -eq $Headers) {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message 'Headers must be a hashtable. No request was sent.'
            }
            foreach ($key in @($Headers.Keys)) {
                $headerName = [string]$key
                $safeHeaderName = ConvertTo-SanitizedDiagnosticText -Text $headerName -MaxLength 80
                $displayHeaderName = 'a supplied header'
                if ($safeHeaderName.Reliable -and $safeHeaderName.Text) {
                    $displayHeaderName = $safeHeaderName.Text
                }
                if ([string]::IsNullOrWhiteSpace($headerName) -or $headerName -match '[\r\n]' -or -not $safeHeaderName.Reliable) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message ('Refusing ' + $displayHeaderName + '. No request was sent.')
                }
                if (Test-SensitiveHeaderName -Name $headerName) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message ('Refusing header "' + $displayHeaderName + '" because it may carry a secret. Use -UseBasicAuth for Basic authentication. No request was sent.')
                }
                $headerValue = [string]$Headers[$key]
                if ($headerValue -match '[\r\n]') {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -Message ('Refusing header "' + $displayHeaderName + '" because the value contains a line break. No request was sent.')
                }
                if ($headerName -eq 'Content-Type') {
                    $requestContentType = $headerValue
                } else {
                    $requestHeaders[$headerName] = $headerValue
                }
            }
        }

        if ($methodDisplay -eq 'GET') {
            $bodyMode = 'None'
            if ($EmptyJson -or $PSBoundParameters.ContainsKey('Body')) {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'GET does not send a request body. No request was sent.'
            }
        } else {
            if ($EmptyJson -and $PSBoundParameters.ContainsKey('Body')) {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'Use either -EmptyJson or -Body, not both. No request was sent.'
            }
            if ($PSBoundParameters.ContainsKey('Body')) {
                if ([string]::IsNullOrWhiteSpace($Body)) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'The request body is empty. Omit -Body to send no body, or use -EmptyJson to send {}. No request was sent.'
                }
                if ($Body.Length -gt 262144) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'The JSON body is larger than 256 KB. No request was sent.'
                }
                if ($Body.IndexOf([char]0) -ge 0) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'The JSON body contains a NUL character. No request was sent.'
                }
                $jsonAccepted = $true
                try {
                    $null = $Body | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    $jsonAccepted = $false
                }
                if (-not $jsonAccepted) {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode 'Rejected' -RequestContentType $requestContentType -Message 'The request body is not valid JSON. No request was sent.'
                }
                $bodyText = $Body
                if ($Body -match '^\s*\{\s*\}\s*$') {
                    $bodyMode = 'Empty JSON'
                } else {
                    $bodyMode = 'JSON'
                }
            } elseif ($EmptyJson) {
                $bodyText = '{}'
                $bodyMode = 'Empty JSON'
            } else {
                $bodyMode = 'Not supplied'
            }
            if ($null -ne $bodyText -and [string]::IsNullOrWhiteSpace($requestContentType)) {
                $requestContentType = 'application/json; charset=utf-8'
            }
        }

        if ($methodDisplay -eq 'POST') {
            if (-not $AllowWrite) {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -RequestContentType $requestContentType -Message 'POST requires -AllowWrite. No request was sent.'
            }
            if (-not $ConfirmPost) {
                $prompt = 'Type POST to send one POST request to ' + $endpointDisplay + '. Any other response cancels'
                $answer = Read-DiagnosticConfirmation -Prompt $prompt
                if ([string]$answer -cne 'POST') {
                    return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -RequestContentType $requestContentType -Message 'Confirmation was not provided. No request was sent.'
                }
            }
        }

        if ($PSBoundParameters.ContainsKey('Credential') -and -not $UseBasicAuth) {
            return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication 'None' -BodyMode $bodyMode -RequestContentType $requestContentType -Message 'A credential was supplied without -UseBasicAuth. No request was sent.'
        }
        if ($UseBasicAuth -and -not $Credential) {
            try {
                $Credential = Get-Credential -Message 'Enter Basic authentication credentials. They are not saved.'
            } catch {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -RequestContentType $requestContentType -Message 'Credential prompt could not be displayed. No request was sent.'
            }
            if (-not $Credential) {
                return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -RequestContentType $requestContentType -Message 'Credential prompt was cancelled. No request was sent.'
            }
        }
        if ($UseBasicAuth) {
            $material = Get-BasicAuthMaterial -Credential $Credential
            $requestHeaders['Authorization'] = [string]$material.HeaderValue
            foreach ($literal in @($material.Literals)) {
                if (-not [string]::IsNullOrEmpty([string]$literal)) {
                    [void]$sensitiveLiterals.Add([string]$literal)
                }
            }
            $material = $null
            $endpointDisplay = ConvertTo-SanitizedEndpoint -AbsoluteUri $Uri.AbsoluteUri -SensitiveLiterals @($sensitiveLiterals)
        }

        if ($null -ne [Net.ServicePointManager]::ServerCertificateValidationCallback) {
            Write-Warning 'This process already has a custom certificate validation callback. This utility did not change it and did not disable certificate checks.'
        }
        $previousProtocol = Enable-DiagnosticTls

        $invokeParams = @{
            Uri              = $Uri.AbsoluteUri
            Method           = $methodDisplay
            UseBasicParsing  = $true
        }
        # A redirect could resubmit a POST. Do not follow redirects for POST.
        if ($methodDisplay -eq 'POST') {
            $invokeParams['MaximumRedirection'] = 0
        }
        if ($requestHeaders.Count -gt 0) {
            $invokeParams['Headers'] = $requestHeaders
        }
        if (-not [string]::IsNullOrWhiteSpace($requestContentType)) {
            $invokeParams['ContentType'] = $requestContentType
        }
        if ($null -ne $bodyText) {
            $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
            $invokeParams['Body'] = $utf8.GetBytes($bodyText)
        }

        $literalArray = @($sensitiveLiterals)
        try {
            $response = Invoke-DiagnosticWebRequest -RequestParameters $invokeParams
            $responseHeaders = ConvertTo-HeaderHashtable -Headers (Get-PropertyValue -Object $response -Name 'Headers')
            $contentText = ''
            $contentValue = Get-PropertyValue -Object $response -Name 'Content'
            if ($null -ne $contentValue) {
                $contentText = [string]$contentValue
                if ($contentText.Length -gt 8192) {
                    $contentText = $contentText.Substring(0, 8192)
                }
            }
            $statusValue = ConvertTo-StatusCode -Value (Get-PropertyValue -Object $response -Name 'StatusCode')
            return Get-ApiDiagnosticReportText `
                -Endpoint $Uri.AbsoluteUri `
                -Method $methodDisplay `
                -Authentication $authentication `
                -BodyMode $bodyMode `
                -RequestContentType $requestContentType `
                -FailureKind 'HTTP' `
                -StatusCode $statusValue `
                -ResponseHeaders $responseHeaders `
                -ResponseBody $contentText `
                -Detail '' `
                -SensitiveLiterals $literalArray `
                -RequestSent $true
        } catch {
            $caught = $_
            $failure = Get-WebFailureDetail -Exception $caught.Exception -ErrorRecord $caught
            try {
                if ($Error.Count -gt 0 -and $Error[0].Exception -and $caught.Exception -and $Error[0].Exception.Message -eq $caught.Exception.Message) {
                    $Error.RemoveAt(0)
                }
            } catch {
                # The session error list is left unchanged when it cannot be edited.
            }
            return Get-ApiDiagnosticReportText `
                -Endpoint $Uri.AbsoluteUri `
                -Method $methodDisplay `
                -Authentication $authentication `
                -BodyMode $bodyMode `
                -RequestContentType $requestContentType `
                -FailureKind ([string]$failure['FailureKind']) `
                -StatusCode $failure['StatusCode'] `
                -ResponseHeaders $failure['ResponseHeaders'] `
                -ResponseBody ([string]$failure['ResponseBody']) `
                -Detail ([string]$failure['Detail']) `
                -SensitiveLiterals $literalArray `
                -RequestSent $true
        }
    } catch {
        $safeUnexpected = ConvertTo-SanitizedDiagnosticText -Text $_.Exception.Message -SensitiveLiterals @($sensitiveLiterals) -MaxLength 400
        $unexpected = 'The diagnostic stopped before a result was produced. No request was sent.'
        if ($safeUnexpected.Reliable -and $safeUnexpected.Text) {
            $unexpected = $safeUnexpected.Text
        }
        return New-NotSentReport -Endpoint $endpointDisplay -Method $methodDisplay -Authentication $authentication -BodyMode $bodyMode -RequestContentType $requestContentType -Message $unexpected
    } finally {
        Clear-AuthorizationFromRequest -RequestParameters $invokeParams
        if ($requestHeaders.Contains('Authorization')) {
            $requestHeaders['Authorization'] = $null
            [void]$requestHeaders.Remove('Authorization')
        }
        if ($null -ne $previousProtocol) {
            [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        }
        if ($sensitiveLiterals) {
            $sensitiveLiterals.Clear()
        }
    }
}

$dotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $dotSourced -and $MyInvocation.Line -match '^\s*\.\s+') {
    $dotSourced = $true
}
if (-not $dotSourced) {
    if (-not $PSBoundParameters.ContainsKey('Uri')) {
        Write-Output @"
API Diagnostic
----------------------------

No request was sent.
An absolute HTTPS URI is required.
Run: Get-Help .\Invoke-ApiDiagnostic.ps1 -Full
"@
    } else {
        Invoke-ApiDiagnostic @PSBoundParameters
    }
}
