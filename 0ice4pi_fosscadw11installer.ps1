#install_foss_cad.ps1
# Set TLS 1.2 for GitHub API compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallDir = "$env:USERPROFILE\oss-cad-suite"
$TempArchive = "$env:TEMP\oss-cad-suite.tgz"

Write-Host "==> Querying latest YosysHQ OSS CAD Suite release..." -ForegroundColor Cyan

try {
    $ReleaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest"
    $Asset = $ReleaseInfo.assets \vert{} Where-Object {$_.name -like "oss-cad-suite-windows-x64-*.tgz" } | Select-Object -First 1

    if (-not $Asset) {
        throw "Could not find a Windows x64 build in the latest release assets."
    }

    $DownloadUrl =$Asset.browser_download_url
    Write-Host "Found release: $($Asset.name)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to fetch release information from GitHub API: $_"
    exit 1
}

# 1. Download Archive
Write-Host "==> Downloading OSS CAD Suite archive (this may take a minute)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $DownloadUrl -OutFile$TempArchive -UseBasicParsing

# 2. Prepare Directory
if (Test-Path $InstallDir) {
    Write-Host "==> Removing old installation at $InstallDir..." -ForegroundColor Yellow
    Remove-Item -Path $InstallDir -Recurse -Force
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# 3. Extract Archive using Windows built-in tar
Write-Host "==> Extracting archive to $InstallDir..." -ForegroundColor Cyan
tar -xzf $TempArchive -C$InstallDir --strip-components=1

if (Test-Path $TempArchive) {
    Remove-Item -Path $TempArchive -Force
}

# 4. Update User PATH
$BinDir = "$InstallDir\bin"
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

if ($UserPath -notlike "*$BinDir*") {
    Write-Host "==> Adding $BinDir to User PATH environment variable..." -ForegroundColor Cyan
    $NewPath = "$UserPath;$BinDir"
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    $env:Path = "$env:Path;$BinDir"
} else {
    Write-Host "==> $BinDir is already in User PATH." -ForegroundColor Green
}

# 5. Verify Installation
Write-Host "`n==> Verification:" -ForegroundColor Green
try {
    & "$BinDir\yosys.exe" -V
    & "$BinDir\nextpnr-ice40.exe" -V
    Write-Host "`nInstallation completed successfully!" -ForegroundColor Green
    Write-Host "Please restart your terminal/PowerShell window to use the toolchain globally." -ForegroundColor Yellow
}
catch {
    Write-Warning "Extraction finished, but tool verification encountered an issue."
}