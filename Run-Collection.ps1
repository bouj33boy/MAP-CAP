Function Run-Collection
{
<#
.SYNOPSIS
The Run-Collection script allows users to gather JSON data about the Conditional Access Policies of an Azure Tenant. 
In many Azure environments, users are not granted access to view Conditional Access Policies. 
However, with that same level of permission, users can query the API endpoints of Conditional Access Policies, applications, users, and groups.
This enables assesors to determine the limiting relationship a Conditional Access Policy has against their profile.

.DESCRIPTION
Requests data from Azure API Clients to define current Conditional Access Policies and map them in the context of the users.
POC for Bloodhound graph mapping but for Conditional Access within Azure

.EXAMPLE 
ipmo ./Run-Collection.ps1
Run-Collection -accessToken $accessToken

.EXAMPLE 
ipmo ./Run-Collection.ps1
Run-Collection -beta -accessToken $accessToken

.EXAMPLE
ipmo ./Run-Collection.ps1
Run-Collection -beta -neo4JPassword "PASSWORD" -neo4JUserName "Username" -accessToken $accessToken

.PARAMETER accessToken
This is the bearer access token granted by your Azure tenant upon successful authentication. 
View the README.md and follow the steps listed to save your access token as a variable $accessToken

.PARAMETER beta
This is a context switch that will make the scrip utilize the /beta API endpoint instead of v1.0.

.PARAMETER neo4JURL
This parameter specifies the neo4j instance to target and ingest the JSON fields. Default is "http://localhost:7474"

.PARAMETER neo4JUserName
This parameter specifies the neo4j username used for authentication. Default is "neo4j"

.PARAMETER neo4JPassword
This parameter specifies the neo4j password used for authentication. Default is "neo4j"

.NOTES
Future state:
- Considerations surrounding Conditional Access Policy "all" statements
- Differentiate between applications listed under the user's tenant and service principals



#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $accessToken,

    [Parameter(Mandatory=$false)]
    [switch]
    $beta,
    
    [Parameter(Mandatory=$false)]
    [string]
    $neo4JUrl= "http://localhost:7474",

    [Parameter(Mandatory=$false)]
    [string]
    $neo4JUserName="neo4j",

    [Parameter(Mandatory=$false)]
    [string]
    $neo4JPassword="neo4j"
)

if ($neo4JUrl) {
    # If $neo4JUrl is specified, require $neo4JUserName and $neo4JPassword
    if (-not $neo4JUserName -or -not $neo4JPassword) {
        Write-Error "When specifying the Neo4j URL, both Neo4j username and password are required."
        return
    }
}
# Initiate Global Variables
# The url: https://graph.microsoft.com/ is the service root for REST API communication. It contains the database for extensive information related to Azure Active Directory
$global:apiUrl = "https://graph.microsoft.com/"
$global:importDirectory = $null  # Define the global variable
# Start Calling Functions #
Test-Neo4J
Collect-ServicePrincipals
#Collect-App
Collect-Users
Collect-Groups
Collect-CAP
}
##################################
#endregion PRIMARY FUNCTION ######
##################################

##################################
#region SECONDARY FUNCTIONS ######
##################################
Function Test-Neo4J 
{
    # Test the Neo4J local import dir
    # Default API Target is: "http://localhost:7474"
    # Default Neo4j version is 5.6
    # Set unique constraint on Neo4j: 
    # Run in Neo4j Desktop: CREATE CONSTRAINT BaseObjectID FOR (b:Base) REQUIRE b.objectid IS UNIQUE 
    
    $headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
    }
    $query = "CALL dbms.listConfig() YIELD name, value WHERE name = 'server.directories.import' RETURN value"
    $response = Invoke-RestMethod -Uri "$neo4jUrl/db/neo4j/tx/commit" -Headers $headers -Method Post -ContentType "application/json" -Body @"
    {
        "statements": [
            {
                "statement": "$query",
                "resultDataContents": ["row"]
            }
        ]
    }
"@

    $importDirectory = $response.results[0].data[0].row[0]
    if ($importDirectory -eq $null) {
        Write-Error "Local Neo4j instance not found. Please ensure that Neo4j is running and accessible."
    }
    elseif ($importDirectory -notlike "*import*") {
        Write-Error "Import directory not found in the Neo4j configuration. Please verify the Neo4j installation."
    }
    else {
        $global:importDirectory = $importDirectory  # Assign value to the global variable
        Write-Host -ForegroundColor Cyan "Connected to Neo4j Successfully."
        #Write-Host "JSON returns can be saved in: $importDirectory"
        Write-Host -ForegroundColor magenta "Make sure to set unique constraints for future ingestion."
        Write-Host -ForegroundColor magenta "Example: Run in Neo4j Desktop: CREATE CONSTRAINT BaseObjectID FOR (b:Base) REQUIRE b.objectid IS UNIQUE" 
        
    }
}
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
Function Collect-CAP
{   
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    $apiUrlCAP = "v1.0/identity/conditionalAccess/policies"
    $betaUrlCAP = "beta/identity/conditionalAccess/policies"
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlCAP 
    } else { 
        $apiUrl + $apiUrlCAP 
    }
    $accessPolicies = Invoke-RestMethod -Uri $apiTarget -Headers $headers -Method Get
    if ($accessPolicies -and $accessPolicies.value -match "conditions") {
        Write-Host -ForegroundColor Cyan "Conditional Access Policies retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        Write-Host -ForegroundColor magenta "Ingesting Conditional Access Policies into Neo4j."
        $accessPolicies.value | %{

            $CAPid = $_.id.ToUpper()
            $CAPDisplayName = $_.displayName
            $IncludedApplications = $_.Conditions.applications.includeApplications
            $IncludedApplications | %{
                #Write-Host $_ "access is limited by" $CAPid
                $AppID = $_.ToUpper()
            }
            $IncludedUsers = $_.Conditions.users.includeUsers
            $IncludedUsers | %{
                #Write-Host $_ " is limited by" $CAPid
                $UserID = $_.ToUpper()
            }
            $IncludedGroups = $_.Conditions.users.includeGroups
            $IncludedGroups | %{
                $GroupID = $_.ToUpper()
            }
        
        $CreateCAPNodes | %{
            $query = "MERGE (p:Base {objectId:'$CAPid', displayName:'$CAPDisplayName', appId:'$AppID', userId:'$UserID', groupId:'$GroupID'}) SET p:AZConditionalAccessPolicy"
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
        # Create (:AZConditionalAccessPolicy) - [:LimitsAccessTo]->(:AZServicePrincial) All Edges
        $accessPolicies.value | %{
            $CAPid = $_.id.ToUpper()
            $IncludedApplications = $_.Conditions.applications.includeApplications
            ForEach ($IncludedApplication In $IncludedApplications) {
                if ($IncludedApplication -Match "All") {
                    Write-Host -ForegroundColor Green "Creating edge: ('$CAPid':AZConditionalAccessPolicy) - [:LimitsAccessTo]->(ALL:AZServicePrincial) for All service principals and applications."
                    $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (sp:AZServicePrincipal) MERGE (p)-[:LimitsAccessTo]->(sp)"
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
        } else {
            $AppId = $IncludedApplication.ToUpper()
            Write-Host -ForegroundColor magenta "Creating edge ('$CAPid':AZConditionalAccessPolicy) - [:LimitsAccessTo]->('$AppId':AZServicePrincial)"
            $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (sp:AZServicePrincipal {appId:'$AppId'}) MERGE (p)-[:LimitsAccessTo]-> (sp)"
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
        }
        # Create (:AZUser) - [:LimitedBy]->(:AZConditionalAccessPolicy) All Edges
        $accessPolicies.value | %{
            $CAPid = $_.id.ToUpper()
            $IncludedUsers = $_.Conditions.users.includeUsers
            ForEach ($IncludedUser In $IncludedUsers) {
                if ($IncludedUser -Match "All") {
                    Write-Host -ForegroundColor Green "Creating edge (:AZUser) - [:LimitedBy]->('$CAPid':AZConditionalAccessPolicy) for All users"
                    $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (u:AZUser) MERGE (u)-[:LimitedBy]->(p)"
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
        } else {
            $UserId = $IncludedUser.ToUpper()
            Write-Host -ForegroundColor magenta "Creating edge ('$UserId':AZUser) - [:LimitedBy]->('$CAPid':AZConditionalAccessPolicy) for specific users"
            $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (u:AZUser {userId:'$UserId'}) MERGE (u)-[:LimitedBy]->(p)"
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
            }
            # Create (:AZGroup) - [:LimitedBy]->(:AZConditionalAccessPolicy) All Edges
        $accessPolicies.value | %{
            $CAPid = $_.id.ToUpper()
            $IncludedGroups = $_.Conditions.users.includeGroups
            ForEach ($IncludedGroup In $IncludedGroups) {
                if ($IncludedGroup -Match "All") {
                    Write-Host -ForegroundColor Green "Creating edge (:AZGroup) - [:LimitedBy]->('$CAPid':AZConditionalAccessPolicy) for All groups"
                    $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (g:AZGroup) MERGE (g)-[:LimitedBy]->(p)"
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
        } else {
            Write-Host -ForegroundColor magenta "Creating edge ('$GroupId':AZGroup) - [:LimitedBy]->('$CAPid':AZConditionalAccessPolicy) for specific groups"
            $GroupId = $IncludedGroup.ToUpper()
            $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (g:AZGroup {groupId:'$GroupId'}) MERGE (g)-[:LimitedBy]->(p)"
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
            }

        }

}
<# Function Collect-App
{
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    $apiUrlApp = "v1.0/applications"
    $betaUrlApp = "beta/applications"
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlApp 
    } else { 
        $apiUrl + $apiUrlApp 
    }
    $applications = Invoke-RestMethod -Uri $apiTarget -Headers $headers -Method Get
    if ($applications -and $applications.value -match "appRoles") {
        Write-Host "Applications retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        $applications.value | %{

            $ApplicationID = $_.id.ToUpper()
            $ApplicationAppID = $_.appid.ToUpper()
            $AppDisplayName = $_.displayName
        
            $CreateAppNodes | %{
                $query = "MERGE (a:Base {objectId:'$ApplicationID', appId:'$ApplicationAppID', displayName:'$AppDisplayName'}) SET a:AZApplication"
        
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
        foreach ($ID in $applications.value.appid.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (a:Base) WHERE a.objectId='$ID' MATCH (p:Base) WHERE p.appId='$ID' MERGE (p)-[:LimitsAccessTo]->(a)"
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
} #>
Function Collect-Users
{
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    $apiUrlUsers = "v1.0/users"
    $betaUrlUsers = "beta/users"
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlUsers 
    } else { 
        $apiUrl + $apiUrlUsers 
    }
    $users = Invoke-RestMethod -Uri $apiTarget -Headers $headers -Method Get
    if ($users -and $users.value -match "accountEnabled") {
        Write-Host -ForegroundColor Cyan "Users retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        Write-Host -ForegroundColor magenta "Ingesting users into Neo4j."
        $users.value | %{

            $UserID = $_.id.ToUpper()
            $UserDisplayName = $_.displayName
        
            $CreateUserNodes | %{
                #Write-Host $_ " is limited by" $CAPid
                $query = "MERGE (u:Base {userId:'$UserID', displayName:'$UserDisplayName'}) SET u:AZUser"
        
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
        
<#         foreach ($ID in $users.value.id.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (u:Base) WHERE u.userId='$ID' MATCH (p:Base) WHERE p.userId='$ID' MERGE (u)-[:IsLimitedBy]->(p)"
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

        } #>
    }
}
Function Collect-Groups
{
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    $apiUrlGroups = "v1.0/groups"
    $betaUrlGroups = "beta/groups"
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlGroups 
    } else { 
        $apiUrl + $apiUrlGroups 
    }
    $groups = Invoke-RestMethod -Uri $apiTarget -Headers $headers -Method Get
    if ($groups -and $groups.value -match "membershipRule") {
        Write-Host -ForegroundColor Cyan "Groups retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        Write-Host -ForegroundColor magenta "Ingesting groups into Neo4j."
        $groups.value | %{

            $GroupID = $_.id.ToUpper()
            $GroupDisplayName = $_.displayName
        
            $CreateGroupNodes | %{
                #Write-Host $_ " is limited by" $CAPid
                $query = "MERGE (g:Base {groupId:'$GroupID', displayName:'$GroupDisplayName'}) SET g:AZGroup"
        
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
        #Loop through and MERGE request the relationship between the Group and the CAP
<#         foreach ($ID in $groups.value.id.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (g:Base) WHERE g.group='$ID' MATCH (p:Base) WHERE p.groupId='$ID' MERGE (g)-[:IsLimitedBy]->(p)"
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

        } #>
    } 
}