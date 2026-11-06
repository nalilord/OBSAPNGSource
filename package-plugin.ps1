param(
    [string]$DelphiRoot,
    [string]$OBSPluginRoot,
    [switch]$Tests
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$') { throw 'Invalid VERSION file.' }
$buildArgs = @{ Tests = $Tests }
if ($DelphiRoot) { $buildArgs.DelphiRoot = $DelphiRoot }
if ($OBSPluginRoot) { $buildArgs.OBSPluginRoot = $OBSPluginRoot }
& (Join-Path $root 'build.ps1') @buildArgs

$stage = Join-Path $root '.build\package'
$dist = Join-Path $root 'Dist'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$pluginDir = Join-Path $stage 'obs-plugins\64bit'
New-Item -ItemType Directory -Force -Path $pluginDir, $dist | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'Bin\Win64\OBSAPNGPlugin.dll') -Destination $pluginDir
foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.txt', 'VERSION')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage
}
@"
APNG Source for OBS Studio $version - Windows x64

1. Close OBS Studio.
2. Merge the obs-plugins folder into your OBS installation directory.
   The DLL belongs at obs-plugins/64bit/OBSAPNGPlugin.dll.
3. Start OBS and add the APNG Image source.
4. Choose an animated PNG file. Playback speed defaults to 100%.

Requires OBS 32.1.2 or newer in the 32.x or 33.x series.
Tested with OBS 32.2.2 and 33.0.1 / Direct3D 11.
To update, close OBS before replacing the DLL.
To uninstall, close OBS and remove OBSAPNGPlugin.dll.

Source and build instructions: the source archive for this release.
License: GNU GPL v2. See LICENSE and THIRD_PARTY_NOTICES.txt.
"@ | Set-Content -LiteralPath (Join-Path $stage 'INSTALL.txt') -Encoding UTF8
$zip = Join-Path $dist "OBSAPNGSource-$version-windows-x64.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
"$hash  $([System.IO.Path]::GetFileName($zip))" |
    Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
Write-Output "Packaged: $zip"
