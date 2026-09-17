# Encoding: UTF-8 with BOM.
# Shared credential lookup for providers that authenticate with a plain bearer
# token (OpenRouter, DeepSeek, ...). Pure file/ENV reading: no network, no UI and
# no logging, so the helpers stay offline-testable and safe inside the worker.
#
# Credential sources, in priority order:
#   1. <AuthPath> - a JSON file whose key is spelled apiKey / api_key / key / token
#   2. an environment variable, kept as the CI and portable fallback

if (-not (Get-Command Get-ConfigPropertyValue -ErrorAction SilentlyContinue)) {
    $configHelper = Join-Path $PSScriptRoot 'WidgetConfig.ps1'
    if (Test-Path -LiteralPath $configHelper) { . $configHelper }
}

# Read the key candidates out of one JSON file; an unreadable or malformed file
# yields nothing so a broken credential file can never break startup.
function Get-ApiKeyFileSources {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $sources = @()
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($name in @('apiKey', 'api_key', 'key', 'token')) {
            $value = Get-ConfigPropertyValue $raw $name
            if ($value) { $sources += [string]$value }
        }
    } catch {
    }
    return @($sources)
}

# File first, environment variable second; duplicates collapse so one account
# never shows up as two rows.
function Get-ApiKeySources {
    param([string]$AuthPath, [string]$EnvironmentValue)
    $sources = @(Get-ApiKeyFileSources -Path $AuthPath)
    if ($EnvironmentValue) { $sources += [string]$EnvironmentValue }
    return @($sources | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-ApiKeyCredExists {
    param([string]$AuthPath, [string]$EnvironmentValue)
    if ($AuthPath -and (Test-Path -LiteralPath $AuthPath)) { return $true }
    return [bool]$EnvironmentValue
}

# Only the credential sources are read here; string comparison stays with the
# caller so a key never reaches the log.
function Read-ApiKeyAuth {
    param([string]$AuthPath, [string]$EnvironmentValue)
    $keys = @(Get-ApiKeySources -AuthPath $AuthPath -EnvironmentValue $EnvironmentValue)
    if ($keys.Count -eq 0) { throw 'missing-credential' }
    return [pscustomobject]@{ ApiKey = $keys[0]; ApiKeyCount = $keys.Count }
}

function Get-ApiKeyAuthHeaders {
    param($Auth)
    return @{
        Authorization = "Bearer $($Auth.ApiKey)"
        Accept        = 'application/json'
        'User-Agent'  = 'ai-usage-widget'
    }
}

# These keys are minted in a web console and have no refresh flow, so a 401 is
# surfaced to Format-FetchError ("登录已过期") instead of being retried.
function Invoke-ApiKeyGet {
    param($Auth, [string]$BaseUrl, [string]$Path)
    return Invoke-WidgetRest -Method Get -Uri ($BaseUrl + $Path) -Headers (Get-ApiKeyAuthHeaders $Auth)
}