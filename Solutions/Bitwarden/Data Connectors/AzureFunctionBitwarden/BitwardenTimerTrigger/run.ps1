param($Timer)

Set-StrictMode -Off   # JSON responses may have missing/optional properties

$currentUTCtime = [System.DateTime]::UtcNow

Write-Host "Bitwarden connector started at $($currentUTCtime.ToString('o'))"

if ($Timer.IsPastDue) {
    Write-Warning "Timer is past due – execution was delayed."
}

$BitwardenClientId     = $env:BITWARDEN_CLIENT_ID
$BitwardenClientSecret = $env:BITWARDEN_CLIENT_SECRET
$BitwardenUrl          = $env:BITWARDEN_URL
$EventLookbackMinutes  = if ($env:BITWARDEN_EVENT_LOOKBACK_MINUTES) { [int]$env:BITWARDEN_EVENT_LOOKBACK_MINUTES } else { 5 }

$DceEndpoint           = $env:AZURE_DCE_ENDPOINT
$DcrEventsImmutableId  = $env:AZURE_DCR_EVENTS_IMMUTABLEID
$DcrMembersImmutableId = $env:AZURE_DCR_MEMBERS_IMMUTABLEID
$DcrGroupsImmutableId  = $env:AZURE_DCR_GROUPS_IMMUTABLEID

$MaxRetries            = 3
$InitialBackoffSeconds = 2
$MaxBackoffSeconds     = 60

function Assert-Required {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required environment variable '$Name' is not set or empty."
    }
}

Assert-Required $DceEndpoint           'AZURE_DCE_ENDPOINT'
Assert-Required $DcrEventsImmutableId  'AZURE_DCR_EVENTS_IMMUTABLEID'
Assert-Required $DcrMembersImmutableId 'AZURE_DCR_MEMBERS_IMMUTABLEID'
Assert-Required $DcrGroupsImmutableId  'AZURE_DCR_GROUPS_IMMUTABLEID'

$BitwardenIdentityUrl  = $env:BITWARDEN_IDENTITY_URL
$BitwardenApiUrl       = $env:BITWARDEN_API_URL

if ($bitwardenUrl -match 'https://bitwarden\.(com|eu)') {
    Write-Verbose "Using Bitwarden SaaS instance. Setting identity and API endpoints based on the provided URL."
    $BitwardenIdentityUrl = "https://identity.bitwarden.$($matches[1])"
    $BitwardenApiUrl      = "https://api.bitwarden.$($matches[1])"
} else {
    Write-Verbose "Using a self-hosted Bitwarden instance. Using provided URLs for identity and API endpoints."
    $BitwardenIdentityUrl = "$env:BitwardenUrl/identity"
    $BitwardenApiUrl      = "$env:BitwardenUrl/api"
}

try {
    $rawEvents   = Get-BitwardenEvents -Start $currentUTCtime.AddMinutes(-$EventLookbackMinutes) -End $currentUTCtime
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
