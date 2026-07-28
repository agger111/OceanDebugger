#Requires -Version 5.0
<#
===============================================================================
           OCEAN ANTI-CHEAT (OCEAN AC) MASTER DIAGNOSTIC & REPAIR TOOL
===============================================================================
 Single-file version. Just double-click this .ps1 (or right-click ->
 "Run with PowerShell"). It will self-elevate to Administrator if needed.

 Features:
   1. Deep System Diagnostics (Hosts, DNS, Proxies, VPNs, Firewalls, AVs).
   2. Auto-Repair Engine (Removes sinkholes, resets proxies, clears firewall rules).
   3. Network & TLS Handshake Simulator (Tests TLS 1.2/1.3 connection to servers).
   4. Ocean Cache Log Analyzer (Inspects local ocean.log for connection/PIN errors).
   5. Saves report + copies of the Ocean log(s) into an "Ocean-Debug-Logs" folder
      next to this script, then opens that folder when it's done.

 Everything this tool does is local to this PC. Nothing is uploaded anywhere.
===============================================================================
#>

# -----------------------------------------------------------------------------
# SELF-ELEVATION (replaces the old separate .bat launcher)
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Requesting Administrator privileges..." -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Path
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    } catch {
        Write-Host "[FAIL] Elevation was cancelled or failed. The tool needs Admin rights to repair proxy/firewall/hosts settings." -ForegroundColor Red
        pause
    }
    exit
}

$ErrorActionPreference = "SilentlyContinue"

# Force TLS 1.2 and 1.3 support in .NET ServicePointManager
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# -----------------------------------------------------------------------------
# SETUP: Ocean-Debug-Logs folder (placed next to this script)
# -----------------------------------------------------------------------------
$ScriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DebugFolder  = Join-Path -Path $ScriptRoot -ChildPath "Ocean-Debug-Logs"
if (-not (Test-Path $DebugFolder)) {
    New-Item -Path $DebugFolder -ItemType Directory -Force | Out-Null
}

$Timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ReportFile = Join-Path -Path $DebugFolder -ChildPath "Ocean_Master_Report_$Timestamp.txt"

$Detections = @()
$Repairs    = @()
$Warnings   = @()
$Passed     = @()

function Log-Output {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Status = ""
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = if ($Status) { "[$Status]" } else { "" }
    $logLine = "$prefix $Message".Trim()

    Add-Content -Path $ReportFile -Value "[$timestamp] $logLine" -ErrorAction SilentlyContinue

    switch ($Status) {
        "CRITICAL" { Write-Host " [CRITICAL BLOCKER] " -ForegroundColor Black -BackgroundColor Red -NoNewline; Write-Host " $Message" -ForegroundColor Red }
        "FAIL"     { Write-Host " [FAIL] " -ForegroundColor Red -NoNewline; Write-Host " $Message" -ForegroundColor White }
        "REPAIRED" { Write-Host " [REPAIRED] " -ForegroundColor Black -BackgroundColor Green -NoNewline; Write-Host " $Message" -ForegroundColor Green }
        "WARN"     { Write-Host " [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host " $Message" -ForegroundColor White }
        "PASS"     { Write-Host " [PASS] " -ForegroundColor Green -NoNewline; Write-Host " $Message" -ForegroundColor White }
        "INFO"     { Write-Host " [INFO] " -ForegroundColor Cyan -NoNewline; Write-Host " $Message" -ForegroundColor White }
        default    { Write-Host $Message -ForegroundColor $Color }
    }
}

Clear-Host
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "            OCEAN AC MASTER DIAGNOSTIC, REPAIR & HANDSHAKE TOOL                " -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Scan Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "Log Folder: $DebugFolder" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# PHASE 1: SYSTEM & NETWORK DIAGNOSTICS
# -----------------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " [PHASE 1] RUNNING COMPREHENSIVE DIAGNOSTICS..." -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor Gray

# 1.1 OS Version
$os = Get-CimInstance Win32_OperatingSystem
Log-Output "OS: $($os.Caption) (Build $($os.BuildNumber)) - $($os.OSArchitecture)" -Status "INFO"

# 1.2 Hosts File Sinkhole Check
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsItem = Get-Item $hostsPath -ErrorAction SilentlyContinue

if ($hostsItem) {
    if ($hostsItem.IsReadOnly) {
        Log-Output "Hosts file is set to READ-ONLY." -Status "WARN"
        $Warnings += "Hosts file Read-Only flag set"
    }

    $hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue
    $oceanSinkholes = $hostsContent | Where-Object { $_ -notmatch "^\s*#" -and $_ -match "ocean" }

    if ($oceanSinkholes) {
        Log-Output "Hosts file contains Ocean domain sinkhole/block entries!" -Status "FAIL"
        foreach ($line in $oceanSinkholes) {
            Log-Output "   Hosts Entry: $line" -Color Red
        }
        $Detections += "Hosts file Ocean Sinkhole Entries"
    } else {
        Log-Output "Hosts file is clean of Ocean block entries." -Status "PASS"
        $Passed += "Clean Hosts File"
    }
}

# 1.3 Proxy Settings Check
$regProxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
if ($regProxy.ProxyEnable -eq 1) {
    Log-Output "System Proxy is ACTIVE: $($regProxy.ProxyServer)" -Status "FAIL"
    $Detections += "System Proxy Active ($($regProxy.ProxyServer))"
} else {
    Log-Output "System Proxy is Disabled." -Status "PASS"
}

$winHttpProxy = (netsh winhttp show proxy) -join " "
if ($winHttpProxy -notmatch "Direct access" -and $winHttpProxy -match "Proxy Server") {
    Log-Output "WinHTTP Proxy is ACTIVE: $winHttpProxy" -Status "FAIL"
    $Detections += "WinHTTP Proxy Active"
} else {
    Log-Output "WinHTTP Direct Access active." -Status "PASS"
}

# 1.4 Active VPN / Virtual Adapters
$vpnKeywords = @("TAP", "TUN", "WireGuard", "Wintun", "Nord", "ExpressVPN", "Proton", "Mullvad", "OpenVPN", "WARP", "Hamachi", "Radmin", "ZeroTier", "Tailscale")
$adapters = Get-NetAdapter -ErrorAction SilentlyContinue
$activeVpns = @()

foreach ($adapter in $adapters) {
    foreach ($kw in $vpnKeywords) {
        if (($adapter.InterfaceDescription -like "*$kw*" -or $adapter.Name -like "*$kw*") -and $adapter.Status -eq "Up") {
            $activeVpns += "$($adapter.Name) ($($adapter.InterfaceDescription))"
        }
    }
}

if ($activeVpns.Count -gt 0) {
    Log-Output "Active VPN / Virtual Network Adapter(s) detected:" -Status "WARN"
    foreach ($vpn in $activeVpns) {
        Log-Output "   Active Adapter: $vpn" -Color Yellow
    }
    $Warnings += "Active VPN Adapter(s): $($activeVpns -join ', ')"
} else {
    Log-Output "No active VPN adapters detected." -Status "PASS"
}

# 1.5 Firewall Block Rules
$oceanFwRules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    ($_.DisplayName -like "*Ocean*" -or $_.Name -like "*Ocean*") -and $_.Action -eq "Block" -and $_.Enabled -eq "True"
}

if ($oceanFwRules) {
    Log-Output "Windows Firewall BLOCK rules targeting Ocean found!" -Status "FAIL"
    foreach ($rule in $oceanFwRules) {
        Log-Output "   Block Rule: $($rule.DisplayName)" -Color Red
    }
    $Detections += "Firewall Block Rules for Ocean"
} else {
    Log-Output "No Ocean Firewall block rules active." -Status "PASS"
}

# 1.6 Third-Party Security Software
try {
    $3rdPartyFw = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName "FirewallProduct" -ErrorAction SilentlyContinue
    if ($3rdPartyFw) {
        foreach ($fw in $3rdPartyFw) {
            Log-Output "3rd-Party Firewall Active: $($fw.displayName)" -Status "WARN"
            $Warnings += "3rd-Party Firewall ($($fw.displayName))"
        }
    }
} catch {}

# -----------------------------------------------------------------------------
# PHASE 2: AUTOMATED REPAIR & REMEDIATION ENGINE
# -----------------------------------------------------------------------------
Write-Host "`n-------------------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " [PHASE 2] EXECUTING AUTOMATED SYSTEM REPAIRS..." -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor Gray

# 2.1 Repair Hosts File
if (Test-Path $hostsPath) {
    $hostsItem = Get-Item $hostsPath
    if ($hostsItem.IsReadOnly) {
        $hostsItem.IsReadOnly = $false
        Log-Output "Unset Read-Only flag on hosts file." -Status "REPAIRED"
        $Repairs += "Unset Hosts File Read-Only Attribute"
    }

    $content = Get-Content $hostsPath -ErrorAction Stop
    $oceanLines = $content | Where-Object { $_ -match "ocean|oceananticheat|oceanac" }
    if ($oceanLines) {
        $cleaned = $content | Where-Object { $_ -notmatch "ocean|oceananticheat|oceanac" }
        Set-Content -Path $hostsPath -Value $cleaned -Encoding ASCII -Force
        Log-Output "Removed $($oceanLines.Count) Ocean sinkhole line(s) from hosts file." -Status "REPAIRED"
        $Repairs += "Removed Ocean Sinkhole Lines from Hosts File"
    }
}

# 2.2 Reset Proxies
if ($regProxy.ProxyEnable -eq 1) {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name "ProxyEnable" -Value 0
    Log-Output "Disabled System Proxy in Registry." -Status "REPAIRED"
    $Repairs += "Disabled Registry System Proxy"
}

$winhttpRes = netsh winhttp reset proxy 2>&1
if ($winhttpRes -notmatch "Direct access") {
    Log-Output "Reset WinHTTP Proxy to Direct Access." -Status "REPAIRED"
    $Repairs += "Reset WinHTTP Proxy"
}

# 2.3 Remove Firewall Rules
if ($oceanFwRules) {
    foreach ($rule in $oceanFwRules) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        Log-Output "Removed Firewall Rule: $($rule.DisplayName)" -Status "REPAIRED"
        $Repairs += "Removed Firewall Rule ($($rule.DisplayName))"
    }
}

# 2.4 Flush DNS Cache
try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    ipconfig /flushdns | Out-Null
    Log-Output "Flushed Windows DNS Client Cache." -Status "REPAIRED"
    $Repairs += "Flushed DNS Resolver Cache"
} catch {}

# -----------------------------------------------------------------------------
# PHASE 3: SIMULATED NETWORK & TLS HANDSHAKE TEST
# -----------------------------------------------------------------------------
Write-Host "`n-------------------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " [PHASE 3] SIMULATING OCEAN SERVER TLS HANDSHAKE & CONNECTION..." -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor Gray

$targetEndpoints = @(
    "https://ocean.ac",
    "https://api.ocean.ac",
    "https://app.ocean.ac"
)

$handshakeSuccess = $false

foreach ($url in $targetEndpoints) {
    Log-Output "Initiating TLS Handshake with $url..." -Status "INFO"

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout = 8000
    $req.UserAgent = "OceanAC-DiagnosticHandshake/1.0"
    $req.Method = "GET"

    try {
        $resp = $req.GetResponse()
        $statusCode = [int]$resp.StatusCode
        Log-Output "TLS Handshake & HTTP Connection to $url SUCCESSFUL (Status: $statusCode)" -Status "PASS"
        $resp.Close()
        $handshakeSuccess = $true
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response) {
            $resp = [System.Net.HttpWebResponse]$ex.Response
            Log-Output "TLS Handshake connected to $url (HTTP Status: $([int]$resp.StatusCode))" -Status "PASS"
            $handshakeSuccess = $true
            $resp.Close()
        } else {
            $errorMsg = $ex.Message
            Log-Output "TLS Handshake / Connection FAILED for $url" -Status "FAIL"
            Log-Output "   Error Details: $errorMsg" -Color Red

            if ($errorMsg -like "*SSL/TLS*" -or $errorMsg -like "*secure channel*") {
                Log-Output "   -> DIAGNOSIS: TLS Handshake Crash detected! (SSL Protocol / Cipher mismatch or local SSL interception)." -Status "CRITICAL"
                Log-Output "   -> RECOMMENDATION: Install Cloudflare WARP or 1.1.1.1 DNS to bypass local ISP/Router TLS interference." -Status "WARN"
            } elseif ($errorMsg -like "*NameResolution*") {
                Log-Output "   -> DIAGNOSIS: DNS Name Resolution failure (Domain blocked or offline)." -Status "WARN"
            } elseif ($errorMsg -like "*timed out*") {
                Log-Output "   -> DIAGNOSIS: Connection timed out (Firewall blocking port 443 outbound)." -Status "FAIL"
            }
        }
    } catch {
        Log-Output "Unexpected Connection Error: $_" -Status "FAIL"
    }
}

# -----------------------------------------------------------------------------
# PHASE 4: OCEAN CACHE LOG INSPECTOR (+ copy raw logs into Ocean-Debug-Logs)
# -----------------------------------------------------------------------------
Write-Host "`n-------------------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " [PHASE 4] ANALYZING & COLLECTING LOCAL OCEAN LOG FILES..." -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------------------------" -ForegroundColor Gray

$possibleLogPaths = @(
    "$env:USERPROFILE\.oceancache\ocean.log",
    "$env:APPDATA\ocean\ocean.log",
    "$env:LOCALAPPDATA\ocean\ocean.log"
)

$foundLog = $false

foreach ($logPath in $possibleLogPaths) {
    if (Test-Path $logPath) {
        $foundLog = $true
        Log-Output "Found local Ocean log file at: $logPath" -Status "INFO"

        # Copy the raw log into the Ocean-Debug-Logs folder for reference
        try {
            $destName = "ocean_log_$($Timestamp)_$(Split-Path $logPath -Leaf)"
            $destPath = Join-Path -Path $DebugFolder -ChildPath $destName
            Copy-Item -Path $logPath -Destination $destPath -Force -ErrorAction Stop
            Log-Output "Copied Ocean log to: $destPath" -Status "INFO"
        } catch {
            Log-Output "Could not copy Ocean log file: $_" -Status "WARN"
        }

        $logLines = Get-Content $logPath -Tail 50 -ErrorAction SilentlyContinue
        Log-Output "--- LAST 15 LOG ENTRIES ---" -Color Gray
        $logLines | Select-Object -Last 15 | ForEach-Object {
            Log-Output "   [LOG] $_" -Color Gray
        }

        # Check for specific error signatures in log
        $logText = $logLines -join "`n"
        if ($logText -match "TLS|Handshake|SSL") {
            Log-Output "Ocean log contains TLS / SSL Handshake entries." -Status "WARN"
        }
        if ($logText -match "PIN|Connect|Failed|Error") {
            Log-Output "Ocean log contains PIN / Server Connection failures." -Status "WARN"
        }
    }
}

if (-not $foundLog) {
    Log-Output "No local ocean.log found at standard paths ($env:USERPROFILE\.oceancache\)." -Status "INFO"
}

# -----------------------------------------------------------------------------
# PHASE 5: FINAL VERDICT & SUMMARY REPORT
# -----------------------------------------------------------------------------
Write-Host "`n===============================================================================" -ForegroundColor Cyan
Write-Host "                         FINAL VERDICT & SUMMARY REPORT                        " -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan

if ($Repairs.Count -gt 0) {
    Write-Host "`n[+] AUTOMATED REPAIRS EXECUTED ($($Repairs.Count)):" -ForegroundColor Green
    foreach ($rep in $Repairs) {
        Write-Host "  - $rep" -ForegroundColor Green
    }
}

if ($Detections.Count -gt 0) {
    Write-Host "`n[!] CRITICAL UNSOLVED BLOCKERS ($($Detections.Count)):" -ForegroundColor Red
    foreach ($det in $Detections) {
        Write-Host "  - $det" -ForegroundColor Red
    }
}

if ($Warnings.Count -gt 0) {
    Write-Host "`n[?] WARNINGS / COMPATIBILITY NOTICES ($($Warnings.Count)):" -ForegroundColor Yellow
    foreach ($warn in $Warnings) {
        Write-Host "  - $warn" -ForegroundColor Yellow
    }
}

Write-Host "`n-------------------------------------------------------------------------------" -ForegroundColor Gray
if ($handshakeSuccess -and $Detections.Count -eq 0) {
    Log-Output "OVERALL VERDICT: SYSTEM IS READY. Ocean AC connection simulation PASSED." -Status "PASS"
} else {
    Log-Output "OVERALL VERDICT: OCEAN AC CONNECTION ISSUE CONFIRMED." -Status "CRITICAL"
    if (-not $handshakeSuccess) {
        Log-Output "TLS Handshake to Ocean servers failed. If TLS crash persists, install Cloudflare 1.1.1.1 / WARP DNS." -Color Yellow
    }
}
Write-Host "===============================================================================" -ForegroundColor Cyan

Log-Output "Full summary report saved locally to: $ReportFile" -Color Gray
Write-Host "`nAll logs saved to: $DebugFolder" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# Open the Ocean-Debug-Logs folder for the user
# -----------------------------------------------------------------------------
try {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$DebugFolder`""
} catch {
    Write-Host "[WARN] Could not auto-open the logs folder. You can find it here: $DebugFolder" -ForegroundColor Yellow
}

pause
