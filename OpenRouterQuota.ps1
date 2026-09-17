# Encoding: UTF-8 with BOM.
# OpenRouter quota helpers. Pure parsing, no network/UI dependency.
#
# The OpenRouter key payload carries the spend limit the key was created with:
#   { "data": { "label": "sk-or-v1-abcd...", "usage": 12.5, "limit": 100,
#               "limit_remaining": 87.5, "limit_reset": "monthly" } }
# `limit` and `limit_remaining` are nullable: a key without a limit is "unlimited"
# and has no percentage to show, so the row says so instead of faking 0%.

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

# API keys are labelled with the key itself; show a short fingerprint instead so
# the row never prints the whole secret.
function Get-OpenRouterKeyFingerprint {
    param([string]$Key)
    $text = ([string]$Key).Trim()
    if (-not $text) { return 'OpenRouter' }
    $hash = [string]::Empty
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
            $hash = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 8)
        } finally {
            $sha.Dispose()
        }
    } catch {
        # 没有哈希实现时退化成不明文的前缀，仍然不泄漏完整密钥。
        $tail = $text.Substring([Math]::Max(0, $text.Length - 4))
        $hash = ('x' + $tail)
    }
    return ('OpenRouter-' + $hash)
}

# Convert-OpenRouterCredits -> Percent/SpentText/IsUnlimited/Label.
function Convert-OpenRouterCredits {
    param($KeyData)
    $data = $KeyData
    if ($data -and $data.data) { $data = $data.data }
    if (-not $data) { throw 'bad-payload' }

    if ($null -eq $data.usage) { throw 'bad-payload' }
    if (-not (Test-FiniteNumber $data.usage)) { throw 'bad-payload' }
    $spent = [double]$data.usage
    if ($spent -lt 0) { throw 'bad-payload' }

    $label = ''
    if ($data.label) { $label = [string]$data.label }

    $period = $null
    if ($data.limit_reset) {
        $period = ([string]$data.limit_reset).Trim().ToLowerInvariant()
    }

    $limit = $null
    if ($null -ne $data.limit) {
        if (-not (Test-FiniteNumber $data.limit)) { throw 'bad-payload' }
        $limit = [double]$data.limit
        if ($limit -le 0) { throw 'bad-payload' }
    }

    if ($null -eq $limit) {
        return [pscustomobject]@{
            Percent     = $null
            Spent       = $spent
            Limit       = $null
            Remaining   = $null
            IsUnlimited = $true
            Label       = $label
            Period      = $period
            FetchedAt   = [datetime]::Now
        }
    }

    # 花超之后不再算比例，直接停在 100%，避免出现 120% 这种读数。
    $ratio = [Math]::Min(100.0, [Math]::Round(($spent / $limit) * 100.0, 1))
    $percent = Assert-UsagePercent $ratio 'OpenRouter spent percent'
    $remaining = $limit - $spent
    if ($remaining -lt 0) { $remaining = 0.0 }
    return [pscustomobject]@{
        Percent     = $percent
        Spent       = $spent
        Limit       = $limit
        Remaining   = [Math]::Round($remaining, 4)
        IsUnlimited = $false
        Label       = $label
        Period      = $period
        FetchedAt   = [datetime]::Now
    }
}