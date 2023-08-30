Function Get-CAPBypassRecipe {
#Get-CAPBypassRecipe -SourceUserID "70353BB0-882A-41A0-97E2-6663C2662E33" -TargetAppID "DE8BC8B5-D9F9-48B1-A8AD-B748DA725064" -neo4JPassword "PASSWORD" -neo4JUserName "neo4j"

[CmdletBinding()]
Param (
    [Parameter(
        Mandatory = $True

    )]
    [String]
    $SourceUserID,

    [Parameter(
        Mandatory = $false

    )]
    [String]
    $TargetAppID,

    [Parameter(
        Mandatory = $false
    )]
    [string]
    $neo4JUserName = "neo4j",

    [Parameter(
        Mandatory = $false
    )]
    [string]
    $neo4JPassword = "canopener",

    [Parameter(
        Mandatory = $false
    )]
    [switch]
    $AllApps
)
If ($AllApps) {
    # If $AllApps is specified, require Error if TargetAppID is specified too
    If ($TargetAppID) {
        Write-Error "When specifying the AllApps parameter, do not use the TargetAppID parameter."
        return
    }
}
    $headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($neo4JUserName):$($neo4JPassword)"))
    }
    If ($AllApps) {
        Write-Host  -ForegroundColor green "You queried all applications with SourceUserID:'$SourceUserID'"
        $QueryAllApps = "MATCH r=(sp:AZServicePrincipal) Return r"
        $ResponseAllApps = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$QueryAllApps",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@
                $TargetAppIDs = $ResponseAllApps.results.data.row.appId
                $TargetAppNames = $ResponseAllApps.results.data.row.displayName
                if ($TargetAppIDs.Length -ne $TargetAppNames.Length) {
                    Write-Error "The arrays TargetAppIDs and TargetAppNames do not have the same length!"
                    return
                }
                # Create an array of custom objects
                $csvData = for ($i = 0; $i -lt $TargetAppIDs.Length; $i++) {
                    [PSCustomObject]@{
                        'AppID'   = $TargetAppIDs[$i]
                        'AppName' = $TargetAppNames[$i]
                    }
                }
                foreach ($TargetAppID in $TargetAppIDs) {
                    $Query = "MATCH (u:AZUser {userId:'$SourceUserID'}) MATCH (sp:AZServicePrincipal {appId:'$TargetAppID'}) MATCH condition = (u)-[:LimitedBy]->(p)-[:LimitsAccessTo]->(sp) RETURN p"
    $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@ -ErrorAction SilentlyContinue
        If ($Response.results.data.row.appID -eq "ALL") {
            $existingColumns = $csvData[0].PSObject.Properties.Name | Where-Object { $_ -match '^AccessLevel\d+$' }
            if ($existingColumns) {
                $highestColumnNumber = ($existingColumns | ForEach-Object { [int]($_ -replace 'AccessLevel', '') } | Sort-Object -Descending)[0]
                $nextColumnNumber = $highestColumnNumber + 1
            } else {
                $nextColumnNumber = 1
            }
            $columnName = "AccessLevel$nextColumnNumber"
            $ResultsAllApps += $Response.results.data.row
            $ResultsCAPName = $Response.results.data.row.displayName
            foreach ($row in $csvData){
                if ($row.AppID -eq $TargetAppID){
                    $row | Add-Member -Name $columnName -Value "CAP:'$ResultsCAPName'" -MemberType NoteProperty -Force
                }

        }
        If ($Response.results.data.row -ne $null -or $Response.results.data.row.appID -eq "ALL") {
            $existingColumns = $csvData[0].PSObject.Properties.Name | Where-Object { $_ -match '^AccessLevel\d+$' }
            if ($existingColumns) {
                $highestColumnNumber = ($existingColumns | ForEach-Object { [int]($_ -replace 'AccessLevel', '') } | Sort-Object -Descending)[0]
                $nextColumnNumber = $highestColumnNumber + 1
            } else {
                $nextColumnNumber = 1
            }
            $columnName = "AccessLevel$nextColumnNumber"
            $ResultsAllApps += $Response.results.data.row
            $ResultsCAPName = $Response.results.data.row.displayName
            foreach ($row in $csvData){
                if ($row.AppID -eq $TargetAppID){
                    $row | Add-Member -Name $columnName -Value "CAP:'$ResultsCAPName'" -MemberType NoteProperty -Force
                }

            }
        Else {
            # Check what groups the user is part of
            # Check if that group is limited by a CAP
            $Query = "MATCH (u:AZUser {userId:'$SourceUserID'}) MATCH (g:AZGroup) MATCH r= (u)-[:MemberOf]->(g) RETURN g.groupId" 
    $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@ -ErrorAction SilentlyContinue
        If ($Response.results.data.row) {
            # UserID is referenced in a group
            # Check to see if any caps reference that groupID
            $groupIDs = $Response.results.data.row
            foreach ($groupId in $groupIDs){
                $Query = "MATCH (g:AZGroup {groupId:'$groupId'}) MATCH (p:AZConditionalAccessPolicy) MATCH r = (g) - [:LimitedBy]-> (p) RETURN p"
                $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@ -ErrorAction SilentlyContinue
                if ($Response.results.data.row){
                    #Test to make sure this CAP is one that limits TargetAppID
                    $CAPIDs = $Response.results.data.row.objectId
                    foreach ($CAPID in $CAPIDs){
                        $Query = "MATCH (p:AZConditionalAccessPolicy {objectId:'$CAPID'}) MATCH (sp:AZServicePrincipal {appId:'TargetAppID'}) MATCH r= (p) - [:LimitsAccessTo]->(sp) RETURN r"
                        $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@ -ErrorAction SilentlyContinue
                        if ($Response.results.data.row){
                            Write-Host -ForegroundColor red "User:'$SourceUserID' is member of '$groupId' which is limited by '$CAPID' to get to the TargetApp:'$TargetAppID'."
                        }
                        else {
                            #Don't Do this
                            Write-Host -ForegroundColor green "User:'$SourceUserID' is member of '$groupId' which is limited by Conditional Access Policy:'$CAPID' but the TargetApp:'$TargetAppID' is not referenced by this Conditional Access Policy, so access to this specific application may not be limited."
                            # Instead create a file in the local directory that will append every AppId that CAPID isn't limiting their access to
                            # Then after this: Tell them that the CAPID isn't associated with the following apps in the directory BUT if more than one CAP is applied - the other CAP might catch them
                        }
                        }
                    } 
                } 
            }
            $Query = $Response.results.data.row.displayName
            Write-Host -ForegroundColor cyan "Conditional Access Policy:'$CAPDisplayName' is limiting this user."
            $ResultsAllApps += $Response.results.data.row
            }
            


        }
        }
        If ($ResultsAllApps){
            $DisplayNames = $ResultsAllApps.displayName | Sort-Object -Unique
            foreach ($DisplayName in $DisplayNames){
                Write-Host -ForegroundColor cyan "Conditional Access Policy:'$DisplayName' is limiting this user from accessing some applications."
            }
            Write-Host 
            
        }

    }
    }
    $Response = $ResultsAllApps
    }              
    Else {
    Write-Host  -ForegroundColor green "You queried TargetAppID:'$TargetAppID' with SourceUserID:'$SourceUserID'"
    $Query = "MATCH (u:AZUser {userId:'$SourceUserID'}) MATCH (sp:AZServicePrincipal {appId:'$TargetAppID'}) MATCH condition = (u)-[:LimitedBy]->(p)-[:LimitsAccessTo]->(sp) RETURN p"
    $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@  -ErrorAction SilentlyContinue
        If ($Response.results.data.row) {
            $ResultsAllApps += $Response.results.data.row
            }
        $Response = $ResultsAllApps
        }
    If (!($Response -eq $null)) {
        $Response | %{
            $CAPState = $_.state
            $TargetAppID = $_.appId
            $CAPDisplayName = $_.displayName
            $CAPEnforcementAction = $_.enforcementAction
            $appEnforcedRestrictions = $_.appEnforcedRestrictions
            $deviceControlsRule = $_.deviceControlsRule
            $deviceControlsEnabled = $_.deviceControlsEnabled
            $disabledResilience = $_.disabledResilience
            $continuousAccessEvaluation = $_.continuousAccessEvaluation
            $groupId = $_.groupId
            $userRiskLevel = $_.userRiskLevel
            $includedUserActions = $_.includedUserActions
            $platforms = $_.platforms
            $persistentBrowser = $_.persistentBrowser
            $secureSignIn = $_.secureSignIn
            $signInFrequency = $_.signInFrequency
            $locations = $_.locations
            $cloudAppSec = $_.cloudAppSec
            $TargetAppID | %{
            Write-Host -ForegroundColor magenta  "Conditional Access Policy: '$CAPDisplayName' between  SourceUserID:'$SourceUserID' and TargetAppID:'$TargetAppID'"
            }
            If (!($CAPState -Match "enabled" -or -not "enabledForReportingButNotEnforced")){
                        Write-Host -ForegroundColor lightgreen "Conditional Access Policy: '$CAPDisplayName' is disabled, user can access TargetAppID:'$TargetAppID'."
                }
                Else {
                    #CAP is enabled, time for analysis...
                    If (!($CAPState -Match "enabled")) {
                            Write-Host -ForegroundColor magenta "[OPSEC]"
                            Write-Host -ForegroundColor magenta "Conditional Access Policy:'$CAPDisplayName' is enabled for report-only mode. User can access TargetAppID:'$TargetAppID', however accessing this application will generate events logged in the Conditional Access and Report-only tabs of the Sign-in log details."
                    }
                    Else {   
                        If ($CAPEnforcementAction -Match "Block") {
                            Write-Host -ForegroundColor darkred "Conditional Access Policy: '$CAPDisplayName' is set to ENABLED and BLOCK for access to TargetAppID:'$TargetAppID'"
                            If ($groupId -not $null) {
                                $Query = "MATCH (u:AZUser {userId:'$SourceUserID'}) MATCH (sp:AZServicePrincipal {appId:'$TargetAppID'}) MATCH condition = (u)-[:LimitedBy]->(p)-[:LimitsAccessTo]->(sp) RETURN p"
                                $Response = Invoke-RestMethod `
        -Uri "http://localhost:7474/db/neo4j/tx/commit" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body @"
        {
            "statements": [
                {
                    "statement": "$Query",
                    "resultDataContents": ["row"]
                }
            ]
        }
"@ 

                            }

                        Else {
                            Write-Host -ForegroundColor darkred "Conditional Access Policy: '$CAPDisplayName' is set to ENABLED and ALLOW for access to TargetAppID:'$TargetAppID'"
                        }

                        }
                    }
                    }

                    }

            }
            }
     <# There is at least one CAP between the user and the target app
        If (!($Response.results.data.state -Match "enabled")){
            If (!($Response.results.data.state -Match "enabledForReportingButNotEnforced")){
                Write-Host "Conditional Access Policy: '$CAPDisplayName' is not enabled, user can access application."
            }
        else {
            #CAP is enabled, time for analysis...
            If ($Response.results.data.row.enforcementAction -Match "block") {

            }
        

            }
        }
        
            Write-Host "The user is blocked from accessing the application, there is no known bypass."
        }

    }#>