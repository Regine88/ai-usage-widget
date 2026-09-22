# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetFormat.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')

$script:Language = 'en-US'
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here

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

Assert-Eq (Format-PercentText 0) '0%' 'explicit zero stays a percent'
Assert-Eq (Format-PercentText 12) '12%' 'whole percent has no decimal'
Assert-Eq (Format-PercentText 12.5) '12.5%' 'fractional percent keeps one decimal'
Assert-Eq (Format-RowValueText -Display '' -Percent 9) '9%' 'empty display falls back to percent'
Assert-Eq (Format-RowValueText -Display '¥14.00' -Percent 0) '¥14.00' 'display text wins over percent'

Assert-Eq (Format-FetchError 'Request timeout after 15s') 'Request timed out' 'timeout maps'
Assert-Eq (Format-FetchError 'HTTP 401 Unauthorized') 'Sign-in expired, please sign in again' '401 maps'
Assert-Eq (Format-FetchError 'HTTP 403 rate limit exceeded') 'Too many requests' '403 rate limit maps before forbidden'
Assert-Eq (Format-FetchError 'HTTP 403 Forbidden') 'Access denied' 'plain 403 maps to forbidden'
Assert-Eq (Format-FetchError 'missing-credential') 'Not signed in' 'missing credential maps'
Assert-Eq (Format-FetchError 'missing-secret') 'The refresh client secret is missing; set ANTIGRAVITY_CLIENT_SECRET' 'missing client secret maps to configuration guidance'
Assert-Eq (Format-FetchError 'weird-backend-crash') 'Failed to read usage, please retry later' 'unknown error is generic'
$detailed = Format-FetchError 'weird-backend-crash' -Detail
Assert-Eq ($detailed -like 'Failed to read usage, please retry later*') 'True' 'detail appends the redacted original'

$stamp = ConvertTo-ResetStamp ([datetime]::SpecifyKind([datetime]'2026-09-17T12:00:00', 'Utc'))
Assert-Eq ([string]::IsNullOrEmpty($stamp)) 'False' 'reset stamp is emitted'
Assert-Eq ($stamp -match '2026-09-17') 'True' 'reset stamp keeps the calendar day'

$never = Format-ForecastText @{ EtaHours = $null; SlopePerDay = -0.1; ExhaustsBeforeReset = $false }
Assert-Eq $never 'No exhaustion at the recent pace' 'negative slope never exhausts'
$hours = Format-ForecastText @{ EtaHours = 9.0; SlopePerDay = 2; ExhaustsBeforeReset = $true }
Assert-Eq ($hours -like '*before the next reset') 'True' 'forecast before reset'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
