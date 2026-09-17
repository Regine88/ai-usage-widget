# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-UsageHistory.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'UsageHistory.ps1')

$failed = 0
function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -ne "$Expected") {
        Write-Host ("FAIL {0}: expected [{1}] got [{2}]" -f $Name, $Expected, $Actual)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

# ---------- 行解析 ----------
$good = ConvertTo-UsageHistoryRecord '{"ts":"2026-09-17T10:58:58.4649505+08:00","id":"commandcode","pct":43.1}'
Assert-Eq $good.Id 'commandcode' 'record id'
Assert-Eq $good.Pct 43.1 'record percent'
# 时间戳带 +08:00 偏移：.Hour 的数值会随机器时区变化（CI runner 是 UTC），
# 所以断言绝对时刻而不是本地小时；Kind 在 PS5.1 与 PS7 上取值不同，不作断言。
Assert-Eq ([datetimeoffset]$good.Ts).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') '2026-09-17T02:58:58' 'record keeps the original instant'
Assert-Eq (ConvertTo-UsageHistoryRecord '{ not json') '' 'broken json ignored'
Assert-Eq (ConvertTo-UsageHistoryRecord '') '' 'empty line ignored'
Assert-Eq (ConvertTo-UsageHistoryRecord '{"id":"kimi","pct":10}') '' 'missing ts ignored'
Assert-Eq (ConvertTo-UsageHistoryRecord '{"ts":"2026-09-17T10:58:58+08:00","pct":10}') '' 'missing id ignored'
Assert-Eq (ConvertTo-UsageHistoryRecord '{"ts":"2026-09-17T10:58:58+08:00","id":"kimi","pct":"nope"}') '' 'non numeric percent ignored'
Assert-Eq (ConvertTo-UsageHistoryRecord '{"ts":"2026-09-17T10:58:58+08:00","id":"kimi","pct":"55.5"}').Pct 55.5 'numeric string percent accepted'

# ---------- 文件读取 ----------
Assert-Eq (@(Read-UsageHistory -Path (Join-Path $env:TEMP 'no-such-history.jsonl')).Count) 0 'missing history file gives empty list'

$dir = Join-Path $env:TEMP ('usage-history-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $historyPath = Join-Path $dir 'ai-history.jsonl'
    $lines = @(
        '{"ts":"2026-09-11T08:00:00+08:00","id":"commandcode","pct":10.0}',
        '{"ts":"2026-09-11T23:00:00+08:00","id":"commandcode","pct":12.0}',
        'not json at all',
        '{"ts":"2026-09-12T09:00:00+08:00","id":"commandcode","pct":20.0}',
        '{"ts":"2026-09-16T09:00:00+08:00","id":"kimi","pct":90.0}',
        '{"ts":"2026-09-01T09:00:00+08:00","id":"commandcode","pct":99.0}'
    )
    [IO.File]::WriteAllText($historyPath, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $records = @(Read-UsageHistory -Path $historyPath)
    Assert-Eq $records.Count 5 'reads every valid line and skips junk'
    Assert-Eq (@(Read-UsageHistory -Path $historyPath -Limit 2).Count) 2 'limit keeps the newest lines'
    Assert-Eq (@(Read-UsageHistory -Path $historyPath -Limit 2)[0].Pct) 90 'limit keeps file order'

    # ---------- 按天聚合 ----------
    $now = [datetime]'2026-09-17T12:00:00'
    $series = @(Get-UsageHistoryDaySeries -Records $records -Id 'commandcode' -Days 7 -Now $now)
    Assert-Eq $series.Count 2 'seven day window drops older samples'
    Assert-Eq $series[0].Pct 12 'day keeps its last sample'
    Assert-Eq $series[0].Day.ToString('yyyy-MM-dd') '2026-09-11' 'series is ascending'
    Assert-Eq $series[1].Pct 20 'second day value'

    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $records -Id 'nobody' -Now $now).Count) 0 'unknown id gives no series'
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $records -Id 'commandcode' -Days 2 -Now $now).Count) 0 'short window drops older days'
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $records -Id 'kimi' -Days 2 -Now $now).Count) 1 'short window keeps yesterday'

    $geminiSeries = @(
        @{ Ts = [datetime]'2026-09-16T09:00:00'; Id = 'gemini'; Pct = 70.0 }
    )
    $converted = @(Get-UsageHistoryDaySeries -Records $geminiSeries -Id 'gemini' -Kind 'gemini' -Now $now)
    Assert-Eq $converted[0].Pct 30 'gemini remaining converts to usage'
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $geminiSeries -Id 'gemini' -Now $now)[0].Pct) 70 'gemini stays raw without kind'

    # ---------- 斜率 ----------
    $rising = @(
        @{ Day = [datetime]'2026-09-11'; Pct = 12.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 20.0 },
        @{ Day = [datetime]'2026-09-13'; Pct = 28.0 }
    )
    Assert-Eq (Get-UsageTrendSlope $rising) 8 'linear slope per day'
    Assert-Eq (Get-UsageTrendSlope @($rising[0])) '' 'single point has no slope'
    Assert-Eq (Get-UsageTrendSlope @()) '' 'empty series has no slope'
    Assert-Eq (Get-UsageTrendSlope @(
        @{ Day = [datetime]'2026-09-11'; Pct = 40.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 30.0 }
    )) -10 'falling slope is negative'

    # ---------- 预测 ----------
    $forecast = Get-UsageForecast $rising 28.0 $null $now
    Assert-Eq $forecast.SlopePerDay 8 'forecast slope'
    Assert-Eq $forecast.EtaHours 216 'forecast eta in hours'
    Assert-Eq $forecast.ExhaustsBeforeReset 'False' 'no reset time means no early warning'
    Assert-Eq $forecast.ResetHours '' 'no reset time recorded'

    $resetIso = [datetimeoffset]$now.AddHours(480)
    $withReset = Get-UsageForecast $rising 28.0 $resetIso.ToString('o') $now
    Assert-Eq $withReset.ResetHours 480 'reset hours parsed from iso string'
    Assert-Eq $withReset.ExhaustsBeforeReset 'True' 'slow creep that still exhausts wins'

    $tightReset = Get-UsageForecast $rising 28.0 ($now.AddHours(48).ToString('o')) $now
    Assert-Eq $tightReset.ExhaustsBeforeReset 'False' 'reset arrives before exhaustion'

    $flat = Get-UsageForecast @(
        @{ Day = [datetime]'2026-09-11'; Pct = 40.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 40.05 }
    ) 40.05 ($now.AddHours(1).ToString('o')) $now
    Assert-Eq $flat.EtaHours '' 'flat series has no eta'
    Assert-Eq $flat.ExhaustsBeforeReset 'False' 'flat series never warns'

    $falling = Get-UsageForecast @(
        @{ Day = [datetime]'2026-09-11'; Pct = 60.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 50.0 }
    ) 50.0 ($now.AddHours(1).ToString('o')) $now
    Assert-Eq $falling.EtaHours '' 'falling series has no eta'

    $done = Get-UsageForecast $rising 100.0 ($now.AddHours(10).ToString('o')) $now
    Assert-Eq $done.EtaHours 0 'already exhausted forecast'
    Assert-Eq $done.ExhaustsBeforeReset 'True' 'exhausted warns before reset'

    $noTrend = Get-UsageForecast @() 50.0 ($now.AddHours(10).ToString('o')) $now
    Assert-Eq $noTrend.EtaHours '' 'no series gives no eta'
    Assert-Eq $noTrend.ExhaustsBeforeReset 'False' 'no series never warns'

    # ---------- 折线几何 ----------
    $path = @(New-SparklinePath $rising 60 20 2 8)
    Assert-Eq $path.Count 3 'one point per sample'
    Assert-Eq $path[0].X 2 'first point on the left pad'
    Assert-Eq $path[2].X 58 'last point on the right pad'
    Assert-Eq $path[0].Y 18 'lowest value sits at the bottom'
    Assert-Eq $path[2].Y 2 'highest value sits at the top'
    Assert-Eq $path[1].Y 10 'middle value in the middle'

    $single = @(New-SparklinePath @(@{ Day = [datetime]'2026-09-11'; Pct = 40.0 }) 60 20 2 8)
    Assert-Eq $single.Count 1 'single sample still yields a point'
    Assert-Eq $single[0].X 30 'single sample is centered'
    Assert-Eq $single[0].Y 10 'single sample is centered vertically'

    $flatPath = @(New-SparklinePath @(
        @{ Day = [datetime]'2026-09-11'; Pct = 40.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 40.4 }
    ) 60 20 2 8)
    Assert-Eq ([Math]::Abs($flatPath[0].Y - 10) -lt 1.0) 'True' 'tiny drift stays near the middle'
    Assert-Eq (@(New-SparklinePath @() 60 20).Count) 0 'empty series gives no path'
    Assert-Eq (@(New-SparklinePath $rising 0 20).Count) 0 'zero width gives no path'
    Assert-Eq (@(New-SparklinePath $rising 60 0).Count) 0 'zero height gives no path'

    # ---------- CSV ----------
    $csvRecords = @(
        @{ Ts = [datetime]'2026-09-11T23:00:00'; Id = 'commandcode'; Pct = 12.0 },
        @{ Ts = [datetime]'2026-09-12T09:00:00'; Id = 'weird,id'; Pct = 20.5 }
    )
    $csv = ConvertTo-UsageHistoryCsv $csvRecords
    $csvLines = @($csv -split "`r`n" | Where-Object { $_ })
    Assert-Eq $csvLines[0] 'time,id,percent' 'csv header'
    Assert-Eq $csvLines[1] '2026-09-11 23:00:00,commandcode,12' 'csv first row'
    Assert-Eq $csvLines[2] '2026-09-12 09:00:00,"weird,id",20.5' 'csv escapes commas'
    Assert-Eq (ConvertTo-UsageHistoryCsv @()).Trim() 'time,id,percent' 'csv with no records still has a header'

    $csvPath = Join-Path $dir 'export.csv'
    Assert-Eq (Export-UsageHistoryCsv -Path $csvPath -Records $csvRecords) 'True' 'export returns true'
    $bytes = [IO.File]::ReadAllBytes($csvPath)
    Assert-Eq ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'True' 'csv export has a BOM for Excel'
    $roundTrip = @(Get-Content -LiteralPath $csvPath)
    Assert-Eq $roundTrip.Count 3 'csv file line count'

    Assert-Eq (Export-UsageHistoryCsv -Path '' -Records $csvRecords) 'False' 'export without a path fails'

    $csvFromSource = Join-Path $dir 'export-source.csv'
    Export-UsageHistoryCsv -Path $csvFromSource -SourcePath $historyPath | Out-Null
    Assert-Eq (@(Get-Content -LiteralPath $csvFromSource).Count) 6 'export reads the source file when no records are given'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0