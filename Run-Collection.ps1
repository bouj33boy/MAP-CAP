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
Run-Collection -beta -neo4JPassword "PASSWORD" -neo4JUserName "USERNAME" -accessToken $accessToken

.EXAMPLE
ipmo ./Run-Collection.ps1
Run-Collection -oldResource -accessToken $accessToken2 -accessToken2 $accessToken -tenantId $tenantId

.PARAMETER accessToken
This is the bearer access token granted by your Azure tenant upon successful authentication. 
View the README.md and follow the steps listed to save your access token as a variable $accessToken

.PARAMETER beta
This is a context switch that will make the scrip utilize the /beta API endpoint instead of v1.0.

####################################################################################
The below parameters are specific to the older resource https://graph.windows.net. #
####################################################################################
.PARAMETER tenantId
This is only utilized in conjunction with accessToken2 and resourceOld to define the tenantId when pulling 
from the older resource https://graph.windows.net.

.PARAMETER accessToken2
This is the bearer access token granted by your Azure tenant upon successful authentication for authenticating 
to the older resource https://graph.windows.net.

.PARAMETER resourceOld
This switch parameter tells the script that you specifically want to pull from the older resource https://graph.windows.net.
If you ran this script without this switch or with beta and there are no conditional access policies within the neo4j database, 
it is likely that the resource provider needed is https://graph.windows.net.

#####################################################################################
The below parameters are specific to the neo4j instance that you are using locally. #
This was designed as a POC. For larger environments you'll likely need to use a     #
larger resource to handle graph visualizations.                                     #
#####################################################################################

.PARAMETER neo4JURL
This parameter specifies the neo4j instance to target and ingest the JSON fields. Default is "http://localhost:7474"

.PARAMETER neo4JUserName
This parameter specifies the neo4j username used for authentication. Default is "neo4j"

.PARAMETER neo4JPassword
This parameter specifies the neo4j password used for authentication. Default is "neo4j"

.NOTES

--------------------------------
AUTHOR
Joshua Prager, @bouj33boy
SpecterOps

.VERSION
2.0

.DATE
09/12/2023

.REQUIRED DEPENDENCIES
This script requires the following modules:
    - Local neo4j instance running

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
    $tenantId,

    [Parameter(Mandatory=$false)]
    [string]
    $accessToken2,

    [Parameter(Mandatory=$false)]
    [switch]
    $resourceOld,
    
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
Collect-Groups
Collect-Users
Collect-CAP
Write-Host -ForegroundColor green "Collection Complete. You should now be able to view data in Neo4J database."
Write-Host -ForegroundColor green "Try running the following in Neo4J Desktop:"
Write-Host -ForegroundColor white "MATCH POC = (u)-[:LimitedBy]->(p) RETURN POC"
Write-Host -ForegroundColor DarkMagenta "Now that you collected the elements, identify subversions with Get-CAPSubversionRecipe.ps1"
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
    # Setting errorActionPreference because each CAP is set a little bit differently and we want to avoid $null value errors where conditions are not set
    #############################################
    #$ErrorActionPreference = 'SilentlyContinue'##
    #####Comment This Out If To Troubleshoot#####
    # Initialize headers in each function to avoid errors
    if ($resourceOld -eq $true) {
        Write-Host "You chose to switch to the oldResource:  https://graph.windows.net"
        if ($accessToken2 -eq $null){
            Write-Host "Access Token for Resource: https://graph.windows.net is needed, pass second access token to AccessToken2 parameter"
        } else {
        $headers = @{
                "Authorization" = "Bearer $accessToken2"
                "Content-Type" = "application/json; charset=utf-8"
            }
            $accessPolicies = Invoke-RestMethod `
                -UseBasicParsing `
                -Uri "https://graph.windows.net/$tenantId/policies?api-version=1.61-internal" `
                -Method "GET" `
                -Headers $headers 
            }
            #Filter access policies based on PolicyType: 18
            #change the name below (mispelling)
            $filteredPolicies = $accessPolicies.value | Where-Object { $_.policyType -eq 18 }
            $filtdPolicies | %{
                $CAPid = $_.objectId.ToUpper()
                $CAPDisplayName = $_.displayName
                $policyDetails = $_.policyDetail | ConvertFrom-Json
                    $policyDetails | %{
                        $IncludedUsers = $_.Conditions.Users.Include.Users | ConvertTo-Json
                        $IncludedUsers | %{
                            $UserId = $_.ToUpper()
                        }
                        $IncludedApplications = $_.Conditions.Applications.Include.Applications |  ConvertTo-Json
                        $IncludedApplications = $_.Conditions.Applications.Include.Applications |  ConvertTo-Json
                        $IncludedApplications | %{
                            $AppID = $_.ToUpper()
                        }
                        $DeviceControlsRule = $_.Conditions.Devices.DeviceRule | ConvertTo-Json
                        $CAPState = $_.State
                        $enforcementAction = $_.Controls.Control
                        $ClientType = $_.Conditions.ClientTypes.Include.ClientTypes | ConvertTo-Json
                        $IncludedPlatforms = $_.Conditions.DevicePlatforms.Include.DevicePlatforms | ConvertTo-Json
                        }
                    }
            if ($filteredPolicies) {
                Write-Host -ForegroundColor Cyan "Conditional Access Policies retrieved successfully."
                $headers = @{
                    "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
                }
                Write-Host -ForegroundColor magenta "Ingesting Conditional Access Policies into Neo4j."
                $CreateCAPNodes | %{
            $query = "MERGE (p:Base {objectId:'$CAPid', displayName:'$CAPDisplayName', state:'$CAPState',appId:'$AppID', userId:'$UserId', enforcementAction:'$enforcementAction', deviceControlsEnabled:'$DeviceControlsRule', clientTypes: '$ClientType', platforms: '$IncludedPlatforms'}) SET p:AZConditionalAccessPolicy"
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
        # Create (:AZConditionalAccessPolicy) - [:LimitsAccessTo]->(:AZServicePrincial) All Edges
        $filterdPolicies | %{
            $CAPid = $_.objectId.ToUpper()
            $policyDetails = $_.policyDetail | ConvertFrom-Json
            $policyDetails | %{
                $IncludedApplications = $_.Conditions.Applications.Include.Applications |  ConvertTo-Json
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
                $IncludedApplications | %{
                    $AppID = $_.ToUpper()
                    Write-Host -ForegroundColor magenta "Creating edge ('$CAPid':AZConditionalAccessPolicy) - [:LimitsAccessTo]->('$AppID':AZServicePrincial)"
                    $query = "MATCH (p:Base {objectId:'$CAPid'}) MATCH (sp:AZServicePrincipal {appId:'$AppID'}) MERGE (p)-[:LimitsAccessTo]-> (sp)"
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
        $IncludedUsers = $_.Conditions.Users.Include.Users | ConvertTo-Json
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
            $IncludedUsers | %{
                $UserId = $_.ToUpper()
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
        
                }
            }

        }


    } elseif ($resourceOld -eq $false) {
    Write-Host "You selected the resource graph.microsoft.com to target" 
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
    }    
    if ($accessPolicies -and $accessPolicies.value -match "conditions") {
        Write-Host -ForegroundColor Cyan "Conditional Access Policies retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        Write-Host -ForegroundColor magenta "Ingesting Conditional Access Policies into Neo4j."
        $accessPolicies.value | %{

            $CAPid = $_.id.ToUpper()
            $CAPDisplayName = $_.displayName
            $CAPState = $_.state
            $IncludedApplications = $_.Conditions.applications.includeApplications
            $IncludedApplications | %{
                #Write-Host $_ "access is limited by" $CAPid
                $AppID = $_.ToUpper()
            }
            $IncludedUsers = $_.Conditions.users.includeUsers
            $IncludedUsers | %{
                #Write-Host $_ " is limited by" $CAPid
                $UserId = $_.ToUpper()
            }
            $ExcludedUsers = $_.Conditions.users.excludeUsers
            $ExcludedUsers | %{
                $ExcludedUsersID = $_.ToUpper()
            }
            $IncludedGroups = $_.Conditions.users.includeGroups
            $IncludedGroups | %{
                $GroupID = $_.ToUpper()
            }
            $ExcludedGroups = $_.Conditions.users.excludeGroups
            $ExcludedGroups | %{
                $ExcludeGroupID = $_.ToUpper()
            }
            $enforcementAction = $_.grantControls.builtInControls
            $IncludedLocations = $_.Conditions.locations.includeLocations
            $IncludedLocations | %{
                if ($IncludedLocations -ne $null){
                    $LocationID = $_.ToUpper()
                } 
            }
            $IncludedUserActions = $_.Conditions.applications.includeUserAction
            $DisabledResilience = $_.sessionControls.disableResilienceDefaults
            $AppEnforcedRestrictions = $_.sessionControls.applicationEnforcedRestrictions
            $PersistentBrowser = $_.sessionControls.persistentBrowser
            $CloudAppSec = $_.sessionControls.cloudAppSecurity
            $SignInFrequency = $_.sessionControls.signInFrequency
            $CAE = $_.sessionControls.continuousAccessEvaluation
            $SecureSignIn = $_.sessionControls.secureSignInSession
            $DeviceControls = $_.Conditions.devices.deviceFilter.mode
            $DeviceControlsRule = $_.Conditions.devices.deviceFilter.rule
            $UserRiskLevel = $_.Conditions.userRiskLevels
            $IncludedPlatforms = $_.Conditions.platforms.includePlatforms

        $CreateCAPNodes | %{
            $query = "MERGE (p:Base {objectId:'$CAPid', displayName:'$CAPDisplayName', state:'$CAPState',appId:'$AppID', userId:'$UserId', excludedUserId:'$ExcludedUsersID', groupId:'$GroupID', excludedGroupId:'$ExcludeGroupID', enforcementAction:'$enforcementAction', locations:'$LocationID', includedUserActions:'$IncludedUserActions', disabledResilience:'$DisabledResilience', appEnforcedRestrictions:'$AppEnforcedRestrictions', persistentBrowser:'$PersistentBrowser', cloudAppSec:'$CloudAppSec', signInFrequency:'$SignInFrequency', continuousAccessEvaluation:'$CAE', secureSignIn:'$SecureSignIn', deviceControlsEnabled:'$DeviceControls', deviceControlsRule:'$DeviceControlsRule', userRiskLevel:'$UserRiskLevel', platforms:'$IncludedPlatforms'}) SET p:AZConditionalAccessPolicy"
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
Function Collect-Users
{
    # Initialize headers in each function to avoid errors
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }
    $apiUrlUsers = "v1.0/users/?`$count=true"
    $betaUrlUsers = "beta/users/?`$count=true"
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlUsers 
    } else { 
        $apiUrl + $apiUrlUsers 
    }
    $uri = $apiTarget
    $ShowProgress = $True
    $Results = $null
    $UserObjects = $null
    If ($ShowProgress) {
        Write-Progress -Activity "Enumerating Users" -Status "Initial request..."
    }
    do {
        $Results = Invoke-RestMethod `
        -Headers @{
            Authorization = "Bearer $($accessToken)"
            ConsistencyLevel = "eventual"
        } `
        -URI $uri `
        -UseBasicParsing `
        -Method "GET" `
        -ContentType "application/json"
    if ($Results.'@odata.count') {
        $TotalUserCount = $Results.'@odata.count'
    }
    if ($Results.value) {
        $UserObjects += $Results.value
    } else {
        $UserObjects += $Results
    }
    $uri = $Results.'@odata.nextlink'
    If ($ShowProgress) {
        $PercentComplete = ([Int32](($UserObjects.count/$TotalUserCount)*100))
        Write-Progress -Activity "Enumerating Users" -Status "$($PercentComplete)% complete [$($UserObjects.count) of $($TotalUserCount)]" -PercentComplete $PercentComplete
    }
    } until (!($uri))
    $headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
    }
    if ($UserObjects) {
        Write-Host -ForegroundColor Cyan "Users retrieved successfully."
        Write-Host -ForegroundColor magenta "Ingesting users into Neo4j."
        $UserObjects | %{
            $UserId = $_.id.ToUpper()
            $UserDisplayName = $_.displayName  
            $CreateUserNodes | %{
                $query = "MERGE (u:Base {userId:'$UserId', displayName:'$UserDisplayName'}) SET u:AZUser"        
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
                $usersCount = $UserObjects.id.Count
                for ($i = 0; $i -lt $usersCount; $i++) {
                    if ($i -gt $usersCount) {
                        Write-Host "Exceeded expected number of users, breaking loop."
                        break
                    }
                    $user = $UserObjects[$i]
                    $UserId = $user.id.ToUpper()
                    $headers = @{
                        "Authorization" = "Bearer $accessToken"
                        "Content-Type" = "application/json"
                    }
                    $CheckMembersAPI = "https://graph.microsoft.com/v1.0/users/$UserId/checkMemberGroups"
                    foreach ($group in $groupArrays){
                        $groupIds = $group 
                        $body = @{
                            "groupIds" = $groupIds
                        } | ConvertTo-Json
                        $CheckMemberResponse = Invoke-RestMethod -Method POST -Uri $CheckMembersAPI -Headers $headers -Body $body
                        $GroupIDs = $CheckMemberResponse.value
                        If ($GroupIDs) {
                            foreach ($g in $GroupIDs){
                                $groupID = $g.ToUpper()
                                $headersNeo4j = @{
                                    "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
                                }
                                $query = "MATCH (g:AZGroup {groupId:'$groupID'}) MATCH (u:AZUser {userId:'$UserId'}) MERGE (u)-[:MemberOf]->(g)"       
                $response = Invoke-RestMethod `
                -Uri "http://localhost:7474/db/neo4j/tx/commit" `
                -Headers $headersNeo4j `
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
"@
                        }
                    }
                }
                # Update the progress bar
                Write-Progress -Activity "Creating edges between users and groups" -Status "Processing user $i of $usersCount" -PercentComplete (($i / $usersCount) * 100)
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
    $uri = $apiTarget
    $ShowProgress = $True
    $Resulsts = $null
    $GroupObjects = $null
    If ($ShowProgress){
        do {
            $Results = Invoke-RestMethod `
                -Headers @{
                    Authorization = "Bearer $($accessToken)"
                    ConsistencyLevel = "eventual"
                } `
                -URI $uri `
                -UseBasicParsing `
                -Method "GET" `
                -ContentType "application/json"
            if ($Results.'@odata.count') {
                $TotalGroupsCount = $Results.'@odata.count'
            }
            if ($Results.value) {
                $GroupObjects += $Results.value
            } else {
                $GroupObjects += $Results
            }
            $uri = $Results.'@odata.nextlink'
            If ($ShowProgress) {
                $PercentComplete = ([Int32](($GroupObjects.count/$TotalGroupsCount)*100))
                Write-Progress -Activity "Enumerating Groups" -Status "$($PercentComplete)% complete [$($GroupObjects.count) of $($TotalGroupsCount)]" -PercentComplete $PercentComplete
            }
        } until (!($uri))
    if ($GroupObjects -and $GroupObjects -match "membershipRule") {
        Write-Host -ForegroundColor Cyan "Groups retrieved successfully."
        $headers = @{
            "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
        }
        Write-Host -ForegroundColor magenta "Ingesting groups into Neo4j."
        $GroupObjects | %{

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
        # Creating array from which to compare user relationships
        $groupArray = $GroupObjects.id
        # Create a global variable to hold the groups
        $global:groupArrays = New-Object System.Collections.ArrayList
        if ($groupArray.count -gt 20) {
            # Calculate the number of groups (as per Microsoft, can't be gt 20)
            $groupIdCount = [math]::Ceiling($groupArray.count / 20)
            for ($i = 0; $i -lt $groupIdCount; $i++) {
                # Get the subsets of 20 group Ids from the groupArray
                $subsetId = $groupArray | Select-Object -Skip ($i * 20) -First 20
                $global:groupArrays.Add($subsetId) | Out-Null 
            }

        } 
        } 
    } 
}
}