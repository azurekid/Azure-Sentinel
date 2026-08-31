Function Send-Data {
    <#
    .SYNOPSIS
    Sends data to a specified endpoint using an Azure access token.
    .DESCRIPTION
    This function sends data to a specified endpoint using an Azure access token. The access token is obtained using the Get-AzAccessToken cmdlet.
    .PARAMETER body
    The data to be sent to the endpoint.
    .EXAMPLE
    $body = @{
        "key1" = "value1"
        "key2" = "value2"
    }
    Send-Data -body $body
    .NOTES
    This function requires the Get-AzAccessToken cmdlet to be installed. It also requires the $env:dataCollectionEndpoint environment variable to be set to the desired endpoint URL.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object]$body
    )

    $uri = "$env:DATA_COLLECTION_ENDPOINT"
    $token = Get-AzAccessToken -ResourceUrl https://monitor.azure.com

    $requestHeader = @{
        "Token"          = $token.token
        "Authentication" = 'OAuth'
        "Method"         = 'POST'
        "ContentType"    = 'application/json'
    }

    try {
        Invoke-RestMethod -Uri "$uri" -Body $body @requestHeader
    }
    catch {
        Write-Warning "Unable to sent data. Validate if the account '$($token.UserId)' has Access to the Data Collection Rule"
    }

}

function Get-BitwardenToken {

    $now = [System.DateTime]::UtcNow

    if ($Script:BwAccessToken -and $now -lt $Script:BwTokenExpires) {
        return $Script:BwAccessToken
    }

    $BitwardenClientId     = $env:BITWARDEN_CLIENT_ID
    $BitwardenClientSecret = $env:BITWARDEN_CLIENT_SECRET

    $tokenUrl = "$Script:BitwardenIdentityUrl/connect/token"
    $body     = "grant_type=client_credentials&scope=api.organization&client_id=$([System.Uri]::EscapeDataString($BitwardenClientId))&client_secret=$([System.Uri]::EscapeDataString($BitwardenClientSecret))"

    Write-Host "Get-BitwardenToken: Requesting Bitwarden access token from $tokenUrl"

    $response = Invoke-RestMethod `
        -Uri     $tokenUrl `
        -Method  POST `
        -Headers @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/x-www-form-urlencoded' } `
        -Body    $body `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Get-BitwardenToken: Bitwarden token response did not contain 'access_token'."
    }

    $expiresIn = if ($response.expires_in) { [int]$response.expires_in } else { 3600 }
    $Script:BwAccessToken = $response.access_token | ConvertTo-SecureString -AsPlainText -Force
    $Script:BwTokenExpires = $now.AddSeconds($expiresIn - $TokenExpiryBufferSec)

    Write-Host "Get-BitwardenToken: Bitwarden access token obtained. Valid until ~ $($Script:BwTokenExpires.ToString('HH:mm:ss')) UTC."
    return $Script:BwAccessToken
}

function Get-BitwardenEvents {
    param(
        [datetime]$Start,
        [datetime]$End
    )

    $startStr = $Start.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')
    $endStr = $End.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')

    Write-Host "Get-BitwardenEvents: Fetching Bitwarden events from $startStr to $endStr"

    $Events = Get-BitwardenAllPages `
        -Url "$Script:BitwardenApiUrl/public/events" `
        -QueryParams @{ start = $startStr; end = $endStr }

    return $Events
}

function Get-BitwardenAllPages {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{}
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $params = [hashtable]$QueryParams
    $page = 0

    do {
        $page++
        $data = Invoke-BitwardenGet -Url $Url -QueryParams $params
        $items = $data.data
        if ($items) { $allItems.AddRange([object[]]$items) }

        Write-Host "Get-BitwardenAllPages: Page $page : fetched $($items.Count) items (total: $($allItems.Count))"

        $nextToken = $data.continuationToken
        $data = $null

        if ($nextToken) {
            Write-Verbose "Get-BitwardenAllPages: Next continuation token found: $nextToken"
            $params['continuationToken'] = $nextToken
        }
        else {
            Write-Verbose "Get-BitwardenAllPages: No more continuation tokens returned. Clearing parameter."
            # Remove the key entirely so the 'while' condition becomes false
            $params.Remove('continuationToken')
        }

        Write-Verbose "Get_BitwardenAllPages: Using query params for next page: $($params | ConvertTo-Json -Compress)"
    } while ($params.continuationToken)

    return $allItems.ToArray()
}

function Invoke-BitwardenGet {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{}
    )

    Get-BitwardenToken -IdentityBaseUrl $Script:BitwardenIdentityUrl | Out-Null

    Write-Host "Invoke-BitwardenGet: GET $Url with query params: $($QueryParams | ConvertTo-Json -Compress)"

    $retryableStatusCodes = @(429, 500, 502, 503, 504)
    $reauthenticated = $false
    $MaxRetries = 3

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {

        $headers = @{
            'Authorization' = "Bearer $($Script:BwAccessToken | ConvertFrom-SecureString -AsPlainText)";
            'Accept'        = 'application/json'
        }

        # Build query string
        $uri = $Url
        if ($QueryParams.Count -gt 0) {
            $qs = ($QueryParams.GetEnumerator() | ForEach-Object {
                    '{0}' -f "$([System.Uri]::EscapeDataString($($_.Key)))=$([System.Uri]::EscapeDataString($_.Value))"
                }) -join '&'
            $uri = '{0}?{1}' -f $Url, $qs
        }

        Write-Host "Invoke-BitwardenGet: Attempt $($attempt + 1)/$MaxRetries : GET $uri"


        try {
            $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -ErrorAction Stop
            return ($response.Content | ConvertFrom-Json)

        }
        catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {

            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # 401 – force token refresh once
            if ($statusCode -eq 401 -and -not $reauthenticated) {
                Write-Warning "Received 401 from Bitwarden API – forcing token refresh."
                $script:BwAccessToken = $null
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

            throw "Invoke-BitwardenGet: Bitwarden API error $statusCode for ${Url}: $_"
        }
    }

    throw "Exhausted retries for $Url."
}




function Get-BitwardenMembers {
    Write-Host "Fetching Bitwarden members."
    $Members = Get-BitwardenAllPages `
        -Url "$Script:BitwardenApiUrl/public/members"

    return $Members | ForEach-Object {
        @{
            TimeGenerated = $Timestamp
            memberId      = $_.id
            userId        = $_.userId
            email         = $_.email
            name          = $_.name
        }
    }
}

function Get-BitwardenGroups {
    Write-Host "Fetching Bitwarden groups."
    return Get-BitwardenAllPages `
        -Url "$Script:BitwardenApiUrl/public/groups"
}

function Build-MemberLookup {
    <#
    .SYNOPSIS
    Builds a lookup hashtable keyed by memberId from raw group objects.
    #>
    param([object[]]$RawMembers)

    $byMemberId = @{}
    $byUserId = @{}

    foreach ($m in $RawMembers) {
        $record = @{
            memberId = $m.id
            userId   = $m.userId
            email    = $m.email
            name     = $m.name
        }
        if ($m.id) { $byMemberId[$m.id] = $record }
        if ($m.userId) { $byUserId[$m.userId] = $record }
    }

    return @{ ByMemberId = $byMemberId; ByUserId = $byUserId }
}

function Build-GroupLookup {
    <#
    .SYNOPSIS
    Builds a lookup hashtable keyed by groupId from raw group objects.
    #>
    param([object[]]$RawGroups)

    $byGroupId = @{}
    foreach ($g in $RawGroups) {
        if ($g.id) {
            $byGroupId[$g.id] = @{ groupId = $g.id; groupName = $g.name }
        }
    }
    return $byGroupId
}

function ConvertTo-EnrichedEventRecords {
    <#
    .SYNOPSIS
    Converts raw Bitwarden events into enriched DCR records by joining member
    and group lookup data. Each output record is a single flat hashtable with:
      - Core event fields
      - Affected member fields  (memberId     -> memberEmail, memberName, memberUserId)
      - Acting user fields      (actingUserId -> actingUserEmail, actingUserName)
      - Group name              (groupId      -> groupName)
    Unresolved IDs produce null values rather than being omitted.
    #>
    param(
        [object[]]  $RawEvents,
        [string]    $FallbackTimestamp
    )

    $memberLookup = @{ ByMemberId = @{}; ByUserId = @{} }
    $groupLookup  = @{}

    try {
        $memberLookup = Build-MemberLookup -RawMembers (Get-BitwardenMembers)
    }
    catch {
        Write-Warning "Failed to fetch Bitwarden members - events will be sent without member enrichment: $_"
    }

    try {
        $groupLookup = Build-GroupLookup -RawGroups (Get-BitwardenGroups)
    }
    catch {
        Write-Warning "Failed to fetch Bitwarden groups - events will be sent without group enrichment: $_"
    }

    return $RawEvents | ForEach-Object {
        $ev = $_

        # Resolve the affected member (memberId is the org-member ID)
        $member = if ($ev.memberId -and $memberLookup.ByMemberId.ContainsKey($ev.memberId)) {
            $memberLookup.ByMemberId[$ev.memberId]
        }
        else { $null }

        # Resolve the acting user (actingUserId is a Bitwarden userId, not memberId)
        $actor = if ($ev.actingUserId -and $memberLookup.ByUserId.ContainsKey($ev.actingUserId)) {
            $memberLookup.ByUserId[$ev.actingUserId]
        }
        else { $null }

        # Resolve the group
        $group = if ($ev.groupId -and $groupLookup.ContainsKey($ev.groupId)) {
            $groupLookup[$ev.groupId]
        }
        else { $null }

        @{
            # Core event fields
            TimeGenerated    = if ($ev.date) { $ev.date } else { $FallbackTimestamp }
            eventType        = $ev.type
            itemId           = $ev.itemId
            collectionId     = $ev.collectionId
            policyId         = $ev.policyId
            installationId   = $ev.installationId
            device           = $ev.device
            ipAddress        = $ev.ipAddress

            # Affected member
            memberId         = $ev.memberId
            memberUserId     = if ($member) { $member.userId } else { $null }
            memberEmail      = if ($member) { $member.email }  else { $null }
            memberName       = if ($member) { $member.name }   else { $null }

            # Acting user
            actingUserId     = $ev.actingUserId
            actingUserEmail  = if ($actor) { $actor.email }     else { $null }
            actingUserName   = if ($actor) { $actor.name }      else { $null }

            # Group
            groupId          = $ev.groupId
            groupName        = if ($group) { $group.groupName } else { $null }

            # Other fields
            serviceAccountId = if ($ev.serviceAccountId) { $ev.serviceAccountId } else { $null }
            projectId        = if ($ev.projectId) { $ev.projectId } else { $null }
            secretId         = if ($ev.secretId) { $ev.secretId } else { $null }
        }
    }
}