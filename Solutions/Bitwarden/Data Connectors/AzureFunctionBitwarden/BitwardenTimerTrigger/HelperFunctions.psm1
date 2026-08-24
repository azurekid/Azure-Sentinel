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