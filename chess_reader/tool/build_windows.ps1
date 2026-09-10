# Builds the Windows app and packages it into a distributable Setup.exe.
#
# Run on Windows with Flutter + Visual Studio (Desktop C++) + Inno Setup 6:
#   powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1
#
# Output: dist\chessbook-reader-setup-<version>.exe
#
# Notes:
# - The installer is unsigned (no code-signing cert needed). On first launch
#   SmartScreen may warn — "More info" -> "Run anyway".
# - Bundles Stockfish (fetched by fetch_stockfish.ps1 if missing) and the ONNX
#   square-classifier model, so analysis and diagram recognition work offline.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:').Line `
    -replace 'version:\s*', '' -split '\+')[0].Trim()
$release = "build\windows\x64\runner\Release"
$dist = "dist"

# Stockfish is bundled by the Windows build (windows/CMakeLists.txt); fetch the
# 110 MB binary once if it isn't present.
if (-not (Test-Path "assets\engines\stockfish-windows-x86-64.exe")) {
    Write-Host "Fetching Stockfish..."
    & (Join-Path $PSScriptRoot "fetch_stockfish.ps1")
}

Write-Host "Building ChessBook Reader $version for Windows..."
flutter build windows --release
if (-not (Test-Path "$release\chessbook_reader.exe")) {
    throw "build failed: $release\chessbook_reader.exe not found"
}

New-Item -ItemType Directory -Force $dist | Out-Null

$iscc = Get-ChildItem `
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", `
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe", `
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" `
    -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $iscc) { throw "ISCC.exe not found; install Inno Setup 6" }

& $iscc.FullName `
    "/DMyAppVersion=$version" `
    "/DSourceDir=$((Resolve-Path $release).Path)" `
    "/DOutputDir=$((Resolve-Path $dist).Path)" `
    "tool\installer.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

Write-Host "Created $dist\chessbook-reader-setup-$version.exe"
