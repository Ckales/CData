# Run after flutter build windows --release. Requires Visual Studio C++ tools and Inno Setup 6.5+.
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../dist')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$flutterDirectory = Split-Path $PSScriptRoot -Parent
$pubspec = Get-Content (Join-Path $flutterDirectory 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$') {
    throw 'Cannot read the application version from pubspec.yaml.'
}
$appVersion = $Matches[1]
if ($Version -and $Version -ne $appVersion) {
    throw "Requested version $Version does not match pubspec.yaml ($appVersion)."
}

$sourceDirectory = Join-Path $flutterDirectory 'build/windows/x64/runner/Release'
foreach ($file in @('CData.exe', 'flutter_windows.dll', 'cdata_rust.dll', 'data/icudtl.dat', 'data/app.so', 'data/flutter_assets')) {
    if (-not (Test-Path (Join-Path $sourceDirectory $file))) {
        throw "Missing build output: $file. Run flutter build windows --release first."
    }
}

# Ship the redistributable CRT beside the app so installation needs neither admin nor a runtime download.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) {
    throw 'Cannot locate Visual Studio C++ redistributables.'
}
$redistDirectory = Join-Path $visualStudio 'VC/Redist/MSVC'
$crtDirectories = @(Get-ChildItem "$redistDirectory/*/x64/Microsoft.VC*.CRT" -Directory |
    Where-Object { $_.Parent.Parent.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending)
if ($crtDirectories.Count -eq 0) {
    throw "No x64 Visual C++ CRT found in $redistDirectory."
}
Copy-Item (Join-Path $crtDirectories[0].FullName '*.dll') $sourceDirectory -Force
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path (Join-Path $sourceDirectory $dll))) {
        throw "Missing Visual C++ runtime: $dll."
    }
}

$compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($compiler) {
    $compilerPath = $compiler.Source
} else {
    $compilers = @(Get-ChildItem @("${env:ProgramFiles(x86)}/Inno Setup */ISCC.exe", "$env:ProgramFiles/Inno Setup */ISCC.exe") -ErrorAction SilentlyContinue)
    if ($compilers.Count -eq 0) {
        throw 'Inno Setup not found. Install it with: choco install innosetup --yes'
    }
    $compilerPath = $compilers[-1].FullName
}

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
& $compilerPath "/DAppVersion=$appVersion" "/DSourceDir=$sourceDirectory" "/DOutputDir=$OutputDirectory" (Join-Path $flutterDirectory 'windows/installer.iss')
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
$installer = Join-Path $OutputDirectory "CData-$appVersion-windows-x64-setup.exe"
if (-not (Test-Path $installer)) {
    throw "Installer not produced: $installer"
}
Write-Output "Installer: $installer"
