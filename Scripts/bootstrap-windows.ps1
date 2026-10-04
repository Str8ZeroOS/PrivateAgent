<#
.SYNOPSIS
Fetches PrivateAgent on Windows even when local Git/curl fail with schannel SEC_E_NO_CREDENTIALS.

.DESCRIPTION
Some managed Windows environments cannot use GitHub over Git because the Git/curl
schannel credential provider fails before TLS completes. This script avoids the Git
transport and downloads the repository archive through .NET HttpClient, then expands
it into a local checkout-like folder for build inspection.

This is not a replacement for Git when Git works. It is a development unblocker for
read/build/test scenarios.
#>

param(
    [string]$Owner = "Str8ZeroOS",
    [string]$Repo = "PrivateAgent",
    [string]$Ref = "main",
    [string]$Destination = ".\\PrivateAgent-main"
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$archiveUrl = "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Ref"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "PrivateAgentBootstrap"
$zipPath = Join-Path $tempRoot "$Repo-$Ref.zip"
$extractPath = Join-Path $tempRoot "extract"

if (Test-Path $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null

Write-Step "Downloading archive from $archiveUrl"
$handler = [System.Net.Http.HttpClientHandler]::new()
$client = [System.Net.Http.HttpClient]::new($handler)
$client.DefaultRequestHeaders.UserAgent.ParseAdd("PrivateAgent-Windows-Bootstrap/1.0")

try {
    $bytes = $client.GetByteArrayAsync($archiveUrl).GetAwaiter().GetResult()
    [IO.File]::WriteAllBytes($zipPath, $bytes)
} catch {
    Write-Error "Archive download failed. If this machine blocks all TLS to GitHub, run CI in GitHub Actions instead. Original error: $($_.Exception.Message)"
    exit 1
} finally {
    $client.Dispose()
    $handler.Dispose()
}

Write-Step "Expanding archive"
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
$expanded = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
if (-not $expanded) {
    Write-Error "Archive did not contain a source directory."
    exit 1
}

$resolvedDestination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
if (Test-Path $resolvedDestination) {
    Write-Step "Removing existing destination $resolvedDestination"
    Remove-Item -LiteralPath $resolvedDestination -Recurse -Force
}

Write-Step "Moving source to $resolvedDestination"
Move-Item -LiteralPath $expanded.FullName -Destination $resolvedDestination

Write-Step "Done"
Write-Host "Source is available at: $resolvedDestination"
Write-Host "Next: cd `"$resolvedDestination`"; swift build; swift test"
