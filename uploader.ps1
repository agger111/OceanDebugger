$folderName = "Ocean-Debug-Logs"
$zipPath = Join-Path $env:TEMP "Ocean-Debug-Logs.zip"
$webhookUrl = "https://discord.com/api/webhooks/1531786262107914333/gC5akS9pT8c-P1bQi_5vllOQWhHQotxbpl2D5FDxgZrBhzS_6pqu7NEnCG96E2lQfpl-"

# 1. Try to find the folder in common Desktop locations
$possibleDesktops = @(
    [Environment]::GetFolderPath("Desktop"),
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\OneDrive\Desktop",
    "$env:USERPROFILE\OneDrive\Bureau",
    "$env:USERPROFILE\Bureau",
    "$env:USERPROFILE\Escritorio"
)

$folderPath = $null
foreach ($desk in $possibleDesktops) {
    if (-Not [string]::IsNullOrWhiteSpace($desk)) {
        $testPath = Join-Path $desk $folderName
        if (Test-Path $testPath) {
            $folderPath = $testPath
            break
        }
    }
}

# 2. If it's not in the standard Desktop paths, search the user profile just in case
if (-not $folderPath) {
    Write-Host "Could not find on Desktop. Searching user profile..." -ForegroundColor Yellow
    $found = Get-ChildItem -Path $env:USERPROFILE -Directory -Recurse -Filter $folderName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $folderPath = $found.FullName
    }
}

# 3. If we still couldn't find it, stop the script
if (-not $folderPath) {
    Write-Host "Error: Could not find the folder '$folderName' anywhere in $env:USERPROFILE" -ForegroundColor Red
    exit
}

Write-Host "Found folder at: $folderPath" -ForegroundColor Green

# Step 1: Compress the folder into a ZIP file (Saving to TEMP to avoid permission issues)
Write-Host "Compressing folder into ZIP..." -ForegroundColor Cyan
Compress-Archive -Path $folderPath -DestinationPath $zipPath -Force

if (-Not (Test-Path $zipPath)) {
    Write-Host "Error: Failed to create the ZIP file." -ForegroundColor Red
    exit
}

# Step 2: Upload the ZIP file to the Discord Webhook
Write-Host "Sending ZIP file to Discord..." -ForegroundColor Cyan

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
    $fileStream.Close()
    $httpClient.Dispose()
    
    # Step 3: Clean up the temporary ZIP file
    Remove-Item -Path $zipPath -Force
    Write-Host "Temporary ZIP file cleaned up." -ForegroundColor DarkGray
}