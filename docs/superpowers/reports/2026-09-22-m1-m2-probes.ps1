# Acceptance probes: synthetic data only, no network or real credentials.
# Prints observations rather than turning known acceptance gaps into CI failures.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'UsageValidation.ps1')
. (Join-Path $root 'SecureSnapshot.ps1')
. (Join-Path $root 'UsageHistory.ps1')
. (Join-Path $root 'ClineQuota.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'AiUsageWidget.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-KimiAccountId', 'Convert-KimiRawAuth', 'Set-KimiAuthFields', 'Save-KimiAuth', 'Update-ClineToken', 'Update-ClaudeToken', 'Write-UsageHistory')) {
    $fn = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $fn) { throw ('Missing function: ' + $name) }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('widget-acceptance-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    # Isolate snapshot persistence while exercising the real live-file writer.
    function Save-KimiSnapshot { param($Auth) return $Auth.Raw }
    function Write-WidgetLog { param($Message) }
    $script:KimiCredPath = Join-Path $scratch 'synthetic-kimi.json'
    $original = '{"user_id":"account-a","access_token":"old","refresh_token":"refresh-old","expires_at":2000000000}' | ConvertFrom-Json
    $pending = Convert-KimiRawAuth -Raw $original -Path $script:KimiCredPath -Source 'file'
    [IO.File]::WriteAllText($script:KimiCredPath, '{"user_id":"account-a","access_token":"newer-client-value","refresh_token":"newer-client-refresh","expires_at":2000000000,"keep":"yes"}')
    $pending.Token = 'late-worker-value'
    $pending.Refresh = 'late-worker-refresh'
    Save-KimiAuth $pending
    $after = Get-Content -LiteralPath $script:KimiCredPath -Raw | ConvertFrom-Json
    [pscustomobject]@{ Probe = 'M1_same_account_stale_write'; NewerCredentialPreserved = ($after.access_token -eq 'newer-client-value'); UnknownFieldPreserved = ($after.keep -eq 'yes') } | ConvertTo-Json -Compress

    # Network and disk failure are mocked; the refresh entry points are real.
    function Save-ClaudeAuth { param($Auth) throw 'synthetic-disk-write-failed' }
    function Save-ClineAuth { param($Auth) throw 'synthetic-disk-write-failed' }
    function Invoke-WidgetRest {
        param($Method, $Uri, $Body, $ContentType)
        return [pscustomobject]@{ access_token = 'synthetic-fresh'; refresh_token = 'synthetic-rotated'; expires_in = 3600; success = $true; data = [pscustomobject]@{ accessToken = 'synthetic-fresh'; refreshToken = 'synthetic-rotated'; expiresAt = 2000000000000 } }
    }
    foreach ($provider in @('Claude', 'Cline')) {
        $auth = [pscustomobject]@{ AccessToken = 'synthetic-old'; RefreshToken = 'synthetic-old-refresh'; ExpiresAt = [datetime]::UtcNow.AddHours(-1) }
        $propagated = $false
        try { $null = & ('Update-' + $provider + 'Token') $auth } catch { $propagated = $true }
        [pscustomobject]@{ Probe = ('M1_' + $provider + '_save_failure'); FailurePropagated = $propagated } | ConvertTo-Json -Compress
    }

    # Four months, 20 accounts, 10 daily observations: 24000 rows > 1 MB.
    $script:HistoryPath = Join-Path $scratch 'synthetic-history.jsonl'
    $script:DemoMode = $false
    $base = [datetime]::Today.AddDays(-119)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($day = 0; $day -lt 120; $day++) {
        for ($account = 0; $account -lt 20; $account++) {
            for ($sample = 0; $sample -lt 10; $sample++) {
                $line = '{"ts":"' + $base.AddDays($day).AddHours($sample).ToString('o') + '","id":"synthetic-account-' + $account + '","pct":50}'
                $lines.Add($line)
            }
        }
    }
    [IO.File]::WriteAllLines($script:HistoryPath, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    $beforeBytes = (Get-Item -LiteralPath $script:HistoryPath).Length
    Write-UsageHistory -Id 'synthetic-account-0' -Percent 51
    $remaining = @(Get-Content -LiteralPath $script:HistoryPath)
    [pscustomobject]@{ Probe = 'M2_retention'; BeforeRows = $lines.Count; BeforeBytes = $beforeBytes; AfterRows = $remaining.Count; FirstRemainingTimestamp = ($remaining[0] | ConvertFrom-Json).ts; AllRowsPreserved = ($remaining.Count -eq ($lines.Count + 1)) } | ConvertTo-Json -Compress

    $series = @(@{ Day = $base; Pct = 90 }, @{ Day = $base.AddDays(1); Pct = 95 }, @{ Day = $base.AddDays(2); Pct = 5 }, @{ Day = $base.AddDays(3); Pct = 15 })
    $forecast = Get-UsageForecast -Series $series -CurrentPercent 15 -Now $base.AddDays(3) -ResetAt $base.AddDays(8)
    [pscustomobject]@{ Probe = 'M2_cycle_forecast'; SlopePerDay = $forecast.SlopePerDay; CurrentCycleSlope = 10; EtaHours = $forecast.EtaHours } | ConvertTo-Json -Compress
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'widget-acceptance-*') { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
