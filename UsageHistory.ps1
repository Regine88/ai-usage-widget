# Usage history: turn ai-history.jsonl samples into a per-day series, a
# sparkline geometry and an exhaustion forecast. Everything except the file
# helpers is pure so the maths can be covered by an offline test.
#
# Sample format (written by Write-UsageHistory): {"ts":"ISO-8601","id":"...","pct":number}

# PowerShell 7.6 throws "Argument types do not match" for @($genericList), so
# normalize everything through one helper before treating it as a series.
# Callers wrap the result in @() so a single element cannot collapse into a
# scalar. PowerShell 7.6 also throws "Argument types do not match" for
# @($genericList), which is why the list is converted through a cast instead.
function ConvertTo-UsageHistoryArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    if ($Value -is [string]) { return $Value }
    try { return [object[]]$Value } catch { return $Value }
}

function ConvertTo-UsageHistoryRecord {
    param($Line)
    if ($null -eq $Line) { return $null }
    $text = ([string]$Line).Trim()
    if (-not $text) { return $null }
    try { $raw = $text | ConvertFrom-Json } catch { return $null }
    if ($null -eq $raw) { return $null }

    $id = $null
    try { if ($raw.id) { $id = [string]$raw.id } } catch { }
    if (-not $id) { return $null }

    $ts = $null
    try { if ($raw.ts) { $ts = Convert-ApiTime ([string]$raw.ts) } } catch { }
    if (-not $ts) { return $null }

    if (-not (Test-FiniteNumber $raw.pct)) { return $null }
    $pct = [double]$raw.pct

    return @{ Ts = [datetime]$ts; Id = $id; Pct = $pct }
}

function Read-UsageHistory {
    param([string]$Path, [int]$Limit = 0)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = @()
    try {
        if ($Limit -gt 0) { $lines = @(Get-Content -LiteralPath $Path -Tail $Limit -Encoding utf8) }
        else { $lines = @(Get-Content -LiteralPath $Path -Encoding utf8) }
    } catch { return @() }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $record = ConvertTo-UsageHistoryRecord $line
        if ($record) { [void]$records.Add($record) }
    }
    return (ConvertTo-UsageHistoryArray $records)
}

# One point per local day - the last sample of that day - so the sparkline
# shows where each day ended instead of every poll.
function Get-UsageHistoryDaySeries {
    param($Records, [string]$Id, [int]$Days = 7, [string]$Kind, [datetime]$Now = (Get-Date))
    if (-not $Id -or $Days -lt 1) { return @() }
    $firstDay = $Now.Date.AddDays(-($Days - 1))
    $lastDay = $Now.Date.AddDays(1)

    $byDay = @{}
    foreach ($record in @(ConvertTo-UsageHistoryArray $Records)) {
        if (-not $record) { continue }
        if ([string]$record.Id -ne $Id) { continue }
        $ts = $record.Ts
        if (-not ($ts -is [datetime])) { continue }
        if ($ts -lt $firstDay -or $ts -ge $lastDay) { continue }
        # File order is time order, so later samples overwrite earlier ones.
        $byDay[$ts.Date] = [double]$record.Pct
    }

    $series = @()
    foreach ($day in @($byDay.Keys | Sort-Object)) {
        $pct = [double]$byDay[$day]
        if ($Kind) {
            try { $pct = Convert-DisplayPercentToUsagePercent $pct $Kind } catch { continue }
        }
        $series += @{ Day = $day; Pct = $pct }
    }
    return $series
}

# Least-squares slope in percent per day. $null when there is nothing to fit
# (fewer than two days, or every sample on the same calendar day).
function Get-UsageTrendSlope {
    param($Series)
    $points = @(ConvertTo-UsageHistoryArray $Series)
    if ($points.Count -lt 2) { return $null }
    $base = $points[0].Day
    $n = 0.0; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
    foreach ($point in $points) {
        $x = ($point.Day - $base).TotalDays
        $y = [double]$point.Pct
        $n += 1.0; $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y
    }
    $denominator = $n * $sxx - $sx * $sx
    if ([Math]::Abs($denominator) -lt 1e-9) { return $null }
    return (($n * $sxy - $sx * $sy) / $denominator)
}

# Slope threshold below which the series is treated as flat: a usage counter
# that drifts by a fraction of a percent per day will never exhaust.
$script:UsageFlowFlatSlope = 0.1

function Get-UsageForecast {
    param($Series, [double]$CurrentPercent, $ResetAt, [datetime]$Now = (Get-Date))
    $remaining = [Math]::Max(0.0, 100.0 - [Math]::Max(0.0, [Math]::Min(100.0, $CurrentPercent)))
    $forecast = @{
        SlopePerDay         = $null
        EtaHours            = $null
        RemainingPercent    = $remaining
        ResetHours          = $null
        ExhaustsBeforeReset = $false
    }

    $slope = Get-UsageTrendSlope $Series
    if ($null -eq $slope) { return $forecast }
    $forecast.SlopePerDay = [double]$slope
    if ($slope -lt $script:UsageFlowFlatSlope) { return $forecast }

    $forecast.EtaHours = ($remaining / [double]$slope) * 24.0

    $reset = $null
    if ($ResetAt -is [datetime]) { $reset = [datetime]$ResetAt }
    elseif ($ResetAt) { try { $reset = Convert-ApiTime $ResetAt } catch { $reset = $null } }
    if ($reset) {
        # Unspecified timestamps are already local; converting them would shift by the UTC offset.
        $resetLocal = if ($reset.Kind -eq [DateTimeKind]::Utc) { $reset.ToLocalTime() } else { $reset }
        $hours = ($resetLocal - $Now).TotalHours
        $forecast.ResetHours = $hours
        if ($hours -gt 0 -and $forecast.EtaHours -lt $hours) { $forecast.ExhaustsBeforeReset = $true }
    }
    return $forecast
}

# Normalized sparkline geometry: x grows left to right, y grows downwards (the
# WinForms direction), so the painter only has to add the panel origin.
function New-SparklinePath {
    param($Series, [double]$Width, [double]$Height, [double]$Pad = 2, [double]$MinRange = 8)
    $points = @(ConvertTo-UsageHistoryArray $Series)
    if ($points.Count -lt 1 -or $Width -le 0 -or $Height -le 0) { return @() }

    $values = @($points | ForEach-Object { [double]$_.Pct })
    $lo = ($values | Measure-Object -Minimum).Minimum
    $hi = ($values | Measure-Object -Maximum).Maximum
    if (($hi - $lo) -lt $MinRange) {
        $middle = ($hi + $lo) / 2.0
        $lo = $middle - $MinRange / 2.0
        $hi = $middle + $MinRange / 2.0
    }
    if ($hi -le $lo) { $hi = $lo + 1.0 }

    $innerW = [Math]::Max(0.0, $Width - 2 * $Pad)
    $innerH = [Math]::Max(0.0, $Height - 2 * $Pad)
    $result = @()
    for ($i = 0; $i -lt $points.Count; $i++) {
        if ($points.Count -eq 1) { $x = $Pad + $innerW / 2.0 }
        else { $x = $Pad + $innerW * $i / ($points.Count - 1) }
        $ratio = [Math]::Max(0.0, [Math]::Min(1.0, ($values[$i] - $lo) / ($hi - $lo)))
        $y = $Pad + $innerH * (1.0 - $ratio)
        $result += @{ X = $x; Y = $y }
    }
    return $result
}

function ConvertTo-UsageHistoryField {
    param($Value)
    $text = [string]$Value
    if ($text -match '[",\r\n]') { return '"' + $text.Replace('"', '""') + '"' }
    return $text
}

function ConvertTo-UsageHistoryCsv {
    param($Records)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("time,id,percent`r`n")
    foreach ($record in @(ConvertTo-UsageHistoryArray $Records)) {
        if (-not $record) { continue }
        $time = ''
        try { $time = ([datetime]$record.Ts).ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        $id = ConvertTo-UsageHistoryField ([string]$record.Id)
        $pct = ''
        if ($null -ne $record.Pct) {
            try { $pct = ([double]$record.Pct).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        }
        [void]$builder.Append(('{0},{1},{2}' -f $time, $id, $pct))
        [void]$builder.Append("`r`n")
    }
    return $builder.ToString()
}

# UTF-8 with BOM and CRLF line endings so Excel opens the export directly.
function Export-UsageHistoryCsv {
    param([string]$Path, $Records, [string]$SourcePath)
    if (-not $Path) { return $false }
    if (-not $Records -and $SourcePath) { $Records = Read-UsageHistory -Path $SourcePath }
    $csv = ConvertTo-UsageHistoryCsv $Records
    [IO.File]::WriteAllText($Path, $csv, [Text.UTF8Encoding]::new($true))
    return $true
}