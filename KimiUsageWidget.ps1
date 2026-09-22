# Compatibility entry point. The combined widget is the single implementation.
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AddAccount,
    [switch]$MigrateSecrets,
    [int]$IntervalSeconds = 300
)

$target = Join-Path $PSScriptRoot 'AiUsageWidget.ps1'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "主 Widget 不存在: $target" }
$forward = @()
if ($Install) { $forward += '-Install' }
if ($Uninstall) { $forward += '-Uninstall' }
if ($AddAccount) { $forward += '-AddKimiAccount' }
if ($MigrateSecrets) { $forward += '-MigrateSecrets' }
if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $forward += @('-IntervalSeconds', [string]$IntervalSeconds) }
& $target @forward
exit $LASTEXITCODE
