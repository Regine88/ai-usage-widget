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

$v2 = ConvertTo-UsageHistoryRecord '{"schemaVersion":2,"ts":"2026-09-17T10:58:58+08:00","id":"codex-acct-a","provider":"codex","accountId":"account-a","metricType":"percent","window":"5h","cycle":"2026-09-17T15:00:00Z","resetAt":"2026-09-17T15:00:00Z","value":42.5,"unit":"percent","pct":42.5,"sampleState":"scheduled"}'
Assert-Eq $v2.SchemaVersion 2 'v2 schema version'
Assert-Eq $v2.Provider 'codex' 'v2 provider'
Assert-Eq $v2.AccountId 'account-a' 'v2 account id'
Assert-Eq $v2.Window '5h' 'v2 window'
Assert-Eq $v2.SampleState 'scheduled' 'v2 sample state'
Assert-Eq $v2.Legacy 'False' 'v2 record is not legacy'
$balance = ConvertTo-UsageHistoryRecord '{"schemaVersion":2,"ts":"2026-09-17T10:58:58+08:00","id":"deepseek","provider":"deepseek","accountId":"account-a","metricType":"balance","value":14.5,"unit":"CNY","sampleState":"changed"}'
Assert-Eq $balance.MetricType 'balance' 'balance metric type'
Assert-Eq $balance.Pct '' 'balance does not fake a percent'
Assert-Eq $balance.Value 14.5 'balance keeps its numeric value'

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
    Assert-Eq (@(Read-UsageHistory -Path $historyPath -Limit 2)[0].Pct) 20 'limit returns the newest records in chronological order'

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
    $shortSeries = Get-UsageForecast @(
        @{ Day = [datetime]'2026-09-11'; Pct = 10.0 },
        @{ Day = [datetime]'2026-09-12'; Pct = 20.0 }
    ) 20.0 $null $now
    Assert-Eq $shortSeries.EtaHours '' 'two samples are not enough for a forecast'

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
    Assert-Eq $csvLines[0] 'time,id,provider,accountId,metricType,window,cycle,resetAt,value,unit,used,limit,sampleState,percent' 'csv header'
    Assert-Eq ($csvLines[1] -like '2026-09-11 23:00:00,commandcode,*12') 'True' 'csv first row'
    Assert-Eq ($csvLines[2] -like '2026-09-12 09:00:00,"weird,id",*20.5') 'True' 'csv escapes commas'
    Assert-Eq (ConvertTo-UsageHistoryCsv @()).Trim() 'time,id,provider,accountId,metricType,window,cycle,resetAt,value,unit,used,limit,sampleState,percent' 'csv with no records still has a header'

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

    # ---------- schema v2 monthly storage ----------
    $storageRoot = Join-Path $dir 'storage'
    New-Item -ItemType Directory -Path $storageRoot | Out-Null
    $storagePath = Join-Path $storageRoot 'ai-history.jsonl'
    foreach ($month in @(1, 2, 3, 4)) {
        foreach ($account in 1..20) {
            [void](Write-UsageHistoryRecord -Path $storagePath -Id ('acct-{0:d2}' -f $account) `
                -Provider 'codex' -AccountId ('account-{0:d2}' -f $account) -MetricType 'percent' `
                -Percent (10 + $month + $account / 100.0) -Value (10 + $month + $account / 100.0) -Unit 'percent' `
                -Timestamp ([datetime]::new(2026, $month, 15, 12, 0, 0)) -SampleState 'scheduled' `
                -RetentionDays 3650 -MaxBytes 104857600)
        }
    }
    $stored = @(Read-UsageHistory -Path $storagePath)
    Assert-Eq $stored.Count 80 'four months and twenty accounts remain readable'
    $storedMonths = @($stored | ForEach-Object { $_.Ts.ToString('yyyy-MM') } | Sort-Object -Unique)
    Assert-Eq ($storedMonths -join ',') '2026-01,2026-02,2026-03,2026-04' 'monthly archives cover every month'
    Assert-Eq (Get-UsageHistoryInventory -Path $storagePath).FileCount 4 'one archive file per month'

    # Legacy rows are copied into monthly archives without deleting the original, and repeated migration deduplicates.
    $legacyPath = Join-Path $storageRoot 'legacy-history.jsonl'
    [IO.File]::WriteAllText($legacyPath, (@(
        '{"ts":"2026-01-01T01:00:00Z","id":"legacy-a","pct":10}'
        '{"ts":"2026-02-01T01:00:00Z","id":"legacy-a","pct":20}'
    ) -join "`n"), [Text.UTF8Encoding]::new($false))
    Assert-Eq (Import-UsageHistoryLegacy -Path $legacyPath) 2 'legacy migration copies both records'
    Assert-Eq (Import-UsageHistoryLegacy -Path $legacyPath) 0 'legacy migration is repeatable without duplicates'
    Assert-Eq (@(Read-UsageHistory -Path $legacyPath).Count) 2 'legacy migration preserves the original source and avoids duplicates'

    # Retention deletes only archives older than the requested window.
    [void](Write-UsageHistoryRecord -Path $storagePath -Id 'current' -Provider 'codex' -AccountId 'current' -MetricType 'percent' -Percent 1 -Value 1 -Unit 'percent' -Timestamp ([datetime]'2026-04-15T12:00:00') -RetentionDays 3650 -MaxBytes 104857600)
    $retention = Invoke-UsageHistoryRetention -Path $storagePath -RetentionDays 30 -MaxBytes 104857600 -Now ([datetime]'2026-04-30T12:00:00')
    Assert-Eq ($retention.Removed -contains 'ai-history-2026-01.jsonl') 'True' 'retention removes the oldest archive'
    Assert-Eq ($retention.Removed -contains 'ai-history-2026-03.jsonl') 'False' 'retention keeps archives inside the window'

    # The old 2000-line / 1MB truncation is gone: every valid line in an archive remains readable.
    $largeRoot = Join-Path $storageRoot 'large'
    New-Item -ItemType Directory -Path $largeRoot -Force | Out-Null
    $largePath = Join-Path $largeRoot 'ai-history.jsonl'
    $largeArchive = Get-UsageHistoryArchivePath -Path $largePath -Timestamp ([datetime]'2026-05-01')
    New-Item -ItemType Directory -Path (Split-Path -Parent $largeArchive) -Force | Out-Null
    $largeLines = New-Object System.Collections.Generic.List[string]
    foreach ($i in 1..2500) {
        $line = [ordered]@{ schemaVersion = 2; ts = ([datetime]'2026-05-01').AddMinutes($i).ToString('o'); id = 'bulk'; provider = 'codex'; accountId = 'a'; metricType = 'percent'; value = ($i % 100); unit = 'percent'; pct = ($i % 100); sampleState = 'changed' } | ConvertTo-Json -Compress
        [void]$largeLines.Add($line)
    }
    [IO.File]::WriteAllLines($largeArchive, $largeLines, [Text.UTF8Encoding]::new($false))
    Assert-Eq (@(Read-UsageHistory -Path $largePath).Count) 2500 'more than 2000 archive rows are retained'
    $capacity = Invoke-UsageHistoryRetention -Path $largePath -RetentionDays 3650 -MaxBytes 1 -Now ([datetime]'2026-05-30')
    Assert-Eq $capacity.Incomplete 'True' 'capacity pressure marks history as incomplete when the current month cannot be trimmed'
    Assert-Eq (Test-Path -LiteralPath $largeArchive) 'True' 'capacity retention never deletes the current month'

    $bulkRoot = Join-Path $storageRoot 'bulk'
    New-Item -ItemType Directory -Path $bulkRoot -Force | Out-Null
    $bulkPath = Join-Path $bulkRoot 'ai-history.jsonl'
    $bulkLines = New-Object System.Collections.Generic.List[string]
    $bulkBase = [datetime]'2026-01-01'
    foreach ($day in 0..119) {
        foreach ($account in 0..19) {
            foreach ($sample in 0..9) {
                [void]$bulkLines.Add(('{{"ts":"{0}","id":"acct-{1:d2}","pct":{2}}}' -f $bulkBase.AddDays($day).AddHours($sample).ToString('o'), $account, (40 + ($day % 20))))
            }
        }
    }
    [IO.File]::WriteAllLines($bulkPath, $bulkLines, [Text.UTF8Encoding]::new($false))
    Assert-Eq (Import-UsageHistoryLegacy -Path $bulkPath) 24000 'a 24000-row legacy history migrates completely'
    [void](Write-UsageHistoryRecord -Path $bulkPath -Id 'acct-00' -Provider 'codex' -AccountId 'account-00' -MetricType 'percent' -Percent 61 -Value 61 -Unit 'percent' -Timestamp ([datetime]'2026-05-01') -RetentionDays 3650 -MaxBytes 104857600)
    Assert-Eq (@(Read-UsageHistory -Path $bulkPath).Count) 24001 'migration plus new sampling preserves the full synthetic history'
    Assert-Eq (@(Get-Content -LiteralPath $bulkPath).Count) 24000 'legacy migration keeps the original source file intact'

    # Balance and unlimited samples stay out of percentage series.
    $mixed = @(
        @{ Ts = [datetime]'2026-06-01T10:00:00'; Id = 'deepseek'; Pct = $null; MetricType = 'balance'; Value = 20.0; SchemaVersion = 2; Legacy = $false }
        @{ Ts = [datetime]'2026-06-01T11:00:00'; Id = 'openrouter'; Pct = 0.0; MetricType = 'unlimited'; Value = 12.0; SchemaVersion = 2; Legacy = $false }
        @{ Ts = [datetime]'2026-06-01T12:00:00'; Id = 'codex'; Pct = 30.0; MetricType = 'percent'; Value = 30.0; SchemaVersion = 2; Legacy = $false }
    )
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $mixed -Id 'deepseek' -Days 7 -Now ([datetime]'2026-06-02')).Count) 0 'balance is not plotted as percent'
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $mixed -Id 'openrouter' -Days 7 -Now ([datetime]'2026-06-02')).Count) 0 'unlimited is not plotted as percent'
    Assert-Eq (@(Get-UsageHistoryDaySeries -Records $mixed -Id 'codex' -Days 7 -Now ([datetime]'2026-06-02')).Count) 1 'percent remains plot data'

    # Reset-at filtering prevents a forecast from mixing two quota cycles.
    $cycles = @(
        @{ Ts = [datetime]'2026-06-01T10:00:00'; Id = 'codex'; Pct = 10.0; MetricType = 'percent'; ResetAt = 'r1'; SchemaVersion = 2; Legacy = $false }
        @{ Ts = [datetime]'2026-06-01T11:00:00'; Id = 'codex'; Pct = 20.0; MetricType = 'percent'; ResetAt = 'r2'; SchemaVersion = 2; Legacy = $false }
    )
    $cycleSeries = @(Get-UsageHistorySampleSeries -Records $cycles -Id 'codex' -Since ([datetime]'2026-06-01') -ResetAt 'r2')
    Assert-Eq $cycleSeries.Count 1 'forecast samples stay inside one reset cycle'
    Assert-Eq $cycleSeries[0].Pct 20 'the current cycle keeps its own value'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
