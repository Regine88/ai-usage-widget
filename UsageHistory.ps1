# Usage history: turn ai-history.jsonl samples into a per-day series, a
# sparkline geometry and an exhaustion forecast. Everything except the file
# helpers is pure so the maths can be covered by an offline test.
#
# Legacy format: {"ts":"ISO-8601","id":"...","pct":number}
# Schema v2 adds provider/account/metric metadata and is stored in monthly files.

$script:UsageHistorySchemaVersion = 2
$script:UsageHistoryArchivePrefix = 'ai-history-'

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

    $ts = $null
    try { if ($raw.ts) { $ts = Convert-ApiTime ([string]$raw.ts) } } catch { }
    if (-not $ts) { return $null }

    $id = $null
    try { if ($raw.id) { $id = [string]$raw.id } } catch { }

    $schemaVersion = 1
    if (Test-FiniteNumber $raw.schemaVersion) { $schemaVersion = [int]$raw.schemaVersion }
    if ($schemaVersion -ge 2) {
        $provider = [string]$raw.provider
        $accountId = [string]$raw.accountId
        if (-not $id -and $provider -and $accountId) { $id = $provider + '-' + $accountId }
        if (-not $id) { return $null }

        $metricType = ([string]$raw.metricType).Trim().ToLowerInvariant()
        if ($metricType -notin @('percent', 'balance', 'unlimited', 'unknown')) { $metricType = 'unknown' }
        $pct = $null
        if ($metricType -in @('percent', 'unlimited')) {
            if (-not (Test-FiniteNumber $raw.pct)) { return $null }
            $pct = [double]$raw.pct
        }

        return @{
            Ts            = [datetime]$ts
            Id            = $id
            Pct           = $pct
            Provider      = $provider
            AccountId     = $accountId
            MetricType    = $metricType
            Window        = [string]$raw.window
            Cycle         = [string]$raw.cycle
            ResetAt       = [string]$raw.resetAt
            Value         = $(if (Test-FiniteNumber $raw.value) { [double]$raw.value } else { $null })
            Unit          = [string]$raw.unit
            Used          = $(if (Test-FiniteNumber $raw.used) { [double]$raw.used } else { $null })
            Limit         = $(if (Test-FiniteNumber $raw.limit) { [double]$raw.limit } else { $null })
            SampleState   = [string]$raw.sampleState
            SchemaVersion = 2
            Legacy        = $false
        }
    }

    if (-not $id -or -not (Test-FiniteNumber $raw.pct)) { return $null }
    return @{
        Ts            = [datetime]$ts
        Id            = $id
        Pct           = [double]$raw.pct
        Provider      = 'legacy'
        AccountId     = 'legacy:' + $id
        MetricType    = 'percent'
        Window        = ''
        Cycle         = ''
        ResetAt       = ''
        Value         = [double]$raw.pct
        Unit          = 'percent'
        Used          = $null
        Limit         = $null
        SampleState   = 'legacy'
        SchemaVersion = 1
        Legacy        = $true
    }
}

function Get-UsageHistoryArchiveDir {
    param([Parameter(Mandatory)][string]$Path)
    return (Join-Path (Split-Path -Parent $Path) 'history')
}

function Get-UsageHistoryArchivePath {
    param([Parameter(Mandatory)][string]$Path, [datetime]$Timestamp = (Get-Date))
    return (Join-Path (Get-UsageHistoryArchiveDir $Path) ($script:UsageHistoryArchivePrefix + $Timestamp.ToString('yyyy-MM') + '.jsonl'))
}

function Get-UsageHistorySourceFile {
    param([Parameter(Mandatory)][string]$Path)
    $files = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [void]$files.Add($Path) }
    if ([IO.Path]::GetFileName($Path) -ne 'ai-history.jsonl') { return @($files.ToArray()) }
    $archiveDir = Get-UsageHistoryArchiveDir $Path
    if (Test-Path -LiteralPath $archiveDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $archiveDir -Filter ($script:UsageHistoryArchivePrefix + '*.jsonl') -File | Sort-Object Name)) {
            [void]$files.Add($file.FullName)
        }
    }
    return @($files.ToArray())
}

function Read-UsageHistoryFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $Path -Encoding utf8) } catch { return @() }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $record = ConvertTo-UsageHistoryRecord $line
        if ($record) { [void]$records.Add($record) }
    }
    return (ConvertTo-UsageHistoryArray $records)
}

function Get-UsageHistoryRecordKey {
    param($Record)
    if (-not $Record) { return '' }
    $ts = ''
    try { $ts = ([datetime]$Record.Ts).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture) } catch { return '' }
    return (@(
        $ts
        [string]$Record.Id
        [string]$Record.Provider
        [string]$Record.MetricType
        [string]$Record.Window
        [string]$Record.ResetAt
    ) -join '|')
}

function Read-UsageHistory {
    param([string]$Path, [int]$Limit = 0, [datetime]$Since)
    if (-not $Path) { return @() }
    $records = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($file in @(Get-UsageHistorySourceFile -Path $Path)) {
        foreach ($record in @(Read-UsageHistoryFile -Path $file)) {
            if ($Since -and [datetime]$record.Ts -lt $Since) { continue }
            $key = Get-UsageHistoryRecordKey $record
            if (-not $key -or $seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$records.Add($record)
        }
    }
    $sorted = @($records | Sort-Object -Property @{ Expression = { $_.Ts } }, @{ Expression = { $_.Id } })
    if ($Limit -gt 0 -and $sorted.Count -gt $Limit) {
        $sorted = @($sorted[($sorted.Count - $Limit)..($sorted.Count - 1)])
    }
    return (ConvertTo-UsageHistoryArray $sorted)
}

# One point per local day - the last sample of that day - so the sparkline
# shows where each day ended instead of every poll.
function Get-UsageHistoryDaySeries {
    param($Records, [string]$Id, [int]$Days = 7, [string]$Kind, [datetime]$Now = (Get-Date), [string]$ResetAt = '')
    if (-not $Id -or $Days -lt 1) { return @() }
    $firstDay = $Now.Date.AddDays(-($Days - 1))
    $lastDay = $Now.Date.AddDays(1)

    $byDay = @{}
    foreach ($record in @(ConvertTo-UsageHistoryArray $Records)) {
        if (-not $record) { continue }
        if ([string]$record.Id -ne $Id) { continue }
        if ([string]$record.MetricType -and [string]$record.MetricType -ne 'percent') { continue }
        if ($ResetAt -and [string]$record.ResetAt -ne [string]$ResetAt) { continue }
        $ts = $record.Ts
        if (-not ($ts -is [datetime])) { continue }
        if ($ts -lt $firstDay -or $ts -ge $lastDay) { continue }
        $previous = $byDay[$ts.Date]
        if (-not $previous -or $ts -ge [datetime]$previous.Ts) {
            $byDay[$ts.Date] = @{ Ts = $ts; Pct = [double]$record.Pct; Normalized = ([int]$record.SchemaVersion -ge 2) }
        }
    }

    $series = @()
    foreach ($day in @($byDay.Keys | Sort-Object)) {
        $point = $byDay[$day]
        $pct = [double]$point.Pct
        if ($Kind -and -not [bool]$point.Normalized) {
            try { $pct = Convert-DisplayPercentToUsagePercent $pct $Kind } catch { continue }
        }
        $series += @{ Day = $day; Pct = $pct }
    }
    return $series
}

function Get-UsageHistorySampleSeries {
    param($Records, [string]$Id, [datetime]$Since, [string]$Kind, [string]$ResetAt = '')
    $series = @()
    foreach ($record in @(ConvertTo-UsageHistoryArray $Records)) {
        if (-not $record -or [string]$record.Id -ne $Id) { continue }
        if ([string]$record.MetricType -and [string]$record.MetricType -ne 'percent') { continue }
        if ($ResetAt -and [string]$record.ResetAt -ne [string]$ResetAt) { continue }
        $ts = $record.Ts
        if (-not ($ts -is [datetime]) -or $ts -lt $Since) { continue }
        $pct = [double]$record.Pct
        if ($Kind -and [int]$record.SchemaVersion -lt 2) {
            try { $pct = Convert-DisplayPercentToUsagePercent $pct $Kind } catch { continue }
        }
        $series += @{ Day = $ts; Pct = $pct }
    }
    return @($series | Sort-Object -Property @{ Expression = { $_.Day } })
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

    $points = @(ConvertTo-UsageHistoryArray $Series)
    if ($points.Count -lt 3) { return $forecast }
    $slope = Get-UsageTrendSlope $points
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

function Invoke-UsageHistoryFileLock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Action)
    if (Get-Command Invoke-SecureSnapshotFileLock -ErrorAction SilentlyContinue) {
        return (Invoke-SecureSnapshotFileLock -Path $Path -Action $Action)
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $name = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '')
    } finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\AIUsageHistory-' + $name))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '历史文件正在被其他进程写入' }
        return (& $Action)
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() | Out-Null } catch { } }
        $mutex.Dispose()
    }
}

function ConvertTo-UsageHistoryLine {
    param($Record)
    if (-not $Record) { return $null }
    $canonical = [ordered]@{
        schemaVersion = $script:UsageHistorySchemaVersion
        ts            = ([datetime]$Record.Ts).ToString('o')
        id            = [string]$Record.Id
        provider      = [string]$Record.Provider
        accountId     = [string]$Record.AccountId
        metricType    = [string]$Record.MetricType
        window        = [string]$Record.Window
        cycle         = [string]$Record.Cycle
        resetAt       = [string]$Record.ResetAt
        value         = $Record.Value
        unit          = [string]$Record.Unit
        used          = $Record.Used
        limit         = $Record.Limit
        sampleState   = [string]$Record.SampleState
    }
    if ($null -ne $Record.Pct) { $canonical.pct = $Record.Pct }
    return ($canonical | ConvertTo-Json -Depth 6 -Compress)
}

function Add-UsageHistoryLine {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Line)
    Add-UsageHistoryLines -Path $Path -Lines @($Line) | Out-Null
}

function Add-UsageHistoryLines {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Lines)
    $items = @($Lines | Where-Object { $_ })
    if ($items.Count -eq 0) { return 0 }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $text = (($items | ForEach-Object { ([string]$_).TrimEnd([char]13, [char]10) }) -join [Environment]::NewLine) + [Environment]::NewLine
    Invoke-UsageHistoryFileLock -Path $Path -Action {
        [IO.File]::AppendAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    } | Out-Null
    return $items.Count
}

function Import-UsageHistoryLegacy {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $legacy = @(Read-UsageHistoryFile -Path $Path)
    if ($legacy.Count -eq 0) { return 0 }
    $copied = 0
    foreach ($group in @($legacy | Group-Object { $_.Ts.ToString('yyyy-MM') })) {
        $month = [datetime]::ParseExact($group.Name + '-01', 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $archive = Get-UsageHistoryArchivePath -Path $Path -Timestamp $month
        $existing = @(Read-UsageHistoryFile -Path $archive)
        $keys = @{}
        foreach ($record in $existing) { $keys[(Get-UsageHistoryRecordKey $record)] = $true }
        $newLines = @()
        foreach ($record in @($group.Group)) {
            $key = Get-UsageHistoryRecordKey $record
            if (-not $key -or $keys.ContainsKey($key)) { continue }
            $newLines += (ConvertTo-UsageHistoryLine $record)
            $keys[$key] = $true
        }
        if ($newLines.Count -gt 0) { $copied += (Add-UsageHistoryLines -Path $archive -Lines $newLines) }
    }
    return $copied
}

function Invoke-UsageHistoryRetention {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetentionDays = 90,
        [long]$MaxBytes = 10485760,
        [datetime]$Now = (Get-Date)
    )
    $archiveDir = Get-UsageHistoryArchiveDir $Path
    if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) {
        return @{ Removed = @(); Bytes = 0; Incomplete = $false }
    }
    $files = @(Get-ChildItem -LiteralPath $archiveDir -Filter ($script:UsageHistoryArchivePrefix + '*.jsonl') -File | Sort-Object Name)
    $removed = @()
    if ($RetentionDays -gt 0) {
        $cutoff = $Now.Date.AddDays(-$RetentionDays)
        foreach ($file in $files) {
            $monthText = $file.BaseName.Substring($script:UsageHistoryArchivePrefix.Length)
            $month = $null
            try { $month = [datetime]::ParseExact($monthText + '-01', 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
            if ($month.AddMonths(1) -le $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force
                $removed += $file.Name
            }
        }
        $files = @($files | Where-Object { -not ($removed -contains $_.Name) })
    }

    $total = 0L
    foreach ($file in $files) { $total += [long]$file.Length }
    $incomplete = $false
    if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) {
        $currentMonth = $Now.ToString('yyyy-MM')
        foreach ($file in $files) {
            if ($total -le $MaxBytes) { break }
            $monthText = $file.BaseName.Substring($script:UsageHistoryArchivePrefix.Length)
            if ($monthText -eq $currentMonth) { continue }
            $size = [long]$file.Length
            Remove-Item -LiteralPath $file.FullName -Force
            $removed += $file.Name
            $total -= $size
        }
        $incomplete = $total -gt $MaxBytes
    }
    return @{ Removed = @($removed); Bytes = $total; Incomplete = $incomplete }
}

function Write-UsageHistoryRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Id,
        [string]$Provider,
        [string]$AccountId,
        [string]$MetricType = 'percent',
        [AllowNull()]$Percent,
        [AllowNull()]$Value,
        [string]$Unit,
        [string]$Window,
        [string]$Cycle,
        [string]$ResetAt,
        [AllowNull()]$Used,
        [AllowNull()]$Limit,
        [string]$SampleState = 'changed',
        [datetime]$Timestamp = (Get-Date),
        [int]$RetentionDays = 90,
        [long]$MaxBytes = 10485760
    )
    if (-not $Id) { throw 'history id is required' }
    [void](Import-UsageHistoryLegacy -Path $Path)
    $metric = ([string]$MetricType).Trim().ToLowerInvariant()
    if ($metric -notin @('percent', 'balance', 'unlimited', 'unknown')) { $metric = 'unknown' }
    if ($metric -in @('percent', 'unlimited') -and -not (Test-FiniteNumber $Percent)) { throw 'percent history sample is missing percent' }
    $record = [ordered]@{
        schemaVersion = $script:UsageHistorySchemaVersion
        ts            = $Timestamp.ToString('o')
        id            = $Id
        provider      = [string]$Provider
        accountId     = [string]$AccountId
        metricType    = $metric
        window        = [string]$Window
        cycle         = [string]$Cycle
        resetAt       = [string]$ResetAt
        value         = $(if (Test-FiniteNumber $Value) { [double]$Value } else { $null })
        unit          = [string]$Unit
        used          = $(if (Test-FiniteNumber $Used) { [double]$Used } else { $null })
        limit         = $(if (Test-FiniteNumber $Limit) { [double]$Limit } else { $null })
        sampleState   = [string]$SampleState
    }
    if ($metric -in @('percent', 'unlimited')) { $record.pct = [double]$Percent }
    $archive = Get-UsageHistoryArchivePath -Path $Path -Timestamp $Timestamp
    Add-UsageHistoryLine -Path $archive -Line (ConvertTo-UsageHistoryLine $record)
    [void](Invoke-UsageHistoryRetention -Path $Path -RetentionDays $RetentionDays -MaxBytes $MaxBytes -Now $Timestamp)
    return $archive
}

function Get-UsageHistoryInventory {
    param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 0)
    $archiveDir = Get-UsageHistoryArchiveDir $Path
    $files = @()
    if (Test-Path -LiteralPath $archiveDir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $archiveDir -Filter ($script:UsageHistoryArchivePrefix + '*.jsonl') -File | Sort-Object Name)
    }
    $bytes = 0L
    foreach ($file in $files) { $bytes += [long]$file.Length }
    $oldest = $null
    $newest = $null
    if ($files.Count -gt 0) {
        $oldest = $files[0].BaseName.Substring($script:UsageHistoryArchivePrefix.Length)
        $newest = $files[$files.Count - 1].BaseName.Substring($script:UsageHistoryArchivePrefix.Length)
    }
    return @{
        FileCount = $files.Count
        Bytes     = $bytes
        Oldest    = $oldest
        Newest    = $newest
        Incomplete = ($MaxBytes -gt 0 -and $bytes -gt $MaxBytes)
        Files     = @($files | ForEach-Object FullName)
    }
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
    [void]$builder.Append("time,id,provider,accountId,metricType,window,cycle,resetAt,value,unit,used,limit,sampleState,percent`r`n")
    foreach ($record in @(ConvertTo-UsageHistoryArray $Records)) {
        if (-not $record) { continue }
        $time = ''
        try { $time = ([datetime]$record.Ts).ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        $number = {
            param($value)
            if ($null -eq $value) { return '' }
            try { return ([double]$value).ToString('0.######', [Globalization.CultureInfo]::InvariantCulture) } catch { return '' }
        }
        $fields = @(
            (ConvertTo-UsageHistoryField $time)
            (ConvertTo-UsageHistoryField ([string]$record.Id))
            (ConvertTo-UsageHistoryField ([string]$record.Provider))
            (ConvertTo-UsageHistoryField ([string]$record.AccountId))
            (ConvertTo-UsageHistoryField ([string]$record.MetricType))
            (ConvertTo-UsageHistoryField ([string]$record.Window))
            (ConvertTo-UsageHistoryField ([string]$record.Cycle))
            (ConvertTo-UsageHistoryField ([string]$record.ResetAt))
            (& $number $record.Value)
            (ConvertTo-UsageHistoryField ([string]$record.Unit))
            (& $number $record.Used)
            (& $number $record.Limit)
            (ConvertTo-UsageHistoryField ([string]$record.SampleState))
            (& $number $record.Pct)
        )
        [void]$builder.Append(($fields -join ','))
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
