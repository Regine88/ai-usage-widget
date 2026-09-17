# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-UsageReport.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageReport.ps1')
. (Join-Path $here 'WidgetStrings.ps1')

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

function New-Record {
    param([string]$Day, [string]$Time, [string]$Id, [double]$Pct)
    return @{
        Ts  = [datetime]::ParseExact(($Day + ' ' + $Time), 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        Id  = $Id
        Pct = $Pct
    }
}

$records = @(
    (New-Record '2026-08-31' '23:00' 'grok' 5)
    (New-Record '2026-09-01' '08:00' 'grok' 10)
    (New-Record '2026-09-01' '20:00' 'grok' 14)
    (New-Record '2026-09-02' '09:00' 'grok' 20)
    (New-Record '2026-09-01' '10:00' 'kimi' 3)
    (New-Record '2026-10-01' '10:00' 'grok' 99)
)

# ---------- 月份容错 ----------
Assert-Eq (ConvertTo-UsageReportMonth '2026-09') '2026-09' 'valid month passes through'
$fixed = [datetime]'2026-09-17 10:00'
Assert-Eq (ConvertTo-UsageReportMonth '2026-9' $fixed) '2026-09' 'short month falls back to now'
Assert-Eq (ConvertTo-UsageReportMonth '' $fixed) '2026-09' 'empty month falls back to now'
Assert-Eq (ConvertTo-UsageReportMonth $null $fixed) '2026-09' 'null month falls back to now'
Assert-Eq ((Get-UsageReportMonthStart '2026-02') -eq [datetime]'2026-02-01') 'True' 'month start is the first day'
Assert-Eq (Test-UsageReportInMonth -Day ([datetime]'2026-09-30 23:59') -Month '2026-09') 'True' 'last day of month is inside'
Assert-Eq (Test-UsageReportInMonth -Day ([datetime]'2026-10-01 00:00') -Month '2026-09') 'False' 'next month is outside'

# ---------- 按天汇总 ----------
$rollup = @(Get-UsageHistoryDailyRollup -Records $records -Month '2026-09')
Assert-Eq $rollup.Count 3 'rollup keeps one row per day and provider'
Assert-Eq $rollup[0].DayKey '2026-09-01' 'first row is the earliest day'
Assert-Eq $rollup[0].Id 'grok' 'rows inside a day are sorted by provider'
Assert-Eq $rollup[1].Id 'kimi' 'second provider on the same day follows'
Assert-Eq $rollup[2].DayKey '2026-09-02' 'later day comes last'
Assert-Eq $rollup[0].Samples 2 'samples count per day'
Assert-Eq $rollup[0].First 10 'first sample of the day'
Assert-Eq $rollup[0].Last 14 'last sample of the day'
Assert-Eq $rollup[0].Min 10 'min of the day'
Assert-Eq $rollup[0].Max 14 'max of the day'
Assert-Eq $rollup[0].Delta 4 'delta of the day'
Assert-Eq (Get-UsageReportNumber $rollup[0].Average) '12' 'average of the day'
Assert-Eq (@(Get-UsageHistoryDailyRollup -Records $records -Month '2026-09' -Id 'kimi').Count) 1 'provider filter keeps one row'
Assert-Eq (@(Get-UsageHistoryDailyRollup -Records $records -Month '2026-08').Count) 1 'august only holds the august sample'
Assert-Eq (@(Get-UsageHistoryDailyRollup -Records @() -Month '2026-09').Count) 0 'no records gives no rows'

# ---------- 月度汇总 ----------
$summary = @(Get-UsageHistoryMonthlySummary -Records $records -Month '2026-09')
Assert-Eq $summary.Count 2 'summary has one row per provider'
Assert-Eq $summary[0].Id 'grok' 'providers are sorted'
Assert-Eq $summary[0].Samples 3 'monthly sample count'
Assert-Eq $summary[0].Days 2 'monthly day count'
Assert-Eq $summary[0].First 10 'month first sample'
Assert-Eq $summary[0].Last 20 'month last sample'
Assert-Eq $summary[0].Min 10 'month min'
Assert-Eq $summary[0].Max 20 'month max'
Assert-Eq $summary[0].Delta 10 'month delta'
Assert-Eq (Get-UsageReportNumber $summary[0].SlopePerDay) '6' 'slope uses the daily last samples'
Assert-Eq $summary[0].PeakDay '2026-09-02' 'peak day is the highest daily last sample'
Assert-Eq $summary[1].Id 'kimi' 'second provider summary'
Assert-Eq ($null -eq $summary[1].SlopePerDay) 'True' 'a single day has no slope'
Assert-Eq (Get-UsageReportNumber $summary[0].Average) '14.67' 'monthly average is sample weighted'

# ---------- 月份清单 ----------
$months = @(Get-UsageHistoryMonths $records)
Assert-Eq ($months -join ',') '2026-10,2026-09,2026-08' 'months are unique and newest first'
Assert-Eq ((@(Get-UsageHistoryMonths $records 2)) -join ',') '2026-10,2026-09' 'month limit keeps the newest'
Assert-Eq (@(Get-UsageHistoryMonths @()).Count) 0 'no records gives no months'

# ---------- CSV ----------
$csv = ConvertTo-UsageReportCsv $rollup
$csvLines = @($csv -split "`r`n" | Where-Object { $_ })
Assert-Eq $csvLines[0] 'day,provider,samples,first,last,min,max,delta' 'csv header'
Assert-Eq $csvLines[1] '2026-09-01,grok,2,10,14,10,14,4' 'csv first data row'
Assert-Eq $csv.Contains("`r`n") 'True' 'csv uses CRLF for Excel'
$quoted = ConvertTo-UsageReportCsv @(@{ DayKey = '2026-09-01'; Id = 'we,ird'; Samples = 1; First = 1; Last = 1; Min = 1; Max = 1; Delta = 0 })
Assert-Eq (@($quoted -split "`r`n")[1]) '2026-09-01,"we,ird",1,1,1,1,1,0' 'csv escapes separators'
Assert-Eq ((ConvertTo-UsageReportCsv @()) -split "`r`n")[0] 'day,provider,samples,first,last,min,max,delta' 'empty rollup still has a header'

# ---------- Markdown ----------
$md = ConvertTo-UsageReportMarkdown -Summary $summary -Rollup $rollup -Month '2026-09' -GeneratedAt $fixed
Assert-Eq $md.Contains('# AI usage report · 2026-09') 'True' 'markdown title carries the month'
Assert-Eq $md.Contains('| Provider | Samples | Days | First | Last | Min | Max | Change | Slope |') 'True' 'markdown summary header'
Assert-Eq $md.Contains('| grok | 3 | 2 | 10 | 20 | 10 | 20 | 10 | 6 %/day |') 'True' 'markdown summary row'
Assert-Eq $md.Contains('| 2026-09-01 | grok | 2 | 10 | 14 | 10 | 14 |') 'True' 'markdown daily row'
Assert-Eq $md.Contains('| kimi | 1 | 1 | 3 | 3 | 3 | 3 | 0 | - |') 'True' 'markdown shows a dash when there is no slope'
Assert-Eq $md.EndsWith("`n") 'True' 'markdown ends with a newline'
$pipe = ConvertTo-UsageReportMarkdown -Summary @(@{ Id = 'a|b'; Samples = 1; Days = 1; First = 1; Last = 2; Min = 1; Max = 2; Delta = 1; SlopePerDay = $null }) -Rollup @() -Month '2026-09'
Assert-Eq $pipe.Contains('a\|b') 'True' 'markdown escapes pipes'
Assert-Eq (ConvertTo-UsageReportMarkdown -Summary @() -Rollup @() -Month '2026-09').Contains('No history samples for this month') 'True' 'markdown explains an empty month'

# ---------- HTML ----------
$html = ConvertTo-UsageReportHtml -Summary $summary -Rollup $rollup -Month '2026-09' -GeneratedAt $fixed
Assert-Eq $html.StartsWith('<!DOCTYPE html>') 'True' 'html starts with the doctype'
Assert-Eq $html.Contains('<meta charset="utf-8">') 'True' 'html declares utf-8'
Assert-Eq $html.Contains('grok') 'True' 'html carries the provider rows'
Assert-Eq ($html -match 'https?://') 'False' 'html is self contained'
Assert-Eq $html.Contains('<style>') 'True' 'html inlines its stylesheet'
$escaped = ConvertTo-UsageReportHtml -Summary @(@{ Id = '<script>x</script>'; Samples = 1; Days = 1; First = 1; Last = 1; Min = 1; Max = 1; Delta = 0; SlopePerDay = $null }) -Rollup @() -Month '2026-09'
Assert-Eq $escaped.Contains('<script>') 'False' 'html escapes markup from the data'
Assert-Eq $escaped.Contains('&lt;script&gt;') 'True' 'html keeps the escaped text visible'

# ---------- 文件名 ----------
Assert-Eq (Get-UsageReportFileName -Month '2026-09' -Extension 'html') 'ai-usage-report-2026-09.html' 'report file name'
Assert-Eq (Get-UsageReportFileName -Month '2026-09') 'ai-usage-report-2026-09.csv' 'csv is the default extension'
Assert-Eq (Get-UsageReportFileName -Month 'bad' -Extension 'md') ('ai-usage-report-' + [datetime]::Now.ToString('yyyy-MM') + '.md') 'bad month falls back to now'

# ---------- 与语言包联动 ----------
$script:WidgetStrings = @{ 'report.title' = 'REPORT-X'; 'report.colProvider' = 'P' }
$labels = Get-UsageReportLabels
Assert-Eq $labels.Title 'REPORT-X' 'labels come from the string table when one is loaded'
Assert-Eq $labels.Provider 'P' 'labels use the loaded table for every key'
$script:WidgetStrings = $null
Assert-Eq (Get-UsageReportLabels).Title 'AI usage report' 'labels fall back to the built in English table'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
