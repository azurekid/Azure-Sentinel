<#
    .SYNOPSIS
        Bitwarden → Microsoft Sentinel data connector (Azure Function – Timer Trigger)

    .DESCRIPTION
        Pulls three data types from the Bitwarden Public API every 5 minutes and
        ingests them into Microsoft Sentinel via the Azure Monitor Logs Ingestion API
        (DCR-based ingestion):

            BitwardenEventLogs_CL  – organisation audit events (5-min sliding window)
            BitwardenMembers_CL    – organisation member list  (full snapshot)
            BitwardenGroups_CL     – organisation group list   (full snapshot)

        Supports Bitwarden Cloud US, Bitwarden Cloud EU, and self-hosted servers.

    .NOTES
        Reference: https://bitwarden.com/help/public-api/
#>

param($Timer)

Set-StrictMode -Off   # JSON responses may have missing/optional properties

# ---------------------------------------------------------------------------
# Region: Configuration
# ---------------------------------------------------------------------------

$currentUTCtime = [System.DateTime]::UtcNow

Write-Host "Bitwarden connector started at $($currentUTCtime.ToString('o'))"

if ($Timer.IsPastDue) {
    Write-Warning "Timer is past due – execution was delayed."
}

# --- Bitwarden ---
$BitwardenClientId     = $env:BITWARDEN_CLIENT_ID
$BitwardenClientSecret = $env:BITWARDEN_CLIENT_SECRET
$BitwardenCloudRegion  = if ($env:BITWARDEN_CLOUD_REGION) { $env:BITWARDEN_CLOUD_REGION.ToLower().Trim() } else { 'us' }
$BitwardenIdentityUrl  = $env:BITWARDEN_IDENTITY_URL
$BitwardenApiUrl       = $env:BITWARDEN_API_URL
$EventLookbackMinutes  = if ($env:BITWARDEN_EVENT_LOOKBACK_MINUTES) { [int]$env:BITWARDEN_EVENT_LOOKBACK_MINUTES } else { 5 }

# --- Azure Monitor / DCR ---
$DceEndpoint           = $env:AZURE_DCE_ENDPOINT
$DcrEventsImmutableId  = $env:AZURE_DCR_EVENTS_IMMUTABLEID
$DcrMembersImmutableId = $env:AZURE_DCR_MEMBERS_IMMUTABLEID
$DcrGroupsImmutableId  = $env:AZURE_DCR_GROUPS_IMMUTABLEID

# --- Key Vault (optional) ---
$KeyVaultUri           = $env:KEY_VAULT_URI
$KeyVaultSecretName    = if ($env:KEY_VAULT_SECRET_NAME) { $env:KEY_VAULT_SECRET_NAME } else { 'bitwarden-client-secret' }

# --- Retry settings ---
$MaxRetries            = 3
$InitialBackoffSeconds = 2
$MaxBackoffSeconds     = 60

# ---------------------------------------------------------------------------
# Region: Input validation
# ---------------------------------------------------------------------------

function Assert-Required {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required environment variable '$Name' is not set or empty."
    }
}

Assert-Required $BitwardenClientId 'BITWARDEN_CLIENT_ID'
Assert-Required $DceEndpoint       'AZURE_DCE_ENDPOINT'
Assert-Required $DcrEventsImmutableId  'AZURE_DCR_EVENTS_IMMUTABLEID'
Assert-Required $DcrMembersImmutableId 'AZURE_DCR_MEMBERS_IMMUTABLEID'
Assert-Required $DcrGroupsImmutableId  'AZURE_DCR_GROUPS_IMMUTABLEID'

# ---------------------------------------------------------------------------
# Region: Resolve Bitwarden endpoint URLs
# ---------------------------------------------------------------------------
#
# Resolution order (first match wins):
#   1. Explicit BITWARDEN_IDENTITY_URL + BITWARDEN_API_URL  (self-hosted)
#   2. BITWARDEN_CLOUD_REGION = 'us' | 'eu'
#   3. Default: Cloud US

$cloudEndpoints = @{
    'us' = @{ identity = 'https://identity.bitwarden.com'; api = 'https://api.bitwarden.com' }
    'eu' = @{ identity = 'https://identity.bitwarden.eu';  api = 'https://api.bitwarden.eu'  }
}

if (-not [string]::IsNullOrWhiteSpace($BitwardenIdentityUrl) -or
    -not [string]::IsNullOrWhiteSpace($BitwardenApiUrl)) {

    if ([string]::IsNullOrWhiteSpace($BitwardenIdentityUrl) -or
        [string]::IsNullOrWhiteSpace($BitwardenApiUrl)) {
        throw "Both BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL must be set together for self-hosted deployments. Only one was provided."
    }

    $IdentityBaseUrl = $BitwardenIdentityUrl.TrimEnd('/')
    $ApiBaseUrl      = $BitwardenApiUrl.TrimEnd('/')
    Write-Host "Using self-hosted Bitwarden URLs – identity: $IdentityBaseUrl, api: $ApiBaseUrl"

} elseif ($cloudEndpoints.ContainsKey($BitwardenCloudRegion)) {

    $IdentityBaseUrl = $cloudEndpoints[$BitwardenCloudRegion].identity
    $ApiBaseUrl      = $cloudEndpoints[$BitwardenCloudRegion].api
    Write-Host "Using Bitwarden Cloud $($BitwardenCloudRegion.ToUpper()) endpoints."

} else {
    throw "Unknown BITWARDEN_CLOUD_REGION '$BitwardenCloudRegion'. Valid values: us, eu. For self-hosted, set BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL."
}

# ---------------------------------------------------------------------------
# Region: Retrieve client_secret (Key Vault preferred, env var fallback)
# ---------------------------------------------------------------------------

function Get-BitwardenClientSecret {
    param(
        [string]$KeyVaultUri,
        [string]$SecretName,
        [string]$EnvFallback
    )

    if (-not [string]::IsNullOrWhiteSpace($KeyVaultUri)) {
        try {
            Write-Host "Retrieving Bitwarden client_secret from Key Vault: $KeyVaultUri / $SecretName"
            $secret = Get-AzKeyVaultSecret -VaultName ([System.Uri]::new($KeyVaultUri).Host.Split('.')[0]) `
                                           -Name $SecretName `
                                           -AsPlainText -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($secret)) {
                Write-Host "Bitwarden client_secret retrieved from Key Vault."
                return $secret
            }
        } catch {
            Write-Warning "Failed to retrieve secret from Key Vault: $_. Falling back to environment variable."
        }
    }

    if ([string]::IsNullOrWhiteSpace($EnvFallback)) {
        throw "Bitwarden client_secret not found. Set BITWARDEN_CLIENT_SECRET or configure KEY_VAULT_URI / KEY_VAULT_SECRET_NAME."
    }

    Write-Host "Using Bitwarden client_secret from environment variable."
    return $EnvFallback
}

$ResolvedClientSecret = Get-BitwardenClientSecret `
    -KeyVaultUri  $KeyVaultUri `
    -SecretName   $KeyVaultSecretName `
    -EnvFallback  $BitwardenClientSecret

# ---------------------------------------------------------------------------
# Region: Bitwarden – OAuth2 token (client_credentials, cached)
# ---------------------------------------------------------------------------

# Module-scope token cache (lives for the duration of this execution)
$script:BwAccessToken  = $null
$script:BwTokenExpires = [System.DateTime]::MinValue
$TokenExpiryBufferSec  = 60

function Get-BitwardenToken {
    param(
        [string]$IdentityBaseUrl,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $now = [System.DateTime]::UtcNow

    if ($script:BwAccessToken -and $now -lt $script:BwTokenExpires) {
        return $script:BwAccessToken
    }

    $tokenUrl = "$IdentityBaseUrl/connect/token"
    $body = "grant_type=client_credentials&scope=api.organization&client_id=$([System.Uri]::EscapeDataString($ClientId))&client_secret=$([System.Uri]::EscapeDataString($ClientSecret))"

    Write-Host "Requesting Bitwarden access token from $tokenUrl"

    $response = Invoke-RestMethod `
        -Uri     $tokenUrl `
        -Method  POST `
        -Headers @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/x-www-form-urlencoded' } `
        -Body    $body `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Bitwarden token response did not contain 'access_token'."
    }

    $expiresIn = if ($response.expires_in) { [int]$response.expires_in } else { 3600 }
    $script:BwAccessToken  = $response.access_token
    $script:BwTokenExpires = $now.AddSeconds($expiresIn - $TokenExpiryBufferSec)

    Write-Host "Bitwarden access token obtained. Valid until ~$($script:BwTokenExpires.ToString('HH:mm:ss')) UTC."
    return $script:BwAccessToken
}

# ---------------------------------------------------------------------------
# Region: Bitwarden – paginated GET with retry + 401 re-auth
# ---------------------------------------------------------------------------

function Invoke-BitwardenGet {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{},
        [string]   $IdentityBaseUrl,
        [string]   $ClientId,
        [string]   $ClientSecret
    )

    $retryableStatusCodes = @(429, 500, 502, 503, 504)
    $reauthenticated = $false

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {

        $token   = Get-BitwardenToken -IdentityBaseUrl $IdentityBaseUrl -ClientId $ClientId -ClientSecret $ClientSecret
        $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }

        # Build query string
        $uri = $Url
        if ($QueryParams.Count -gt 0) {
            $qs = ($QueryParams.GetEnumerator() | ForEach-Object {
                "$([System.Uri]::EscapeDataString($_.Key))=$([System.Uri]::EscapeDataString($_.Value))"
            }) -join '&'
            $uri = "$Url`?$qs"
        }

        try {
            $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -ErrorAction Stop
            return ($response.Content | ConvertFrom-Json)

        } catch [System.Net.WebException],[Microsoft.PowerShell.Commands.HttpResponseException] {

            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # 401 – force token refresh once
            if ($statusCode -eq 401 -and -not $reauthenticated) {
                Write-Warning "Received 401 from Bitwarden API – forcing token refresh."
                $script:BwAccessToken  = $null
                $script:BwTokenExpires = [System.DateTime]::MinValue
                $reauthenticated = $true
                $attempt--   # don't count this as a retry attempt
                continue
            }

            # Retryable errors
            if ($statusCode -in $retryableStatusCodes -and $attempt -lt $MaxRetries) {
                $waitSec = [Math]::Min($InitialBackoffSeconds * [Math]::Pow(2, $attempt), $MaxBackoffSeconds)
                Write-Warning "Retryable status $statusCode from $Url. Attempt $($attempt + 1)/$MaxRetries. Waiting ${waitSec}s."
                Start-Sleep -Seconds $waitSec
                continue
            }

            throw "Bitwarden API error $statusCode for ${Url}: $_"
        }
    }

    throw "Exhausted retries for $Url."
}

# ---------------------------------------------------------------------------
# Region: Bitwarden – fetch all pages (continuation token)
# ---------------------------------------------------------------------------
# The API returns a continuationToken at the top level when > 50 records exist.
# Pass it back as a query parameter on subsequent requests.
# Ref: https://bitwarden.com/help/public-api/#continuation-token

function Get-BitwardenAllPages {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{},
        [string]   $IdentityBaseUrl,
        [string]   $ClientId,
        [string]   $ClientSecret
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $params   = [hashtable]$QueryParams.Clone()
    $page     = 0

    do {
        $page++
        $data  = Invoke-BitwardenGet -Url $Url -QueryParams $params `
                                     -IdentityBaseUrl $IdentityBaseUrl `
                                     -ClientId $ClientId -ClientSecret $ClientSecret
        $items = $data.data
        if ($items) { $allItems.AddRange([object[]]$items) }

        Write-Host "Page $page : fetched $($items.Count) items (total: $($allItems.Count))"

        $continuationToken = $data.continuationToken
        if ($continuationToken) {
            $params['continuationToken'] = $continuationToken
        }

    } while ($continuationToken)

    return $allItems.ToArray()
}

# ---------------------------------------------------------------------------
# Region: Bitwarden – fetch events, members, groups
# ---------------------------------------------------------------------------

function Get-BitwardenEvents {
    param([datetime]$Start, [datetime]$End)

    $startStr = $Start.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')
    $endStr   = $End.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')
    Write-Host "Fetching Bitwarden events from $startStr to $endStr"

    return Get-BitwardenAllPages `
        -Url "$ApiBaseUrl/public/events" `
        -QueryParams @{ start = $startStr; end = $endStr } `
        -IdentityBaseUrl $IdentityBaseUrl `
        -ClientId $BitwardenClientId `
        -ClientSecret $ResolvedClientSecret
}

function Get-BitwardenMembers {
    Write-Host "Fetching Bitwarden members."
    return Get-BitwardenAllPages `
        -Url "$ApiBaseUrl/public/members" `
        -IdentityBaseUrl $IdentityBaseUrl `
        -ClientId $BitwardenClientId `
        -ClientSecret $ResolvedClientSecret
}

function Get-BitwardenGroups {
    Write-Host "Fetching Bitwarden groups."
    return Get-BitwardenAllPages `
        -Url "$ApiBaseUrl/public/groups" `
        -IdentityBaseUrl $IdentityBaseUrl `
        -ClientId $BitwardenClientId `
        -ClientSecret $ResolvedClientSecret
}

# ---------------------------------------------------------------------------
# Region: Normalise records to table schemas
# ---------------------------------------------------------------------------

function ConvertTo-EventRecords {
    param([object[]]$RawEvents, [string]$FallbackTimestamp)
    return $RawEvents | ForEach-Object {
        @{
            TimeGenerated  = if ($_.date) { $_.date } else { $FallbackTimestamp }
            eventType      = $_.type
            itemId         = $_.itemId
            collectionId   = $_.collectionId
            groupId        = $_.groupId
            policyId       = $_.policyId
            memberId       = $_.memberId
            actingUserId   = $_.actingUserId
            installationId = $_.installationId
            device         = $_.device
            ipAddress      = $_.ipAddress
        }
    }
}

function ConvertTo-MemberRecords {
    param([object[]]$RawMembers, [string]$Timestamp)
    return $RawMembers | ForEach-Object {
        @{
            TimeGenerated = $Timestamp
            memberId      = $_.id
            userId        = $_.userId
            email         = $_.email
            name          = $_.name
        }
    }
}

function ConvertTo-GroupRecords {
    param([object[]]$RawGroups, [string]$Timestamp)
    return $RawGroups | ForEach-Object {
        @{
            TimeGenerated = $Timestamp
            groupId       = $_.id
            name          = $_.name
        }
    }
}

# ---------------------------------------------------------------------------
# Region: Azure Monitor – upload via Logs Ingestion API (DCR)
# ---------------------------------------------------------------------------
# Uses the Az.Monitor.Ingestion module which calls the DCR endpoint
# authenticated via the Managed Identity (Az context set in profile.ps1).

function Send-ToDcr {
    param(
        [string]   $DceEndpoint,
        [string]   $DcrImmutableId,
        [string]   $StreamName,
        [object[]] $Records
    )

    if (-not $Records -or $Records.Count -eq 0) {
        Write-Host "No records for stream '$StreamName' – skipping."
        return
    }

    Write-Host "Uploading $($Records.Count) records to stream '$StreamName' (DCR: $DcrImmutableId)."

    # Chunk into 1 MB batches to stay within the API limit
    # Az.Monitor.Ingestion handles this internally, but we serialise for logging
    $body = $Records | ConvertTo-Json -Depth 5 -Compress

    $token     = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com/' -ErrorAction Stop).Token
    $uploadUri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/$StreamName`?api-version=2023-01-01"

    $response = Invoke-RestMethod `
        -Uri         $uploadUri `
        -Method      POST `
        -Headers     @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Body        $body `
        -ErrorAction Stop

    Write-Host "Successfully uploaded $($Records.Count) records to '$StreamName'."
}

# ---------------------------------------------------------------------------
# Region: Main execution
# ---------------------------------------------------------------------------

$windowEnd   = $currentUTCtime
$windowStart = $currentUTCtime.AddMinutes(-$EventLookbackMinutes)
$ts          = $currentUTCtime.ToString('yyyy-MM-ddTHH:mm:ss.000Z')

$totalEvents  = 0
$totalMembers = 0
$totalGroups  = 0

# -- Events ------------------------------------------------------------------
try {
    $rawEvents   = Get-BitwardenEvents -Start $windowStart -End $windowEnd
    $totalEvents = $rawEvents.Count
    Write-Host "Fetched $totalEvents Bitwarden events."

    if ($totalEvents -gt 0) {
        $eventRecords = ConvertTo-EventRecords -RawEvents $rawEvents -FallbackTimestamp $ts
        Send-ToDcr -DceEndpoint $DceEndpoint `
                   -DcrImmutableId $DcrEventsImmutableId `
                   -StreamName 'Custom-BitwardenEventLogs_CL' `
                   -Records $eventRecords
    }
} catch {
    Write-Error "Failed to process Bitwarden events: $_"
}

# -- Members -----------------------------------------------------------------
try {
    $rawMembers   = Get-BitwardenMembers
    $totalMembers = $rawMembers.Count
    Write-Host "Fetched $totalMembers Bitwarden members."

    if ($totalMembers -gt 0) {
        $memberRecords = ConvertTo-MemberRecords -RawMembers $rawMembers -Timestamp $ts
        Send-ToDcr -DceEndpoint $DceEndpoint `
                   -DcrImmutableId $DcrMembersImmutableId `
                   -StreamName 'Custom-BitwardenMembers_CL' `
                   -Records $memberRecords
    }
} catch {
    Write-Error "Failed to process Bitwarden members: $_"
}

# -- Groups ------------------------------------------------------------------
try {
    $rawGroups   = Get-BitwardenGroups
    $totalGroups = $rawGroups.Count
    Write-Host "Fetched $totalGroups Bitwarden groups."

    if ($totalGroups -gt 0) {
        $groupRecords = ConvertTo-GroupRecords -RawGroups $rawGroups -Timestamp $ts
        Send-ToDcr -DceEndpoint $DceEndpoint `
                   -DcrImmutableId $DcrGroupsImmutableId `
                   -StreamName 'Custom-BitwardenGroups_CL' `
                   -Records $groupRecords
    }
} catch {
    Write-Error "Failed to process Bitwarden groups: $_"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$duration = ([System.DateTime]::UtcNow - $currentUTCtime).TotalSeconds
Write-Host "Bitwarden connector finished in $([Math]::Round($duration, 1))s. Events: $totalEvents, Members: $totalMembers, Groups: $totalGroups."
