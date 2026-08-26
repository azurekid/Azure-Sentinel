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
        "Token"          = ($token.token | ConvertTo-SecureString -AsPlainText -Force)
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

function Get-BitwardenToken {
    param(
        [string]$IdentityBaseUrl,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $now = [System.DateTime]::UtcNow

    # if ($script:BwAccessToken -and $now -lt $script:BwTokenExpires) {
    #     return $script:BwAccessToken
    # }

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
    $script:BwAccessToken  = $response.access_token | ConvertTo-SecureString -AsPlainText -Force
    $script:BwTokenExpires = $now.AddSeconds($expiresIn - $TokenExpiryBufferSec)

    Write-Host "Bitwarden access token obtained. Valid until ~ $($script:BwTokenExpires.ToString('HH:mm:ss')) UTC."
    return $script:BwAccessToken
}

function Invoke-BitwardenGet {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{}
    )

    Write-Host "Invoking Bitwarden GET $Url with query params: $($QueryParams | ConvertTo-Json -Compress)"
    $retryableStatusCodes = @(429, 500, 502, 503, 504)
    $reauthenticated = $false
    $MaxRetries            = 3

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {

        $headers = @{
            'Authorization' = "Bearer $($BwAccessToken | ConvertFrom-SecureString -AsPlainText)";
            'Accept' = 'application/json'
        }

        # Build query string
        $uri = $Url
        if ($QueryParams.Count -gt 0) {
            $qs = ($QueryParams.GetEnumerator() | ForEach-Object {
                '{0}' -f "$([System.Uri]::EscapeDataString($($_.Key)))=$([System.Uri]::EscapeDataString($_.Value))"
            }) -join '&'
            $uri = '{0}?{1}' -f $Url, $qs
        }

        Write-Host "Attempt $($attempt + 1)/$MaxRetries : GET $uri"


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

function Get-BitwardenAllPages {
    param(
        [string]   $Url,
        [hashtable]$QueryParams = @{}
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $params   = [hashtable]$QueryParams
    $page     = 0
    Write-Host "Initial query params: $($params | ConvertTo-Json -Compress)"

    do {
        $page++
        $data  = Invoke-BitwardenGet -Url $Url -QueryParams $params
        $items = $data.data
        write-host $data
        pause
        if ($items) { $allItems.AddRange([object[]]$items) }

        Write-Host "Page $page : fetched $($items.Count) items (total: $($allItems.Count))"

        $nextToken = $data.continuationToken
        $data = $null

        if ($nextToken) {
            Write-Host "Next continuation token found: $nextToken"
            $params['continuationToken'] = $nextToken
        } else {
            Write-Host "No more continuation tokens returned. Clearing parameter."
            # Remove the key entirely so the 'while' condition becomes false
            $params.Remove('continuationToken')
        }

        Write-Host "Using query params for next page: $($params | ConvertTo-Json -Compress)"
    } while ($params.continuationToken) # This will now cleanly evaluate to false when removed

    return $allItems.ToArray()
}


function Get-BitwardenEvents {
    param(
        [datetime]$Start,
        [datetime]$End
    )

    $startStr = $Start.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')
    $endStr   = $End.ToString('yyyy-MM-ddTHH:mm:ss.000000Z')
    Write-Host "Fetching Bitwarden events from $startStr to $endStr"

    $Events = Get-BitwardenAllPages `
        -Url "$Script:ApiBaseUrl/public/events" `
        -QueryParams @{ start = $startStr; end = $endStr }

    return $Events
    | ForEach-Object {
        @{
            TimeGenerated  = $_.date
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

function Get-BitwardenMembers {
    Write-Host "Fetching Bitwarden members."
    $Members = Get-BitwardenAllPages `
        -Url "$Script:ApiBaseUrl/public/members"

    return $Members.data | ForEach-Object {
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
        -Url "$Script:ApiBaseUrl/public/groups"
}

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
    return $RawMembers.data | ForEach-Object {
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