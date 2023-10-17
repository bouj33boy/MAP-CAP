------ Old Resource -------
Function Get-AccessToken {
    $body = @{
        "client_id" = "1950a258-227b-4e31-a9cf-717495945fc2"
        "resource" = "https://graph.windows.net"
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

$accessToken2 = $Tokens.access_token

# Prep for token stuff

------ New Resource -------
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
