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

# Key Vault secret resolution (if configured)
$ResolvedClientSecret = Get-BitwardenClientSecret `
    -KeyVaultUri  $KeyVaultUri `
    -SecretName   $KeyVaultSecretName `
    -EnvFallback  $BitwardenClientSecret

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

$duration = ([System.DateTime]::UtcNow - $currentUTCtime).TotalSeconds
Write-Host "Bitwarden connector finished in $([Math]::Round($duration, 1))s. Events: $totalEvents, Members: $totalMembers, Groups: $totalGroups."
