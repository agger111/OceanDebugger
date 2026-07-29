# Define paths and webhook URL
$folderPath = "$env:USERPROFILE\Desktop\Ocean-Debug-Logs"
$zipPath = "$env:USERPROFILE\Desktop\Ocean-Debug-Logs.zip"
$webhookUrl = "https://discord.com/api/webhooks/1531786262107914333/gC5akS9pT8c-P1bQi_5vllOQWhHQotxbpl2D5FDxgZrBhzS_6pqu7NEnCG96E2lQfpl-"

# Check if the folder exists before proceeding
if (-Not (Test-Path $folderPath)) {
    Write-Host "Error: Could not find the folder at $folderPath" -ForegroundColor Red
    exit
}

# Step 1: Compress the folder into a ZIP file
Write-Host "Compressing folder into ZIP..." -ForegroundColor Cyan
Compress-Archive -Path $folderPath -DestinationPath $zipPath -Force

if (-Not (Test-Path $zipPath)) {
    Write-Host "Error: Failed to create the ZIP file." -ForegroundColor Red
    exit
}

# Step 2: Upload the ZIP file to the Discord Webhook
Write-Host "Sending ZIP file to Discord..." -ForegroundColor Cyan

# Using System.Net.Http for reliable multipart/form-data upload (works on PowerShell 5.1 and 7+)
Add-Type -AssemblyName System.Net.Http
$httpClient = New-Object System.Net.Http.HttpClient
$multipartContent = New-Object System.Net.Http.MultipartFormDataContent
$fileStream = [System.IO.File]::OpenRead($zipPath)
$fileContent = New-Object System.Net.Http.StreamContent($fileStream)
$fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/zip")
$multipartContent.Add($fileContent, "file", "Ocean-Debug-Logs.zip")

try {
    $response = $httpClient.PostAsync($webhookUrl, $multipartContent).Result
    $response.EnsureSuccessStatusCode()
    Write-Host "Successfully sent the logs to Discord!" -ForegroundColor Green
} catch {
    Write-Host "Failed to send to Discord: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # Close streams and dispose of the HTTP client
    $fileStream.Close()
    $httpClient.Dispose()
    
    # Step 3: Clean up the temporary ZIP file
    Remove-Item -Path $zipPath -Force
    Write-Host "Temporary ZIP file cleaned up." -ForegroundColor DarkGray
}
