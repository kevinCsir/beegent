param([string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $repo 'build-profile.json5'))) {
    Copy-Item -LiteralPath (Join-Path $repo 'build-profile.template.json5') -Destination (Join-Path $repo 'build-profile.json5')
}
$node = Join-Path $DevEco 'tools\node\node.exe'
$hvigor = Join-Path $DevEco 'tools\hvigor\hvigor\bin\hvigor.js'
$deps = Join-Path $env:LOCALAPPDATA 'JiuWenBridge\hvigor-deps\node_modules'
$scope = Join-Path $deps '@ohos'
New-Item -ItemType Directory -Force $scope | Out-Null
foreach ($package in @('hvigor','hvigor-ohos-plugin')) {
    $target = Join-Path $DevEco ('tools\hvigor\' + $package)
    $link = Join-Path $scope $package
    if (-not (Test-Path -LiteralPath $target)) { throw "Missing bundled tool: $target" }
    if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
    if ((Get-Item -LiteralPath $link).Target -ne $target) { throw "Tool link points elsewhere: $link" }
}
$env:NODE_PATH = $deps
$env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
$env:JAVA_HOME = Join-Path $DevEco 'jbr'
$env:Path = "$DevEco\tools\node;$DevEco\tools\ohpm\bin;$DevEco\jbr\bin;" + $env:Path
Push-Location $repo
try {
    & $node -e "require.resolve('@ohos/hvigor'); require.resolve('@ohos/hvigor-ohos-plugin'); console.log('HVIGOR_DEPS_OK')"
    if ($LASTEXITCODE -ne 0) { throw 'Hvigor dependencies unavailable' }
    & $node $hvigor --mode module -p module=entry@default -p product=default assembleHap --no-daemon
    $result = $LASTEXITCODE
} finally { Pop-Location }
exit $result
