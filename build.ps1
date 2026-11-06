param(
    [string]$DelphiRoot,
    [string]$OBSPluginRoot,
    [switch]$Tests,
    [switch]$RenderProbe
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
$projectRoot = $PSScriptRoot
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
& $compiler @compilerArgs (Join-Path $projectRoot 'OBSAPNGPlugin.dpr')
if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed.' }
if ($Tests) {
    & $compiler @compilerArgs (Join-Path $projectRoot 'Tests\DecodeProbe.dpr')
    if ($LASTEXITCODE -ne 0) { throw 'Decoder probe build failed.' }
    & node (Join-Path $projectRoot 'Tests\test-decoder.cjs') (Join-Path $outputDir 'DecodeProbe.exe') (Join-Path $unitDir 'fixtures')
    if ($LASTEXITCODE -ne 0) { throw 'Decoder tests failed.' }
}
if ($RenderProbe) {
    & $compiler @compilerArgs (Join-Path $projectRoot 'Tests\OBSRenderProbe.dpr')
    if ($LASTEXITCODE -ne 0) { throw 'OBS render probe build failed.' }
}
Write-Output "Built: $outputDir\OBSAPNGPlugin.dll"
