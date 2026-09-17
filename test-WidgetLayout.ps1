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

# 多列布局：1 列保持经典宽度；2-3 列变宽，并把行数折算成行带。
Assert-Eq (ConvertTo-WidgetLayoutColumns 1) '1' 'one column'
Assert-Eq (ConvertTo-WidgetLayoutColumns 2) '2' 'two columns'
Assert-Eq (ConvertTo-WidgetLayoutColumns 3) '3' 'three columns'
Assert-Eq (ConvertTo-WidgetLayoutColumns 0) '1' 'zero columns falls back'
Assert-Eq (ConvertTo-WidgetLayoutColumns 9) '1' 'too many columns falls back'
Assert-Eq (ConvertTo-WidgetLayoutColumns 'abc') '1' 'junk columns falls back'

$two = Get-WidgetLayoutMetrics -Scale 1 -Layout 'full' -ShowTrend $true -Columns 2
Assert-Eq $two.Columns 2 'two columns recorded'
Assert-Eq $two.ColumnStride 260 'two column stride'
Assert-Eq $two.FormWidth 540 'two column form width'
$one = Get-WidgetLayoutMetrics -Scale 1 -Layout 'full' -ShowTrend $true
Assert-Eq $one.FormWidth 280 'single column keeps the classic width'
$three = Get-WidgetLayoutMetrics -Scale 1 -Layout 'compact' -ShowTrend $true -Columns 3
Assert-Eq $three.FormWidth 800 'three compact columns add two gaps'

$anchor0 = Get-WidgetLayoutRowAnchor -Metrics $two -Index 0
$anchor1 = Get-WidgetLayoutRowAnchor -Metrics $two -Index 1
$anchor2 = Get-WidgetLayoutRowAnchor -Metrics $two -Index 2
Assert-Eq $anchor0.X 16 'first row starts at the left margin'
Assert-Eq $anchor0.Y 14 'first row starts at the top padding'
Assert-Eq $anchor1.X 276 'second row moves one column right'
Assert-Eq $anchor1.Y 14 'second row stays in the first band'
Assert-Eq $anchor2.X 16 'third row wraps back to the first column'
Assert-Eq $anchor2.Y 88 'third row starts the second band'

Assert-Eq (Get-WidgetFormHeight -Metrics $two -RowCount 10) (Get-WidgetFormHeight -Metrics $one -RowCount 5) 'two columns halve ten rows into five bands'
Assert-Eq (Get-WidgetFormHeight -Metrics $two -RowCount 11) (Get-WidgetFormHeight -Metrics $one -RowCount 6) 'odd row counts round up a band'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
