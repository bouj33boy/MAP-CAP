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
Collect-CAP
Collect-App
Collect-Users
Collect-Groups
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
        Write-Host "JSON returns can be saved in: $importDirectory"
        Write-Host "Make sure to set unique constraints for future ingestion"
        Write-Host "Example: Run in Neo4j Desktop: CREATE CONSTRAINT BaseObjectID FOR (b:Base) REQUIRE b.objectid IS UNIQUE" 
        
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
        Write-Host "Conditional Access Policies retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
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
        }
        $CreateCAPNodes | %{
            $query = "MERGE (p:Base {objectid:'$CAPid', displayName:'$CAPDisplayName', AppID:'$AppID', UserID:'$UserID', GroupID:'$GroupID'})"

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
Function Collect-App
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

            $ApplicationID = $_.appid.ToUpper()
            $AppDisplayName = $_.displayName
        
            $CreateAppNodes | %{
                #Write-Host $_ " is limited by" $CAPid
                $query = "MERGE (a:Base {objectid:'$ApplicationID', displayName:'$AppDisplayName'})"
        
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
            $query = "MATCH (a:Base) WHERE a.objectid='$ID' MATCH (p:Base) WHERE p.AppID='$ID' MERGE (p)-[:LimitsAccessTo]->(a)"
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
}
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
        Write-Host "Users retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        $users.value | %{

            $UserID = $_.id.ToUpper()
            $UserDisplayName = $_.displayName
        
            $CreateUserNodes | %{
                #Write-Host $_ " is limited by" $CAPid
                $query = "MERGE (u:Base {objectid:'$UserID', displayName:'$UserDisplayName'})"
        
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
        foreach ($ID in $users.value.id.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (u:Base) WHERE u.objectid='$ID' MATCH (p:Base) WHERE p.UserID='$ID' MERGE (u)-[:IsLimitedBy]->(p)"
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
        Write-Host "Groups retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        $groups.value | %{

            $GroupID = $_.id.ToUpper()
            $GroupDisplayName = $_.displayName
        
            $CreateGroupNodes | %{
                #Write-Host $_ " is limited by" $CAPid
                $query = "MERGE (g:Base {objectid:'$GroupID', displayName:'$GroupDisplayName'})"
        
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
        foreach ($ID in $groups.value.id.ToUpper())
        {
            $headers = @{
                "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
            }
            $query = "MATCH (g:Base) WHERE g.objectid='$ID' MATCH (p:Base) WHERE p.GroupID='$ID' MERGE (g)-[:IsLimitedBy]->(p)"
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
}