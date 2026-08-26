param($Timer)

Set-StrictMode -Off   # JSON responses may have missing/optional properties

$currentUTCtime = [System.DateTime]::UtcNow

Write-Host "Bitwarden connector started at $($currentUTCtime.ToString('o'))"

if ($Timer.IsPastDue) {
    Write-Warning "Timer is past due – execution was delayed."
}

$BitwardenUrl          = $env:BITWARDEN_URL
$EventLookbackMinutes  = if ($env:BITWARDEN_EVENT_LOOKBACK_MINUTES) { [int]$env:BITWARDEN_EVENT_LOOKBACK_MINUTES } else { 5 }

if ($bitwardenUrl -match 'bitwarden\.(com|eu)') {
    Write-Verbose "Using Bitwarden SaaS instance. Setting identity and API endpoints based on the provided URL."
    $BitwardenIdentityUrl = "https://identity.bitwarden.$($matches[1])"
    $BitwardenApiUrl      = "https://api.bitwarden.$($matches[1])"
} else {
    Write-Verbose "Using a self-hosted Bitwarden instance. Using provided URLs for identity and API endpoints."
    $BitwardenIdentityUrl = "$BitwardenUrl/identity"
    $BitwardenApiUrl      = "$BitwardenUrl/api"
}

$ts           = $currentUTCtime.ToString('yyyy-MM-ddTHH:mm:ss.000Z')

$totalEvents  = 0
$totalMembers = 0
$totalGroups  = 0

try {
    $rawMembers   = Get-BitwardenMembers
    $totalMembers = $rawMembers.Count
    Write-Host "Fetched $totalMembers Bitwarden members."
} catch {
    Write-Warning "Failed to fetch Bitwarden members - events will be sent without member enrichment: $_"
    $rawMembers = @()
}

try {
    $rawGroups   = Get-BitwardenGroups
    $totalGroups = $rawGroups.Count
    Write-Host "Fetched $totalGroups Bitwarden groups."
} catch {
    Write-Warning "Failed to fetch Bitwarden groups - events will be sent without group enrichment: $_"
    $rawGroups = @()
}

$memberLookup = Build-MemberLookup -RawMembers $rawMembers
$groupLookup  = Build-GroupLookup  -RawGroups  $rawGroups

try {
    $rawEvents   = Get-BitwardenEvents -Start $currentUTCtime.AddMinutes(-$EventLookbackMinutes) -End $currentUTCtime
    $totalEvents = $rawEvents.Count
    Write-Host "Fetched $totalEvents Bitwarden events."

    if ($totalEvents -gt 0) {
        $eventRecords = ConvertTo-EnrichedEventRecords `
            -RawEvents         $rawEvents `
            -FallbackTimestamp $ts `
            -MemberLookup      $memberLookup `
            -GroupLookup       $groupLookup

        Send-Data -body ($eventRecords | ConvertTo-Json -Depth 5)
    }
} catch {
    Write-Error "Failed to process Bitwarden events: $_"
}

$duration = ([System.DateTime]::UtcNow - $currentUTCtime).TotalSeconds
Write-Host "Bitwarden connector finished in $([Math]::Round($duration, 1))s. Events: $totalEvents, Members (lookup): $totalMembers, Groups (lookup): $totalGroups."