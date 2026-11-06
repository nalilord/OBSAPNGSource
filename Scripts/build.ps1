param(
    [string]$DelphiRoot,
    [string]$OBSPluginRoot,
    [switch]$Tests,
    [switch]$RenderProbe,
    [switch]$Package
)
$ErrorActionPreference = 'Stop'
if (-not $DelphiRoot) {
    $studioRoot = Join-Path ${env:ProgramFiles(x86)} 'Embarcadero\Studio'
    $DelphiRoot = Get-ChildItem -LiteralPath $studioRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\dcc64.exe') } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $DelphiRoot) { throw 'Delphi Win64 compiler not found; pass -DelphiRoot.' }
$compiler = Join-Path $DelphiRoot 'bin\dcc64.exe'
$rtl = Join-Path $DelphiRoot 'lib\win64\release'
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($Package) {
    $version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$') { throw 'Invalid VERSION file.' }
}
$outputDir = Join-Path $projectRoot 'Bin\Win64'
$unitDir = Join-Path $projectRoot '.build\Win64'
New-Item -ItemType Directory -Force -Path $outputDir, $unitDir | Out-Null
if (-not $OBSPluginRoot) { $OBSPluginRoot = Join-Path (Split-Path $projectRoot -Parent) 'OBSPlugin' }
$bindings = Join-Path $OBSPluginRoot 'Source'
if (-not (Test-Path -LiteralPath (Join-Path $bindings 'XENOME.OBS.Compatibility.pas'))) {
    throw 'DelphiOBS v0.2.0 bindings not found. Clone nalilord/DelphiOBS to ../OBSPlugin or pass -OBSPluginRoot.'
}
$paths = "$projectRoot\Source;$bindings;$rtl"
$compilerArgs = @('-B', '-Q', "-U$paths", "-I$paths", "-N0$unitDir", "-E$outputDir")
& $compiler @compilerArgs (Join-Path $projectRoot 'Source\OBSAPNGPlugin.dpr')
if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed.' }
if ($Tests) {
    & $compiler @compilerArgs (Join-Path $projectRoot 'Tests\DecodeProbe.dpr')
    if ($LASTEXITCODE -ne 0) { throw 'Decoder probe build failed.' }
    & node (Join-Path $projectRoot 'Tests\test-decoder.cjs') (Join-Path $outputDir 'DecodeProbe.exe') (Join-Path $unitDir 'fixtures')
    if ($LASTEXITCODE -ne 0) { throw 'Decoder tests failed.' }
    & $compiler @compilerArgs (Join-Path $projectRoot 'Tests\DecodeBenchmark.dpr')
    if ($LASTEXITCODE -ne 0) { throw 'Decoder benchmark build failed.' }
}
if ($RenderProbe) {
    & $compiler @compilerArgs (Join-Path $projectRoot 'Tests\OBSRenderProbe.dpr')
    if ($LASTEXITCODE -ne 0) { throw 'OBS render probe build failed.' }
}
Write-Output "Built: $outputDir\OBSAPNGPlugin.dll"

if ($Package) {
    $stage = Join-Path $projectRoot '.build\package'
    $dist = Join-Path $projectRoot 'Dist'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    $pluginDir = Join-Path $stage 'obs-plugins\64bit'
    New-Item -ItemType Directory -Force -Path $pluginDir, $dist | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Bin\Win64\OBSAPNGPlugin.dll') -Destination $pluginDir
    foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.txt', 'VERSION')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $stage
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
}
