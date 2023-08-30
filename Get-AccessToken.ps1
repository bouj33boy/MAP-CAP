Function Get-AccessToken {
    $body = @{
        "client_id" = "1950a258-227b-4e31-a9cf-717495945fc2"
        "resource" = "https://graph.microsoft.com"
        }
    $UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36"
    $Headers = @{}
    $Headers["User-Agent"] = $UserAgent

    # 2. Run the following Invoke-RestMethod 

$authResponse = Invoke-RestMethod `
    -UseBasicParsing `
    -Method Post `
    -Uri "https://login.microsoftonline.com/common/oauth2/devicecode?api-version=1.0" `
    -Headers $Headers `
    -Body $body
Write-Host $authResponse

Start-Sleep -Seconds 30

# 5. Get the Access_Token by running the following lines:

$body = @{
    "client_id" = "1950a258-227b-4e31-a9cf-717495945fc2"
    "grant_type" = "urn:ietf:params:oauth:grant-type:device_code"
    "code" = $authResponse.device_code
    }

$Tokens = Invoke-RestMethod `
    -UseBasicParsing `
    -Method Post `
    -Uri "https://login.microsoftonline.com/Common/oauth2/token?api-version=1.0" `
    -Headers $Headers `
    -Body $body

$accessToken = $Tokens.access_token

# Prep for token stuff

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type" = "application/json"
}
}

------
Function Collect-ServicePrincipals
{
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    # Get-AllAzureADServicePrincipals taken from Bark.ps1
    # https://github.com/BloodHoundAD/BARK/blob/main/BARK.ps1
    $ShowProgress = $True
    $URI = "https://graph.microsoft.com/beta/servicePrincipals/?`$count=true"
    $Results = $null
    $ServicePrincipalObjects = $null
    If ($ShowProgress) {
        Write-Progress -Activity "Enumerating Service Principals" -Status "Initial request..."
    }
    do {
        $Results = Invoke-RestMethod `
            -Headers @{
                Authorization = "Bearer $($accessToken)"
                ConsistencyLevel = "eventual"
            } `
            -URI $URI `
            -UseBasicParsing `
            -Method "GET" `
            -ContentType "application/json"
        if ($Results.'@odata.count') {
            $TotalServicePrincipalCount = $Results.'@odata.count'
        }
        if ($Results.value) {
            $ServicePrincipalObjects += $Results.value
        } else {
            $ServicePrincipalObjects += $Results
        }
        $uri = $Results.'@odata.nextlink'
        If ($ShowProgress) {
            $PercentComplete = ([Int32](($ServicePrincipalObjects.count/$TotalServicePrincipalCount)*100))
            Write-Progress -Activity "Enumerating Service Principals" -Status "$($PercentComplete)% complete [$($ServicePrincipalObjects.count) of $($TotalServicePrincipalCount)]" -PercentComplete $PercentComplete
        }
    } until (!($uri))
    Write-Host -ForegroundColor Cyan "Service Principal objects retrieved successfully."
    $headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
    }
    #Ingest SP into Neo4j nodes
    Write-Host -ForegroundColor magenta "Now ingesting Service Principal objects into Neo4j as nodes."
    Write-Host -ForegroundColor magenta "This may take up to several min."
    $ServicePrincipalObjects | %{
        $SPObjectID = $_.id.ToUpper()
        $SPAppID = $_.appId.ToUpper()
        $SPDisplayName = $_.displayName
        $CreateSPNodes | %{
                $query = "MERGE (sp:Base {appId:'$SPAppID', displayName:'$SPDisplayName', objectId:'$SPObjectID'}) SET sp:AZServicePrincipal"
                $response = Invoke-RestMethod `
                -Uri "http://localhost:7474/db/neo4j/tx/commit" `
                -Headers $headers `
                -Method Post `
                -ContentType "application/json" `
                -Body @"
    {
        "statements": [
            {
                "statement": "$query",
                "resultDataContents": ["row"]
            }
        ]
    }
"@`
            }
        } 
        #Loop through and MERGE request the relationship between the CAP and the APP
        Write-Host -ForegroundColor magenta "Creating relationships between Service Principals and the conditional access policies."
        foreach ($ID in $ServicePrincipalObjects.id.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (sp:Base) WHERE sp.appId='$ID' MATCH (p:Base) WHERE p.appId='$ID' MERGE (p)-[:LimitsAccessTo]->(sp)"
            #Write-Host $query
        #}
            $response = Invoke-RestMethod `
            -Uri "http://localhost:7474/db/neo4j/tx/commit" `
            -Headers $headers `
            -Method Post `
            -ContentType "application/json" `
            -Body @"
{
    "statements": [
        {
            "statement": "$query",
            "resultDataContents": ["row"]
        }
    ]
}
"@`

        }
}

-------
$URI = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=startswith(displayName,'$($TestGUID)')"
$Results = $null
$TestSPObjects = $null
do {
    $Results = Invoke-RestMethod `
        -Headers @{Authorization = "Bearer $($MSGraphGlobalAdminToken)"} `
        -URI $URI `
        -UseBasicParsing `
        -Method "GET" `
        -ContentType "application/json"
    if ($Results.value) {
        $TestSPObjects += $Results.value
    } else {
        $TestSPObjects += $Results
    }
    $uri = $Results.'@odata.nextlink'
} until (!($uri))

# Get the current sub-level role assignments
$URI = "https://management.azure.com/subscriptions/$($SubscriptionID)/providers/Microsoft.Authorization/roleAssignments?api-version=2018-01-01-preview"
$Request = $null
$SubLevelRoleAssignments = Invoke-RestMethod `
    -Headers @{Authorization = "Bearer $($UserAccessAdminAzureRMToken)"} `
    -URI $URI `
    -Method GET 
$RoleAssignmentToDelete = $null
