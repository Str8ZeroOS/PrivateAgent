<#
.SYNOPSIS
Start the Str8ZeRO bridge on a Windows PC so the iPhone app can pair with it.

.DESCRIPTION
Runs Bridge\mac_bridge_helper.py on 0.0.0.0:8765. On Windows the bridge
answers health checks, pairing and openURL (in the default browser); the
Mac-only actions (iPhone Mirroring, Accessibility clicks/typing) report
themselves as unavailable.

The bridge prints a 6-digit one-time pairing code. In Str8ZeRO open
Agent Mode > Mac Bridge, set Host to this PC's IP and Port 8765, tap
Check Bridge, type the code and tap Pair. The app stores the issued token in
the iOS Keychain; this PC only keeps a SHA-256 hash of it.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File Scripts\start-bridge-windows.ps1
#>

param(
    [int]$Port = 8765,
    [switch]$ForgetDevices
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $root "Bridge\mac_bridge_helper.py"

$python = $null
foreach ($candidate in @("py", "python", "python3")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $python = $candidate; break }
}
if (-not $python) {
    Write-Error "Python 3 is not installed. Install it from https://www.python.org/downloads/ (tick 'Add python.exe to PATH') and run this again."
    exit 1
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object -First 1 -ExpandProperty IPAddress)

$ruleName = "Str8ZeRO Bridge $Port"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    if ($isAdmin) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private | Out-Null
        Write-Host "Opened Windows Firewall for TCP $Port (Private networks)."
    } else {
        Write-Host "If the iPhone shows 'Unreachable', allow the port once from an Administrator PowerShell:" -ForegroundColor Yellow
        Write-Host "  New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private" -ForegroundColor Yellow
        Write-Host "  (or click 'Allow access' on Private networks when Windows asks)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "On the iPhone: Str8ZeRO > Agent Mode > Mac Bridge > Host $ip  Port $Port" -ForegroundColor Cyan
Write-Host "Tap Check Bridge, enter the pairing code shown below, tap Pair. Ctrl+C stops the bridge." -ForegroundColor Cyan
Write-Host ""

$arguments = @()
if ($python -eq "py") { $arguments += "-3" }
$arguments += @($helper, "--host", "0.0.0.0", "--port", "$Port")
if ($ip) { $arguments += @("--advertise-host", $ip) }
if ($ForgetDevices) { $arguments += "--forget-devices" }

& $python @arguments
