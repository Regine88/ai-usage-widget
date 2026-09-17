# Encoding: UTF-8 with BOM.
# CopilotQuota.ps1 - GitHub Copilot 用量载荷的纯解析。
#
# 数据来自 https://api.github.com/copilot_internal/user（社区通用、非官方文档接口），
# 请求头需要 Authorization: token <oauth_token 或带 copilot scope 的经典 PAT>。
# 载荷形如：
#   { "copilot_plan": "individual", "quota_reset_date": "2026-10-01",
#     "quota_snapshots": {
#       "premium_interactions": { "entitlement": 300, "remaining": 171, "percent_remaining": 57.0, "unlimited": false } } }
# 本模块只做“对象到数值”的换算，不读磁盘、不联网，因此可以离线测试。

function Get-CopilotProperty {
    param($Source, [string]$Name)
    if ($null -eq $Source -or -not $Name) { return $null }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $null
    }
    $property = $Source.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

# 单个配额窗口：优先进位为 entitlement/remaining，缺失时退回 percent_remaining。
function Convert-CopilotQuotaDetail {
    param($Value)
    if ($null -eq $Value) { return $null }
    $unlimited = [bool](Get-CopilotProperty $Value 'unlimited')
    $entitlement = 0.0
    $remaining = 0.0
    $percentRemaining = $null

    $rawEntitlement = Get-CopilotProperty $Value 'entitlement'
    if (Test-FiniteNumber $rawEntitlement) { $entitlement = [double]$rawEntitlement }
    $rawRemaining = Get-CopilotProperty $Value 'remaining'
    if (Test-FiniteNumber $rawRemaining) { $remaining = [double]$rawRemaining }
    $rawPercent = Get-CopilotProperty $Value 'percent_remaining'
    if (Test-FiniteNumber $rawPercent) { $percentRemaining = [double]$rawPercent }

    $usedPercent = 0.0
    if ($unlimited) {
        $usedPercent = 0.0
    } elseif ($entitlement -gt 0) {
        $usedPercent = (($entitlement - $remaining) / $entitlement) * 100.0
    } elseif ($null -ne $percentRemaining) {
        $usedPercent = 100.0 - $percentRemaining
    }
    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $usedPercent))
    return @{
        Unlimited   = $unlimited
        Entitlement = $entitlement
        Remaining   = [Math]::Max(0.0, $remaining)
        UsedPercent = $usedPercent
    }
}

function Convert-CopilotResetDate {
    param($Value)
    if (-not $Value) { return $null }
    try { return [datetime]::Parse([string]$Value) } catch { return $null }
}

function Convert-CopilotQuota {
    param($Payload)
    if ($null -eq $Payload) { return $null }
    $snapshots = Get-CopilotProperty $Payload 'quota_snapshots'
    return @{
        Plan        = [string](Get-CopilotProperty $Payload 'copilot_plan')
        Premium     = (Convert-CopilotQuotaDetail (Get-CopilotProperty $snapshots 'premium_interactions'))
        Chat        = (Convert-CopilotQuotaDetail (Get-CopilotProperty $snapshots 'chat'))
        Completions = (Convert-CopilotQuotaDetail (Get-CopilotProperty $snapshots 'completions'))
        ResetAt     = (Convert-CopilotResetDate (Get-CopilotProperty $Payload 'quota_reset_date'))
    }
}

# hosts.json / apps.json / OpenCode auth.json 的嵌套层级随版本变化，
# 所以按“深度优先找第一个 token 键”的方式读取，避免绑定单一结构。
# 只有非空字符串才算 token；配置文件里的数字或布尔值一律忽略。
function ConvertTo-CopilotTokenText {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $null }
    $text = $Value.Trim()
    if (-not $text) { return $null }
    return $text
}

function Find-CopilotToken {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $null }
    $tokenKeys = @('oauth_token', 'oauthToken', 'access_token', 'accessToken', 'access')
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $tokenKeys) {
            if ($Value.Contains($key)) {
                $candidate = ConvertTo-CopilotTokenText $Value[$key]
                if ($candidate) { return $candidate }
            }
        }
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $found = Find-CopilotToken $Value[$key]
            if ($found) { return $found }
        }
        return $null
    }
    foreach ($key in $tokenKeys) {
        $property = $Value.PSObject.Properties[$key]
        if ($property) {
            $candidate = ConvertTo-CopilotTokenText $property.Value
            if ($candidate) { return $candidate }
        }
    }
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $found = Find-CopilotToken $property.Value
        if ($found) { return $found }
    }
    return $null
}