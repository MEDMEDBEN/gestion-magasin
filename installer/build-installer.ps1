# Fabrique l'installateur Windows : ShinoLighting-Setup-<version>.exe
#   powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
# Prérequis sur le PC qui FABRIQUE (pas sur ceux qui installent) :
#   Flutter (C:\flutter), Visual Studio Build Tools + ATL, Inno Setup 6.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'app'

# 1. Version : celle de pubspec.yaml (1.0.0+1 -> 1.0.0).
$version = (Select-String -Path "$app\pubspec.yaml" -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
Write-Host "Version $version"

# 2. Application, branchée sur le serveur de production.
Push-Location $app
flutter build windows --release --dart-define-from-file=config/prod.json
if ($LASTEXITCODE -ne 0) { throw 'Build Flutter en échec' }
Pop-Location

# 3. Runtime Visual C++ 2015-2022 x64 (lien officiel Microsoft, une fois).
$redist = Join-Path $PSScriptRoot 'redist\vc_redist.x64.exe'
if (-not (Test-Path $redist)) {
  New-Item -ItemType Directory -Force (Split-Path $redist) | Out-Null
  Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redist
}

# 4. Installateur.
$iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 introuvable : https://jrsoftware.org/isdl.php' }
& $iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'gestion_magasin.iss')
if ($LASTEXITCODE -ne 0) { throw 'Compilation Inno Setup en échec' }
Write-Host "OK : $PSScriptRoot\Output\ShinoLighting-Setup-$version.exe"
