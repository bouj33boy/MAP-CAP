# Define the Azure AD tenant and app details
$tenantId = "your-tenant-id"
$clientId = "your-client-id"
$clientSecret = "your-client-secret"
$scope = "https://graph.microsoft.com/.default"

# Get the access token using the client credentials flow
$tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$body = @{
    client_id     = $clientId
    scope         = $scope
    client_secret = $clientSecret
    grant_type    = "client_credentials"
}

$response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -ContentType "application/x-www-form-urlencoded" -Body $body
$accessToken = $response.access_token

# Define the Graph API headers
$headers = @{
    "Authorization" = "Bearer $accessToken"
}

# Read the list of GUIDs from the file
$guidsFilePath = "C:\path\to\your\guids.txt"
$guids = Get-Content -Path $guidsFilePath | ConvertFrom-Json

# Function to get display name for a single GUID
function Get-DisplayName {
    param (
        [string]$guid
    )
    
    $url = "https://graph.microsoft.com/v1.0/directoryObjects/$guid"
    $object = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
    return $object.displayName
}

# Loop through each GUID and retrieve the display name
$results = @()
foreach ($guid in $guids) {
    try {
        $displayName = Get-DisplayName -guid $guid
        $results += [PSCustomObject]@{
            GUID = $guid
            DisplayName = $displayName
        }
    } catch {
        Write-Output "Error retrieving display name for GUID: $guid"
        Write-Output "Exception: $_"
    }
}

# Output the results
$results | Format-Table -AutoSize
