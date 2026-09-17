# Pure validation and redaction helpers shared by the UI and worker runspace.

function Test-FiniteNumber {
    param($Value)
    if ($null -eq $Value) { return $false }
    try { $number = [double]$Value } catch { return $false }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
    return $true
}

function Assert-UsagePercent {
    param(
        $Value,
        [string]$Field = 'usage percent'
    )
    if (-not (Test-FiniteNumber $Value)) {
        throw ("{0} 缺失或不是有限数值" -f $Field)
    }
    $number = [double]$Value
    if ($number -lt 0 -or $number -gt 100) {
        throw ("{0} 超出 0-100 范围" -f $Field)
    }
    return $number
}

function Assert-PositiveFiniteNumber {
    param(
        $Value,
        [string]$Field = '数值'
    )
    if (-not (Test-FiniteNumber $Value)) {
        throw ("{0} 缺失或不是有限数值" -f $Field)
    }
    $number = [double]$Value
    if ($number -le 0) {
        throw ("{0} 必须大于 0" -f $Field)
    }
    return $number
}

function Convert-UsageRatioPercent {
    param(
        $Used,
        $Limit,
        [string]$Field = 'usage ratio'
    )
    if ($null -eq $Used -or -not (Test-FiniteNumber $Used)) {
        throw ("{0} 的 used 缺失或不是有限数值" -f $Field)
    }
    if ($null -eq $Limit -or -not (Test-FiniteNumber $Limit)) {
        throw ("{0} 的 limit 缺失或不是有限数值" -f $Field)
    }
    $usedNumber = [double]$Used
    $limitNumber = [double]$Limit
    if ($usedNumber -lt 0) { throw ("{0} 的 used 不能为负数" -f $Field) }
    if ($limitNumber -le 0) { throw ("{0} 的 limit 必须大于 0" -f $Field) }
    $percent = [Math]::Min(100.0, 100.0 * $usedNumber / $limitNumber)
    return Assert-UsagePercent $percent ("{0} percent" -f $Field)
}

function Convert-DisplayPercentToUsagePercent {
    param(
        $Percent,
        [string]$Kind
    )
    $display = Assert-UsagePercent $Percent 'display percent'
    $usage = if ($Kind -eq 'gemini') { 100.0 - $display } else { $display }
    return Assert-UsagePercent $usage 'usage percent'
}

function Convert-OptionalNumber {
    param(
        $Value,
        [string]$Field = '数值'
    )
    if ($null -eq $Value) { return $null }
    if (([string]$Value).Trim() -eq '') { return $null }
    if (-not (Test-FiniteNumber $Value)) { throw ("{0} 缺失或不是有限数值" -f $Field) }
    return [double]$Value
}

function Convert-ApiTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    return [datetime]::Parse([string]$Value, $null, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Resolve-TrustedHttpsEndpoint {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Value,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$AllowedHosts
    )
    try { $uri = [Uri]::new($Value.Trim()) } catch { throw 'API 地址不是有效的绝对 URL' }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        throw 'API 地址必须使用 HTTPS 绝对 URL'
    }
    $endpointHost = $uri.DnsSafeHost.ToLowerInvariant()
    $allowedHostSet = @($AllowedHosts | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if ($allowedHostSet -notcontains $endpointHost) {
        throw ("API 地址主机不在允许列表: {0}" -f $endpointHost)
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'API 地址不能包含用户信息、查询参数或片段'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-AccountFingerprint {
    param(
        [AllowNull()][string]$AccountId,
        [string]$Prefix = 'acct'
    )
    if (-not $AccountId) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($AccountId.Trim().ToLowerInvariant())
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return ('{0}-{1}' -f $Prefix, $hash.Substring(0, 8))
}

function Convert-SafeLogText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [int]$MaxLength = 400
    )
    if ($null -eq $Text) { return $null }
    $safe = $Text -replace '[\r\n\t]+', ' '
    $safe = $safe -replace '(?i)(Bearer\s+)[^\s,;}{"'']+', '$1[redacted]'
    $safe = $safe -replace '(?i)(["'']?)(access_token|refresh_token|id_token|client_secret|api[_-]?key)(["'']?\s*[:=]\s*["'']?)([^"''\s,&}]+)(["'']?)', '$1$2$3[redacted]$5'
    $safe = $safe -replace '(?i)\bsk-[a-z0-9_-]{8,}\b', 'sk-[redacted]'
    $safe = $safe -replace '(?i)([a-z0-9._%+\-]+)@([a-z0-9.\-]+\.[a-z]{2,})', '$1[at]$2'
    $safe = $safe -replace '(?i)(https?://[^\s?]+)[^\s]*', '$1'
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaxLength) { return $safe.Substring(0, $MaxLength) }
    return $safe
}

function Get-WidgetTrustedHosts {
    return @(
        'auth.x.ai'
        'cli-chat-proxy.grok.com'
        'auth.openai.com'
        'chatgpt.com'
        'api.commandcode.ai'
        'openrouter.ai'
        'api.deepseek.com'
        'oauth2.googleapis.com'
        'cloudcode-pa.googleapis.com'
        'api.github.com'
        'auth.kimi.com'
        'auth.kimi.ai'
        'api.kimi.com'
        'api.kimi.ai'
        'api.anthropic.com'
        'platform.claude.com'
        'console.anthropic.com'
        'api2.cursor.sh'
        'cursor.com'
        'api.z.ai'
        'open.bigmodel.cn'
    )
}

# Host-only check used by Invoke-WidgetRest. Unlike Resolve-TrustedHttpsEndpoint
# this allows path and query (Grok billing uses ?format=credits) and rejects
# only non-https schemes and hosts outside the allow list.
function Assert-TrustedHttpsHost {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Value,
        [string[]]$AllowedHosts
    )
    if (-not $AllowedHosts -or $AllowedHosts.Count -eq 0) {
        $AllowedHosts = Get-WidgetTrustedHosts
    }
    try { $uri = [Uri]::new($Value.Trim()) } catch { throw 'API 地址不是有效的绝对 URL' }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        throw 'API 地址必须使用 HTTPS 绝对 URL'
    }
    $endpointHost = $uri.DnsSafeHost.ToLowerInvariant()
    $allowedHostSet = @($AllowedHosts | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if ($allowedHostSet -notcontains $endpointHost) {
        throw ("API 地址主机不在允许列表: {0}" -f $endpointHost)
    }
    return $uri.AbsoluteUri
}
