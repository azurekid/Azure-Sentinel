param($Timer)

# JSON responses may have missing/optional properties
Set-StrictMode -Off

$currentUTCtime = [System.DateTime]::UtcNow
$ts = $currentUTCtime.ToString('yyyy-MM-ddTHH:mm:ss.000Z')

Write-Host "Bitwarden connector started at $($currentUTCtime.ToString('o'))"

if ($Timer.IsPastDue) {
    Write-Warning "Timer is past due – execution was delayed."
}

$BitwardenUrl = $env:BITWARDEN_URL
$EventLookbackMinutes = if ($env:BITWARDEN_EVENT_LOOKBACK_MINUTES) { [int]$env:BITWARDEN_EVENT_LOOKBACK_MINUTES } else { 5 }

if ($bitwardenUrl -match 'bitwarden\.(com|eu)') {
    Write-Verbose "Using Bitwarden SaaS instance. Setting identity and API endpoints based on the provided URL."
    $Script:BitwardenIdentityUrl = "https://identity.bitwarden.$($matches[1])"
    $Script:BitwardenApiUrl = "https://api.bitwarden.$($matches[1])"
} else {
    Write-Verbose "Using a self-hosted Bitwarden instance. Using provided URLs for identity and API endpoints."
    $Script:BitwardenIdentityUrl = "$BitwardenUrl/identity"
    $Script:BitwardenApiUrl = "$BitwardenUrl/api"
}

try {
    $rawEvents = Get-BitwardenEvents -Start $currentUTCtime.AddMinutes(-$EventLookbackMinutes) -End $currentUTCtime
    
    $totalEvents = $rawEvents.Count
    Write-Host "Fetched $totalEvents Bitwarden events."

    if ($totalEvents -gt 0) {
        $eventRecords = ConvertTo-EnrichedEventRecords `
            -RawEvents         $rawEvents `
            -FallbackTimestamp $ts

        if ($eventRecords.Count -gt 0) {
            Write-Host "Sending $($eventRecords.Count) enriched Bitwarden events to the SIEM."
        }
        # Send-Data -body ($eventRecords | ConvertTo-Json -Depth 5)
    } else {
        Write-Host "No new Bitwarden events to send to the SIEM."
    }
} catch {
    Write-Error "Failed to process Bitwarden events: $_"
}

$duration = ([System.DateTime]::UtcNow - $currentUTCtime).TotalSeconds
Write-Host "Bitwarden connector finished in $([Math]::Round($duration, 1))s. Events: $totalEvents"