param(
    [Parameter(Mandatory = $true)][string]$OBSRoot,
    [string]$DelphiRoot,
    [string]$OBSPluginRoot
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$OBSRoot = (Resolve-Path -LiteralPath $OBSRoot).Path
$runtime = Join-Path $OBSRoot 'bin\64bit'
foreach ($name in @('obs.dll', 'libobs-d3d11.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtime $name))) { throw "OBS runtime is missing $name" }
}
$buildArgs = @{ RenderProbe = $true }
if ($DelphiRoot) { $buildArgs.DelphiRoot = $DelphiRoot }
if ($OBSPluginRoot) { $buildArgs.OBSPluginRoot = $OBSPluginRoot }
& (Join-Path $root 'build.ps1') @buildArgs
$version = (Get-Item -LiteralPath (Join-Path $runtime 'obs.dll')).VersionInfo.FileVersion
$output = Join-Path $root ('.build\render-tests\' + ($version -replace '[^A-Za-z0-9.-]', '_'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$fixture = Join-Path $output 'border.apng'
& node (Join-Path $PSScriptRoot 'render-fixture.cjs') generate $fixture
if ($LASTEXITCODE -ne 0) { throw 'Fixture generation failed.' }
$previousPath = $env:PATH
try {
    $env:PATH = "$runtime;" + $previousPath
    $effects = ($OBSRoot -replace '\\', '/') + '/data/libobs/'
    foreach ($speed in @(100, 50, 200)) {
        $capture = Join-Path $output "speed-$speed"
        $probeArgs = @((Join-Path $root 'Bin\Win64\OBSAPNGPlugin.dll'), $fixture,
            $effects, (Join-Path $runtime 'libobs-d3d11.dll'), $capture)
        if ($speed -ne 100) { $probeArgs += "$speed" }
        # The recovery check deliberately logs a missing-file error to stderr.
        $ErrorActionPreference = 'Continue'
        & (Join-Path $root 'Bin\Win64\OBSRenderProbe.exe') @probeArgs *> "$capture.log"
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { throw "OBS $version at $speed percent failed; see $capture.log" }
        Write-Output "PASS: OBS $version at $speed percent: rendering, Properties, recovery and shutdown"
    }
} finally {
    $env:PATH = $previousPath
    $ErrorActionPreference = 'Stop'
}
& node (Join-Path $PSScriptRoot 'render-fixture.cjs') verify $output
if ($LASTEXITCODE -ne 0) { throw 'Capture verification failed.' }
