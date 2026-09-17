# Encoding: UTF-8 with BOM.
# DeepSeek balance helpers. Pure parsing, no network/UI dependency.
#
# GET https://api.deepseek.com/user/balance answers with the prepaid balance:
#   { "is_available": true,
#     "balance_infos": [ { "currency": "CNY", "total_balance": "1.58",
#                          "granted_balance": "0.00",
#                          "topped_up_balance": "1.58" } ] }
#
# DeepSeek has no rolling quota window: the number a user cares about is the
# balance itself, so the row prints an amount instead of a percentage. Amounts
# arrive as decimal strings and are normalised to numbers here.

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

# Only the purses DeepSeek actually tops up get a symbol; anything else keeps its
# ISO code so an unknown currency stays readable instead of printing a bare number.
function Get-DeepSeekCurrencySymbol {
    param([string]$Currency)
    $code = ([string]$Currency).Trim().ToUpperInvariant()
    if ($code -eq 'USD') { return '$' }
    if ($code -eq 'CNY') { return '¥' }
    return ''
}

# Amounts are formatted with the invariant culture on purpose: a currency symbol
# must not turn into "1,58" on a machine whose regional format says so.
function Format-DeepSeekAmount {
    param([double]$Amount, [string]$Currency)
    $value = $Amount.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
    $symbol = Get-DeepSeekCurrencySymbol $Currency
    if ($symbol) { return ($symbol + $value) }
    $code = ([string]$Currency).Trim().ToUpperInvariant()
    if (-not $code) { return $value }
    return ($code + ' ' + $value)
}

function ConvertTo-DeepSeekPurse {
    param($Info)
    if (-not $Info) { return $null }
    if (-not (Test-FiniteNumber $Info.total_balance)) { return $null }
    $total = [double]$Info.total_balance
    if ($total -lt 0) { return $null }
    $granted = 0.0
    if (Test-FiniteNumber $Info.granted_balance) { $granted = [double]$Info.granted_balance }
    $topped = 0.0
    if (Test-FiniteNumber $Info.topped_up_balance) { $topped = [double]$Info.topped_up_balance }
    return [pscustomobject]@{
        Currency = ([string]$Info.currency).Trim().ToUpperInvariant()
        Total    = $total
        Granted  = $granted
        ToppedUp = $topped
    }
}

# Convert-DeepSeekBalance -> Currency/Total/Granted/ToppedUp/IsAvailable/Display.
# An account can hold several purses at once (a USD and a CNY one), so the row
# shows the first funded purse and falls back to the first readable one when every
# balance is zero.
function Convert-DeepSeekBalance {
    param($Payload)
    if (-not $Payload) { throw 'bad-payload' }
    $infos = @($Payload.balance_infos)
    if ($infos.Count -eq 0) { throw 'bad-payload' }

    $funded = $null
    $fallback = $null
    foreach ($info in $infos) {
        $purse = ConvertTo-DeepSeekPurse $info
        if (-not $purse) { continue }
        if (-not $fallback) { $fallback = $purse }
        if ($purse.Total -gt 0) { $funded = $purse; break }
    }
    $picked = if ($funded) { $funded } else { $fallback }
    if (-not $picked) { throw 'bad-payload' }

    # A payload without the flag still carries a usable balance, so the warning is
    # only raised when the API explicitly reports the account as unusable.
    $available = $true
    if ($null -ne $Payload.is_available) { $available = [bool]$Payload.is_available }
    return [pscustomobject]@{
        Currency    = $picked.Currency
        Total       = $picked.Total
        Granted     = $picked.Granted
        ToppedUp    = $picked.ToppedUp
        IsAvailable = $available
        Display     = (Format-DeepSeekAmount $picked.Total $picked.Currency)
        FetchedAt   = [datetime]::Now
    }
}