# Offline tests for Invoke-ApiDiagnostic.ps1.
# These tests must not contact a network. The web cmdlets are replaced
# before the utility is loaded, and every scenario uses a .invalid hostname.
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:Secrets = @(
    'example-password',
    'example-user',
    'example-token-value',
    'example-session-cookie',
    'example-internal-route'
)

function Invoke-WebRequest {
    throw 'NETWORK BLOCKED'
}

function Invoke-RestMethod {
    throw 'NETWORK BLOCKED'
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Output ("PASS  " + $Name)
    } else {
        $script:Failed++
        Write-Output ("FAIL  " + $Name)
    }
}

function Test-TextIsSafe {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    foreach ($secret in $script:Secrets) {
        if ($Text.IndexOf($secret, [System.StringComparison]::Ordinal) -ge 0) {
            return $false
        }
    }
    if (-not [string]::IsNullOrEmpty($script:EncodedCredential)) {
        if ($Text.IndexOf($script:EncodedCredential, [System.StringComparison]::Ordinal) -ge 0) {
            return $false
        }
    }
    return $true
}

function Show-SafeReport {
    param([string]$Text)
    if (Test-TextIsSafe -Text $Text) {
        Write-Output $Text
    } else {
        Write-Output '  report suppressed because it contained a test secret'
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Needed, [string]$Name)
    $ok = $false
    if ($null -ne $Text -and $Text.Contains($Needed)) { $ok = $true }
    Assert-True $ok $Name
    if (-not $ok) { Show-SafeReport -Text $Text }
}

function Assert-SecretAbsent {
    param([string]$Text, [string]$Secret, [string]$Name)
    $present = $false
    if (-not [string]::IsNullOrEmpty($Secret) -and $null -ne $Text) {
        if ($Text.IndexOf($Secret, [System.StringComparison]::Ordinal) -ge 0) {
            $present = $true
        }
    }
    Assert-True (-not $present) $Name
}

function Reset-Transport {
    $script:Calls = 0
    $script:LastMethod = $null
    $script:LastBody = $null
    $script:LastHadBody = $false
    $script:LastContentType = $null
    $script:LastRedirect = $null
    $script:LastHadAuthorization = $false
    $script:LastAuthorization = $null
    $script:Transport = 'return'
    $script:FakeStatus = 200
    $script:FakeContent = '{}'
    $script:FakeHeaders = @{ 'Content-Type' = 'application/json' }
    $script:NextConfirmation = 'no'
}

function New-ExampleCredential {
    $secure = ConvertTo-SecureString 'example-password' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential('example-user', $secure)
}

function New-WebException {
    param([string]$Message, [System.Net.WebExceptionStatus]$Status)
    return New-Object System.Net.WebException($Message, $null, $Status, $null)
}

$utilityPath = Join-Path $PSScriptRoot '..\Invoke-ApiDiagnostic.ps1'
$utilityPath = (Resolve-Path -LiteralPath $utilityPath).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$beforeFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | ForEach-Object { $_.FullName })

$webCommand = Get-Command Invoke-WebRequest
Assert-True ($webCommand.CommandType -eq 'Function') 'Invoke-WebRequest is overridden before the utility is loaded'
if ($webCommand.CommandType -ne 'Function') {
    Write-Output 'STOP  refusing to continue because a live web cmdlet is visible'
    exit 1
}

$dotOutput = @( . $utilityPath *>&1 | ForEach-Object { "$_" } )
Assert-True ($dotOutput.Count -eq 0) 'Dot-sourcing the utility produces no output and sends no request'

$loadedWebCommand = Get-Command Invoke-WebRequest
Assert-True ($loadedWebCommand.CommandType -eq 'Function') 'Invoke-WebRequest remains overridden after dot-sourcing'
if ($loadedWebCommand.CommandType -ne 'Function') {
    Write-Output 'STOP  refusing to continue because a live web cmdlet is visible'
    exit 1
}

$utilityText = Get-Content -LiteralPath $utilityPath -Raw
Assert-True (-not ($utilityText -match 'SkipCertificateCheck')) 'Source does not skip certificate checks'
Assert-True (-not ($utilityText -match 'ServerCertificateValidationCallback\s*=')) 'Source does not assign a certificate validation callback'
foreach ($forbidden in @('Out-File', 'Set-Content', 'Add-Content', 'Start-Transcript', 'Export-Clixml', 'OutFile')) {
    Assert-True (-not ($utilityText -match [regex]::Escape($forbidden))) ("Source does not contain " + $forbidden)
}
$transportMentions = ([regex]::Matches($utilityText, 'Invoke-DiagnosticWebRequest')).Count
Assert-True ($transportMentions -eq 2) 'The web transport is defined once and called once'

function Read-DiagnosticConfirmation {
    param([string]$Prompt)
    $script:ConfirmationPrompts++
    return $script:NextConfirmation
}

function Invoke-DiagnosticWebRequest {
    param([hashtable]$RequestParameters)
    $script:Calls++
    $script:LastMethod = [string]$RequestParameters['Method']
    $script:LastHadBody = $RequestParameters.ContainsKey('Body')
    $script:LastBody = $null
    if ($script:LastHadBody -and $null -ne $RequestParameters['Body']) {
        $script:LastBody = [System.Text.Encoding]::UTF8.GetString([byte[]]$RequestParameters['Body'])
    }
    $script:LastContentType = $null
    if ($RequestParameters.ContainsKey('ContentType')) {
        $script:LastContentType = [string]$RequestParameters['ContentType']
    }
    $script:LastRedirect = $null
    if ($RequestParameters.ContainsKey('MaximumRedirection')) {
        $script:LastRedirect = $RequestParameters['MaximumRedirection']
    }
    $script:LastHadAuthorization = $false
    $script:LastAuthorization = $null
    if ($RequestParameters.ContainsKey('Headers') -and $RequestParameters['Headers'].ContainsKey('Authorization')) {
        $script:LastHadAuthorization = $true
        $script:LastAuthorization = [string]$RequestParameters['Headers']['Authorization']
    }

    if ($script:Transport -eq 'dns') {
        throw (New-WebException -Message "The remote name could not be resolved: 'ops-toolkit.invalid'" -Status NameResolutionFailure)
    }
    if ($script:Transport -eq 'tls') {
        throw (New-WebException -Message 'The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.' -Status TrustFailure)
    }
    if ($script:Transport -eq 'connection') {
        throw (New-WebException -Message 'Unable to connect to the remote server' -Status ConnectFailure)
    }
    if ($script:Transport -eq 'timeout') {
        throw (New-WebException -Message 'The operation has timed out' -Status Timeout)
    }
    if ($script:Transport -eq 'protocol') {
        $protocolMessage = 'The remote server returned an error: (' + $script:FakeStatus + ') .'
        throw (New-WebException -Message $protocolMessage -Status ProtocolError)
    }

    return [pscustomobject]@{
        StatusCode = $script:FakeStatus
        Headers    = $script:FakeHeaders
        Content    = $script:FakeContent
    }
}

$script:EncodedCredential = [Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes('example-user:example-password')
)
$script:Secrets += $script:EncodedCredential
$script:Secrets += ('Basic ' + $script:EncodedCredential)

$baseUri = 'https://ops-toolkit.invalid/diagnostic'

try {
    Reset-Transport
    $getReport = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-True ($script:Calls -eq 1) 'Default GET sends exactly one request'
    Assert-True ($script:LastMethod -eq 'GET') 'Default method is GET'
    Assert-Contains $getReport 'Method: GET' 'GET report names the method'
    Assert-Contains $getReport 'Request completed.' 'GET report says the request completed'
    Assert-Contains $getReport 'No automatic retry performed.' 'GET report says no retry was performed'
    Assert-True ($null -eq $script:LastRedirect) 'GET does not force a second submission through redirect settings'
    Assert-True (-not ($getReport -match '(?m)^(True|False)$')) 'Report does not include leaked boolean output'

    Reset-Transport
    $blocked = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -ConfirmPost
    Assert-True ($script:Calls -eq 0) 'POST without -AllowWrite does not send'
    Assert-Contains $blocked 'POST requires -AllowWrite' 'POST without -AllowWrite explains why'
    Assert-Contains $blocked 'No request was sent.' 'Blocked POST says nothing was sent'
    Assert-Contains $blocked 'No automatic retry performed.' 'Blocked POST says no retry was performed'

    Reset-Transport
    $script:NextConfirmation = 'post'
    $script:ConfirmationPrompts = 0
    $needsWord = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite
    Assert-True ($script:Calls -eq 0) 'POST is not sent when confirmation is not the word POST'
    Assert-True ($script:ConfirmationPrompts -eq 1) 'POST without -ConfirmPost asks for confirmation'
    Assert-Contains $needsWord 'Confirmation was not provided' 'Rejected confirmation is reported'

    Reset-Transport
    $script:NextConfirmation = 'POST'
    $confirmed = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite
    Assert-True ($script:Calls -eq 1) 'Typing POST sends one request'
    Assert-True ($script:LastMethod -eq 'POST') 'Confirmed request uses POST'
    Assert-True ($script:LastRedirect -eq 0) 'POST disables redirect following'
    Assert-True (-not $script:LastHadBody) 'Confirmed POST without a body sends no body'
    Assert-Contains $confirmed 'Request Body: Not supplied' 'Missing POST body is labeled Not supplied'
    Assert-Contains $confirmed 'Request Content Type: Not set' 'Missing POST body does not invent a content type'

    Reset-Transport
    $empty = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -EmptyJson
    Assert-True ($script:Calls -eq 1) 'Empty JSON POST sends one request'
    Assert-True ($script:LastBody -eq '{}') 'Empty JSON POST sends exactly {}'
    Assert-True ($script:LastContentType -eq 'application/json; charset=utf-8') 'Empty JSON POST sets a JSON content type'
    Assert-Contains $empty 'Request Body: Empty JSON' 'Empty JSON is labeled Empty JSON'
    Assert-True ($script:LastRedirect -eq 0) 'Empty JSON POST is not retried through a redirect'

    Reset-Transport
    $payload = '{"action":"validate","id":"example"}'
    $json = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -Body $payload
    Assert-True ($script:LastBody -eq $payload) 'Custom JSON is sent without being rewritten'
    Assert-Contains $json 'Request Body: JSON' 'Custom JSON is not labeled as empty JSON'
    Assert-True ($script:LastBody -ne '{}') 'Custom JSON is distinct from {}'

    Reset-Transport
    $spaced = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -Body '{ }'
    Assert-True ($script:LastBody -eq '{ }') 'A supplied empty object keeps its original text'
    Assert-Contains $spaced 'Request Body: Empty JSON' 'Whitespace-only object is still empty JSON'

    Reset-Transport
    $both = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -EmptyJson -Body '{}'
    Assert-True ($script:Calls -eq 0) 'Body and -EmptyJson together do not send'
    Assert-Contains $both 'not both' 'Body and -EmptyJson conflict is explained'

    Reset-Transport
    $badJson = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -Body '{'
    Assert-True ($script:Calls -eq 0) 'Invalid JSON does not send'
    Assert-Contains $badJson 'not valid JSON' 'Invalid JSON is explained'

    Reset-Transport
    $getBody = Invoke-ApiDiagnostic -Uri $baseUri -EmptyJson
    Assert-True ($script:Calls -eq 0) 'GET with a body does not send'
    Assert-Contains $getBody 'GET does not send a request body' 'GET body refusal is explained'

    Reset-Transport
    $httpUri = Invoke-ApiDiagnostic -Uri 'http://ops-toolkit.invalid/diagnostic'
    Assert-True ($script:Calls -eq 0) 'HTTP URIs do not send'
    Assert-Contains $httpUri 'Only HTTPS' 'HTTP refusal names HTTPS'

    Reset-Transport
    $userInfo = Invoke-ApiDiagnostic -Uri 'https://example-user:example-password@ops-toolkit.invalid/diagnostic'
    Assert-True ($script:Calls -eq 0) 'URIs with embedded credentials do not send'
    Assert-SecretAbsent $userInfo 'example-password' 'Embedded password is not displayed'
    Assert-SecretAbsent $userInfo 'example-user' 'Embedded username is not displayed'
    Assert-Contains $userInfo 'embedded user information' 'Embedded user information is refused'

    Reset-Transport
    $secretHeader = Invoke-ApiDiagnostic -Uri $baseUri -Headers @{ 'X-Api-Key' = 'example-token-value' }
    Assert-True ($script:Calls -eq 0) 'Secret-bearing request headers do not send'
    Assert-SecretAbsent $secretHeader 'example-token-value' 'Rejected header value is not displayed'

    Reset-Transport
    $plainCredential = New-ExampleCredential
    $unusedCredential = Invoke-ApiDiagnostic -Uri $baseUri -Credential $plainCredential
    Assert-True ($script:Calls -eq 0) 'A credential without -UseBasicAuth does not send'
    Assert-SecretAbsent $unusedCredential 'example-password' 'Unused credential password is not displayed'

    Reset-Transport
    $protocolBefore = $null
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $protocolBefore = [Net.ServicePointManager]::SecurityProtocol
    }
    $credential = New-ExampleCredential
    $script:FakeStatus = 400
    $script:FakeContent = '{"message":"rejected example-password for this call","token":"example-token-value","password":"example-password"}'
    $script:FakeHeaders = @{
        'Content-Type'    = 'application/json'
        'Set-Cookie'      = 'session=example-session-cookie'
        'Authorization'   = 'Bearer example-token-value'
        'X-Request-Id'    = 'req-12345'
        'X-Environment'   = 'example-internal-route'
    }
    $authed = Invoke-ApiDiagnostic -Uri ($baseUri + '?token=example-token-value&id=example') -UseBasicAuth -Credential $credential
    $authorizationCopy = $script:LastAuthorization
    $script:LastAuthorization = $null
    Assert-True ($script:Calls -eq 1) 'Authenticated GET sends one request'
    Assert-True ($script:LastHadAuthorization) 'Basic authentication is applied to the request'
    Assert-True ($authorizationCopy -eq ('Basic ' + $script:EncodedCredential)) 'Basic header matches the supplied credential'
    $authorizationCopy = $null
    Assert-Contains $authed 'Authentication: Basic' 'Report names Basic authentication without the secret'
    Assert-Contains $authed 'HTTP Status: 400' 'Returned HTTP 400 is reported'
    Assert-Contains $authed 'Category: Bad Request' 'HTTP 400 category is Bad Request'
    Assert-Contains $authed 'rejected [REDACTED] for this call' 'Password inside an API message is redacted'
    Assert-Contains $authed 'not equivalent' 'HTTP 400 hint compares the POST body forms'
    Assert-Contains $authed 'X-Request-Id: req-12345' 'Correlation header value is kept'
    Assert-Contains $authed 'Set-Cookie: [REDACTED]' 'Set-Cookie is redacted'
    Assert-Contains $authed 'Authorization: [REDACTED]' 'Response authorization header is redacted'
    Assert-Contains $authed 'X-Environment: [not displayed]' 'Unknown response header values are hidden'
    Assert-Contains $authed 'token=[REDACTED]' 'Sensitive query values are redacted'
    Assert-Contains $authed 'id=example' 'Ordinary query values are kept'
    Assert-Contains $authed 'No automatic retry performed.' 'Authenticated report says no retry was performed'
    Assert-SecretAbsent $authed 'example-password' 'Password is absent from the report'
    Assert-SecretAbsent $authed 'example-user' 'Username is absent from the report'
    Assert-SecretAbsent $authed 'example-token-value' 'Token is absent from the report'
    Assert-SecretAbsent $authed 'example-session-cookie' 'Session cookie is absent from the report'
    Assert-SecretAbsent $authed 'example-internal-route' 'Hidden header value is absent from the report'
    Assert-SecretAbsent $authed $script:EncodedCredential 'Encoded credential is absent from the report'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $protocolAfter = [Net.ServicePointManager]::SecurityProtocol
        Assert-True ($protocolBefore -eq $protocolAfter) 'TLS protocol setting is restored'
    }

    foreach ($status in @(400, 401, 403)) {
        Reset-Transport
        $script:Transport = 'protocol'
        $script:FakeStatus = $status
        $protocolReport = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -EmptyJson
        Assert-True ($script:Calls -eq 1) ("HTTP " + $status + " exception is attempted once")
        Assert-Contains $protocolReport ("HTTP Status: " + $status) ("HTTP " + $status + " status is reported from the exception")
        Assert-Contains $protocolReport 'No automatic retry performed.' ("HTTP " + $status + " is not retried")
    }
    Reset-Transport
    $script:Transport = 'protocol'
    $script:FakeStatus = 401
    $unauthorized = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-Contains $unauthorized 'Category: Unauthorized' 'HTTP 401 category is Unauthorized'
    Reset-Transport
    $script:Transport = 'protocol'
    $script:FakeStatus = 403
    $forbidden = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-Contains $forbidden 'Category: Forbidden' 'HTTP 403 category is Forbidden'

    $simulated400 = Get-ApiDiagnosticReportText `
        -Endpoint 'https://api.example.com/v1/jobs?token=example-token-value' `
        -Method 'POST' `
        -Authentication 'Basic' `
        -BodyMode 'Empty JSON' `
        -RequestContentType 'application/json; charset=utf-8' `
        -FailureKind 'HTTP' `
        -StatusCode 400 `
        -ResponseHeaders @{ 'Content-Type' = 'application/json' } `
        -ResponseBody '{"message":"name is required","token":"example-token-value"}' `
        -Detail '' `
        -SensitiveLiterals @('example-token-value') `
        -RequestSent $true
    Assert-Contains $simulated400 'Request Body: Empty JSON' 'Simulated 400 shows the empty JSON body mode'
    Assert-Contains $simulated400 'HTTP Status: 400' 'Simulated 400 shows the status'
    Assert-Contains $simulated400 'Category: Bad Request' 'Simulated 400 shows Bad Request'
    Assert-Contains $simulated400 'Message: name is required' 'Simulated 400 shows the safe message field'
    Assert-SecretAbsent $simulated400 'example-token-value' 'Simulated 400 omits a sibling token field'
    Assert-Contains $simulated400 'Request completed.' 'Simulated 400 says the request completed'

    $simulated401 = Get-ApiDiagnosticReportText `
        -Endpoint 'https://api.example.com/v1/status' `
        -Method 'GET' `
        -Authentication 'Basic' `
        -BodyMode 'None' `
        -RequestContentType 'Not set' `
        -FailureKind 'HTTP' `
        -StatusCode 401 `
        -ResponseHeaders @{ 'Content-Type' = 'application/json' } `
        -ResponseBody '{"message":"authentication failed"}' `
        -Detail '' `
        -SensitiveLiterals @() `
        -RequestSent $true
    Assert-Contains $simulated401 'Category: Unauthorized' 'Simulated 401 shows Unauthorized'
    Assert-Contains $simulated401 'authentication failed' 'Simulated 401 shows the safe message'

    $simulated403 = Get-ApiDiagnosticReportText `
        -Endpoint 'https://api.example.com/v1/status' `
        -Method 'GET' `
        -Authentication 'Basic' `
        -BodyMode 'None' `
        -RequestContentType 'Not set' `
        -FailureKind 'HTTP' `
        -StatusCode 403 `
        -ResponseHeaders @{ 'Content-Type' = 'text/plain' } `
        -ResponseBody 'not allowed to perform this action' `
        -Detail '' `
        -SensitiveLiterals @() `
        -RequestSent $true
    Assert-Contains $simulated403 'Category: Forbidden' 'Simulated 403 shows Forbidden'
    Assert-Contains $simulated403 'not allowed to perform this action' 'Simulated 403 shows plain text'

    $unsafe = Get-ApiDiagnosticReportText `
        -Endpoint 'https://api.example.com/v1/status' `
        -Method 'GET' `
        -Authentication 'None' `
        -BodyMode 'None' `
        -RequestContentType 'Not set' `
        -FailureKind 'HTTP' `
        -StatusCode 400 `
        -ResponseHeaders @{ 'Content-Type' = 'application/json' } `
        -ResponseBody '{"message":"-----BEGIN PRIVATE KEY----- ABC"}' `
        -Detail '' `
        -SensitiveLiterals @() `
        -RequestSent $true
    Assert-SecretAbsent $unsafe 'BEGIN PRIVATE KEY' 'Unsafe response text is not displayed'
    Assert-Contains $unsafe 'omitted because it could not be sanitized safely' 'Unsafe response text says it was omitted'

    $dnsException = New-WebException -Message "The remote name could not be resolved: 'ops-toolkit.invalid'" -Status NameResolutionFailure
    $tlsInner = New-Object System.Security.Authentication.AuthenticationException('The remote certificate is invalid according to the validation procedure.')
    $tlsException = New-Object System.Net.WebException('The SSL connection could not be established.', $tlsInner, [System.Net.WebExceptionStatus]::SecureChannelFailure, $null)
    $connectionException = New-WebException -Message 'Unable to connect to the remote server' -Status ConnectFailure
    Assert-True ((Get-FailureKindFromException -Exception $dnsException) -eq 'DNS') 'DNS exceptions are classified as DNS'
    Assert-True ((Get-FailureKindFromException -Exception $tlsException) -eq 'TLS') 'TLS exceptions are classified as TLS'
    Assert-True ((Get-FailureKindFromException -Exception $connectionException) -eq 'Connection') 'Connection exceptions are classified as Connection'

    Reset-Transport
    $script:Transport = 'dns'
    $dnsReport = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-True ($script:Calls -eq 1) 'DNS failure is attempted once'
    Assert-Contains $dnsReport 'Category: DNS' 'DNS failure category is DNS'
    Assert-Contains $dnsReport 'HTTP Status: Not available' 'DNS failure has no HTTP status'
    Assert-Contains $dnsReport 'Request finished without an HTTP status.' 'DNS failure does not claim an HTTP response'
    Assert-Contains $dnsReport 'No automatic retry performed.' 'DNS failure is not retried'

    Reset-Transport
    $script:Transport = 'tls'
    $tlsReport = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-Contains $tlsReport 'Category: TLS' 'TLS failure category is TLS'
    Assert-Contains $tlsReport 'Certificate checks were not disabled.' 'TLS failure states that checks stayed enabled'
    Assert-Contains $tlsReport 'Certificate validation was not disabled.' 'TLS hint does not suggest bypassing validation'

    Reset-Transport
    $script:Transport = 'connection'
    $connectionReport = Invoke-ApiDiagnostic -Uri $baseUri
    Assert-Contains $connectionReport 'Category: Connection' 'Connection failure category is Connection'
    Assert-True ($script:Calls -eq 1) 'Connection failure is not retried'

    Reset-Transport
    $script:Transport = 'connection'
    $postFailure = Invoke-ApiDiagnostic -Uri $baseUri -Method POST -AllowWrite -ConfirmPost -Body '{"action":"validate"}'
    Assert-True ($script:Calls -eq 1) 'A failed POST is not retried'
    Assert-Contains $postFailure 'No automatic retry performed.' 'Failed POST says no retry was performed'

    $success = Get-ApiDiagnosticReportText `
        -Endpoint 'https://api.example.com/v1/status' `
        -Method 'GET' `
        -Authentication 'None' `
        -BodyMode 'None' `
        -RequestContentType 'Not set' `
        -FailureKind 'HTTP' `
        -StatusCode 200 `
        -ResponseHeaders @{ 'Content-Type' = 'application/json' } `
        -ResponseBody '{"password":"example-password","secret":"example-token-value"}' `
        -Detail '' `
        -SensitiveLiterals @('example-password', 'example-token-value') `
        -RequestSent $true
    Assert-Contains $success 'Category: Success' 'HTTP 200 category is Success'
    Assert-Contains $success 'response body is not displayed' 'Successful response body is not displayed'
    Assert-SecretAbsent $success 'example-password' 'Successful response does not show a password field'
    Assert-SecretAbsent $success 'example-token-value' 'Successful response does not show a token field'

    $bearer = ConvertTo-SanitizedDiagnosticText -Text 'Authorization: Bearer example-token-value.extra'
    Assert-True ($bearer.Reliable) 'Bearer text can be sanitized'
    Assert-SecretAbsent $bearer.Text 'example-token-value' 'Bearer token text is redacted'

    $afterFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | ForEach-Object { $_.FullName })
    $fileDiff = Compare-Object -ReferenceObject $beforeFiles -DifferenceObject $afterFiles
    Assert-True ($null -eq $fileDiff) 'No files were created or removed'
} catch {
    $script:Failed++
    $failureText = [string]$_.Exception.Message
    if (-not (Test-TextIsSafe -Text $failureText)) {
        $failureText = 'unhandled error contained a test secret and was suppressed'
    }
    Write-Output ("FAIL  unhandled error: " + $failureText)
} finally {
    $script:LastAuthorization = $null
    $script:EncodedCredential = $null
    Remove-Item -LiteralPath Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
}

Write-Output ("Passed: " + $script:Passed)
Write-Output ("Failed: " + $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
