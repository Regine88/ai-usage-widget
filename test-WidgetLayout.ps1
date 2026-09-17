# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetLayout.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetLayout.ps1')

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

Assert-Eq (ConvertTo-WidgetLayoutName 'FULL') 'full' 'layout full is case insensitive'
Assert-Eq (ConvertTo-WidgetLayoutName 'compact') 'compact' 'layout compact'
Assert-Eq (ConvertTo-WidgetLayoutName 'grid') 'full' 'unknown layout falls back'
Assert-Eq (ConvertTo-WidgetLayoutName $null) 'full' 'null layout falls back'
Assert-Eq (ConvertTo-WidgetLayoutScale 1.5) '1.5' 'scale passthrough'
Assert-Eq (ConvertTo-WidgetLayoutScale 0) '1' 'zero scale falls back'
Assert-Eq (ConvertTo-WidgetLayoutScale 99) '1' 'huge scale falls back'
Assert-Eq (ConvertTo-WidgetLayoutScale 'abc') '1' 'junk scale falls back'

$full = Get-WidgetLayoutMetrics -Scale 1 -Layout 'full' -ShowTrend $true
Assert-Eq $full.FormWidth 280 'full form width'
Assert-Eq $full.RowH 74 'full row height'
Assert-Eq $full.DetailH 16 'full keeps the detail line'
Assert-Eq ($full.BarTrackW -lt $full.ContentW) 'True' 'full trend shrinks the bar'
Assert-Eq $full.FontPct 16 'full percent font'

$fullNoTrend = Get-WidgetLayoutMetrics -Scale 1 -Layout 'full' -ShowTrend $false
Assert-Eq $fullNoTrend.BarTrackW $fullNoTrend.ContentW 'hiding the trend gives the bar the full width'

$compact = Get-WidgetLayoutMetrics -Scale 1 -Layout 'compact' -ShowTrend $true
Assert-Eq $compact.RowH 38 'compact row height'
Assert-Eq $compact.DetailH 0 'compact hides the detail line'
Assert-Eq ($compact.RowH -lt $full.RowH) 'True' 'compact is shorter than full'
Assert-Eq $compact.FontPct 11 'compact uses a smaller percent font'

$scaled = Get-WidgetLayoutMetrics -Scale 1.5 -Layout 'full' -ShowTrend $true
Assert-Eq $scaled.FormWidth 420 '1.5x form width'
Assert-Eq $scaled.RowH 111 '1.5x row height'

$fullH = Get-WidgetFormHeight -Metrics $full -RowCount 10
$compactH = Get-WidgetFormHeight -Metrics $compact -RowCount 10
Assert-Eq ($compactH -lt $fullH) 'True' 'ten compact rows are shorter than ten full rows'
Assert-Eq (Get-WidgetFormHeight -Metrics $full -RowCount 0) (Get-WidgetFormHeight -Metrics $full -RowCount 1) 'zero rows still reserve one row of height'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
