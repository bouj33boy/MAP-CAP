Function Run-Collection
{
<#
.DESCRIPTION
Requests data from Azure API Clients to define current Conditional Access Policies and map them in the context of the users.
POC for Bloodhound graph mapping but for Conditional Access within Azure
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
    $neo4JUserName="neo4j"

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
$apiUrl = "https://graph.microsoft.com/"

# Start Calling Functions #
Test-Neo4J
Collect-CAP
Collect-App
Collect-Users
Collect-Groups
Run-Ingestion
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
        Write-Output "Neo4j Import Directory: $importDirectory"
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
        $outputFile = $importDirectory + "/ConditionalAccessPolicies.json"
        
        if (Test-Path $outputFile) {
            Write-Host "Error: ConditionalAccessPolicies.json already exists in this path."
        }
        else {
            $parsedaccessPolicies = $accessPolicies | ConvertTo-Json -Depth 100
            $parsedaccessPolicies | Out-File -FilePath $outputFile -Encoding utf8 -Force
            $outFileLocation = (Get-Item $outputFile).FullName
            Write-Host "Conditional Access Policies can be found at $outFileLocation"
        }
    }
    else {
        Write-Host "Failed to retrieve Conditional Access Policies."
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
        $outputFile = $importDirectory + "/Applications.json"
        
        if (Test-Path $outputFile) {
            Write-Host "Error: Applications.json already exists in this path."
        }
        else {
            $parsedApplications = $applications | ConvertTo-Json -Depth 100
            $parsedApplications | Out-File -FilePath $outputFile -Encoding utf8 -Force
            $outFileLocation = (Get-Item $outputFile).FullName
            Write-Host "Applications can be found at $outFileLocation"
        }
    }
    else {
        Write-Host "Failed to retrieve Applications."
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
        $outputFile = $importDirectory + "/Users.json"
        
        if (Test-Path $outputFile) {
            Write-Host "Error: Users.json already exists in this path."
        }
        else {
            $parsedUsers = $users | ConvertTo-Json -Depth 100
            $parsedUsers | Out-File -FilePath $outputFile -Encoding utf8 -Force
            $outFileLocation = (Get-Item $outputFile).FullName
            Write-Host "Users can be found at $outFileLocation"
        }
    }
    else {
        Write-Host "Failed to retrieve Users."
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
    $apiTarget = $apiUrl+$betaUrlGroups
    $apiTarget = if ($beta) 
    { 
        $apiUrl + $betaUrlGroups 
    } else { 
        $apiUrl + $apiUrlGroups 
    }
    $groups = Invoke-RestMethod -Uri $apiTarget -Headers $headers -Method Get
    if ($groups -and $groups.value -match "membershipRule") {
        Write-Host "Groups retrieved successfully."
        $outputFile = $importDirectory + "/Groups.json"
        
        if (Test-Path $outputFile) {
            Write-Host "Error: Groups.json already exists in this path."
        }
        else {
            $parsedUsers = $users | ConvertTo-Json -Depth 100
            $parsedUsers | Out-File -FilePath $outputFile -Encoding utf8 -Force
            $outFileLocation = (Get-Item $outputFile).FullName
            Write-Host "Groups can be found at $outFileLocation"
        }
    }
    else {
        Write-Host "Failed to retrieve Groups."
    }    
}
Function Run-Ingestion
{
    # Default API Target is: "http://localhost:7474"
    # Default Neo4j version is 5.6
    $headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
    }
    
}