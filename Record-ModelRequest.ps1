[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Provider,
    [Parameter(Mandatory)][string]$Model,
    [string]$AccountId,
    [string]$RequestId,
    [ValidateSet('started', 'completed', 'failed')][string]$Status = 'completed',
    [string]$Operation = 'chat',
    [string]$Source = 'external',
    [Nullable[double]]$DurationMs,
    [string]$ErrorMessage,
    [string]$Path,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ModelRequestRecorder.ps1')

$event = Write-ModelRequestEvent @PSBoundParameters
if ($event) {
    $event | ConvertTo-Json -Compress -Depth 4
} elseif ($Strict) {
    throw '请求事件写入失败'
}
