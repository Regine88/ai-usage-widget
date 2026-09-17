# Encoding: UTF-8 with BOM.
# Cursor usage helpers. Pure parsing plus a dependency-free sqlite text probe.
#
# POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
# with the editor access token returns the current billing-cycle pool:
#   { "planUsage": { "totalPercentUsed": 42.5, "remaining": 1150, "limit": 2000 },
#     "billingCycleEnd": 1774000000000 }
# Monetary fields are cents. The editor stores the JWT at
# cursorAuth/accessToken inside state.vscdb.

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

function ConvertTo-CursorDollars {
    param($Cents)
    if (-not (Test-FiniteNumber $Cents)) { return $null }
    return [Math]::Round([double]$Cents / 100.0, 2)
}

function Convert-CursorUnixMs {
    param($Value)
    if (-not (Test-FiniteNumber $Value)) { return $null }
    $number = [double]$Value
    if ($number -gt 1000000000000) { $number = $number / 1000.0 }
    if ($number -le 0) { return $null }
    try { return [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc').AddSeconds($number) } catch { return $null }
}

function Get-CursorPlanUsageObject {
    param($Payload)
    if (-not $Payload) { return $null }
    if ($Payload.PSObject.Properties['planUsage'] -and $Payload.planUsage) { return $Payload.planUsage }
    if ($Payload.PSObject.Properties['plan_usage'] -and $Payload.plan_usage) { return $Payload.plan_usage }
    return $null
}

function Convert-CursorPeriodUsage {
    param($Payload)
    if (-not $Payload) { throw 'bad-payload' }
    $plan = Get-CursorPlanUsageObject $Payload
    if (-not $plan) { throw 'bad-payload' }
    $percent = $null
    foreach ($name in @('totalPercentUsed', 'total_percent_used')) {
        if ($plan.PSObject.Properties[$name] -and (Test-FiniteNumber $plan.$name)) {
            $percent = Assert-UsagePercent $plan.$name 'cursor used percent'
            break
        }
    }
    $limit = ConvertTo-CursorDollars $plan.limit
    $remaining = ConvertTo-CursorDollars $plan.remaining
    $used = ConvertTo-CursorDollars $plan.used
    if ($null -eq $used) { $used = ConvertTo-CursorDollars $plan.totalSpend }
    if ($null -eq $percent) {
        if ($null -ne $limit -and $limit -gt 0 -and $null -ne $used) {
            $percent = Assert-UsagePercent ([Math]::Min(100.0, [Math]::Round(100.0 * $used / $limit, 1))) 'cursor used percent'
        } elseif ($null -ne $limit -and $limit -gt 0 -and $null -ne $remaining) {
            $used = [Math]::Max(0.0, $limit - $remaining)
            $percent = Assert-UsagePercent ([Math]::Min(100.0, [Math]::Round(100.0 * $used / $limit, 1))) 'cursor used percent'
        } else {
            throw 'bad-payload'
        }
    }
    $end = $null
    foreach ($name in @('billingCycleEnd', 'billing_cycle_end')) {
        if ($Payload.PSObject.Properties[$name]) { $end = Convert-CursorUnixMs $Payload.$name; if ($end) { break } }
    }
    $membership = $null
    foreach ($name in @('membershipType', 'membership_type')) {
        if ($Payload.PSObject.Properties[$name] -and $Payload.$name) { $membership = [string]$Payload.$name; break }
    }
    return [pscustomobject]@{
        Percent     = $percent
        Limit       = $limit
        Remaining   = $remaining
        Used        = $used
        ResetAt     = $end
        Membership  = $membership
        FetchedAt   = [datetime]::Now
    }
}

function Find-Utf8NeedleIndex {
    param([byte[]]$Bytes, [byte[]]$Needle, [int]$Start = 0)
    if (-not $Bytes -or -not $Needle -or $Needle.Length -eq 0) { return -1 }
    $last = $Bytes.Length - $Needle.Length
    for ($i = $Start; $i -le $last; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    return -1
}

function Get-CursorJwtFromBytes {
    param([byte[]]$Bytes, [int]$From)
    $limit = [Math]::Min($Bytes.Length, $From + 80)
    for ($k = $From; $k -lt $limit; $k++) {
        if (($k + 2) -ge $Bytes.Length) { break }
        if ($Bytes[$k] -ne 0x65 -or $Bytes[$k + 1] -ne 0x79 -or $Bytes[$k + 2] -ne 0x4A) { continue }
        $end = $k
        while ($end -lt $Bytes.Length) {
            $c = $Bytes[$end]
            $jwt = ($c -ge 0x41 -and $c -le 0x5A) -or ($c -ge 0x61 -and $c -le 0x7A) -or ($c -ge 0x30 -and $c -le 0x39) -or $c -eq 0x2D -or $c -eq 0x5F -or $c -eq 0x2E -or $c -eq 0x2B -or $c -eq 0x2F -or $c -eq 0x3D
            if (-not $jwt) { break }
            $end++
        }
        if (($end - $k) -ge 20) { return [Text.Encoding]::UTF8.GetString($Bytes, $k, $end - $k) }
    }
    return $null
}

function Get-CursorSqliteTextValue {
    param([byte[]]$Bytes, [string]$Key)
    if (-not $Bytes -or -not $Key) { return $null }
    $needle = [Text.Encoding]::UTF8.GetBytes($Key)
    $at = 0
    while ($true) {
        $found = Find-Utf8NeedleIndex -Bytes $Bytes -Needle $needle -Start $at
        if ($found -lt 0) { return $null }
        $token = Get-CursorJwtFromBytes -Bytes $Bytes -From ($found + $needle.Length)
        if ($token) { return $token }
        $at = $found + $needle.Length
    }
}
