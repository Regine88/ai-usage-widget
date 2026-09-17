# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-OpenRouterProvider.ps1
# 把主程序里与 OpenRouter 相关的函数定义取出来在同一个进程里调用，所以既不启动界面也不发网络请求。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'OpenRouterQuota.ps1')

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

function Get-ScriptFunctionDefinition {
    param([string]$ScriptPath, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return $fn.Extent.Text }
    }
    throw ('function not found: ' + $Name)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
. (Join-Path $here 'WidgetStrings.ps1')
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here

$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8

# ---------- 行数据：有上限 ----------
$limited = '{"data":{"label":"sk-or-v1-abc","usage":12.5,"limit":100,"limit_remaining":87.5,"limit_reset":"monthly"}}' | ConvertFrom-Json
$missing = '{"data":{"usage":3.25,"limit":null,"limit_remaining":null}}' | ConvertFrom-Json
$script:payload = $limited
$script:seenUri = ''
$script:seenAuth = ''
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType)
    $script:seenUri = $Uri
    $script:seenAuth = $Headers['Authorization']
    return $script:payload
}

$definitions = @()
foreach ($name in @('Get-OpenRouterAuthHeaders', 'Invoke-OpenRouterGet', 'Get-OpenRouterUsageSnapshot', 'Get-OpenRouterRowData', 'Format-PercentText')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:OpenRouterApiBaseUrl = ''https://openrouter.ai/api/v1'''
$definitions += '$script:OpenRouterDisplayName = ''OpenRouter'''
$definitions += 'function Write-WidgetLog { param([string]$Message) }'
$probe = $definitions -join [Environment]::NewLine
. ([ScriptBlock]::Create($probe))

$row = Get-OpenRouterRowData -Auth ([pscustomobject]@{ ApiKey = 'sk-or-v1-test'; ApiKeyCount = 1 }) -Name 'OpenRouter-abc' -Id 'openrouter-abc'
Assert-Eq $script:seenUri 'https://openrouter.ai/api/v1/key' 'the key payload is read from the expected endpoint'
Assert-Eq ($script:seenAuth -like 'Bearer sk-*') 'True' 'the request carries the bearer token'
Assert-Eq $row.Percent '12.5' 'limited key reports its percent'
Assert-Eq $row.Detail 'used $12.50 of $100.00 (12.5%)' 'limited key detail line'

# ---------- 行数据：无上限 ----------
$script:payload = $missing
$unlimited = Get-OpenRouterRowData -Auth ([pscustomobject]@{ ApiKey = 'sk-or-v1-test'; ApiKeyCount = 1 }) -Name 'OpenRouter-abc' -Id 'openrouter-abc'
Assert-Eq $unlimited.Percent '0' 'a key without a limit shows as 0 percent'
Assert-Eq $unlimited.Detail 'used $3.25 (no limit)' 'unlimited key detail line says so'

# ---------- 凭证：文件优先，环境变量兜底 ----------
$sandbox = Join-Path $env:TEMP ('openrouter-provider-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    # 拼出与真实密钥等长的假密钥，避免字面量触发仓库的推送保护
    $keyA = 'sk-or-v1-' + ('1' * 64)
    $keyB = 'sk-or-v1-' + ('2' * 64)
    $authPath = Join-Path $sandbox 'auth.json'
    [IO.File]::WriteAllText($authPath, ('{ "apiKey": "' + $keyA + '" }'), (New-Object Text.UTF8Encoding $false))
    $credDefs = @()
    $credDefs += (Get-ScriptFunctionDefinition (Join-Path $here 'WidgetConfig.ps1') 'Get-ConfigPropertyValue')
    foreach ($name in @('Test-OpenRouterCredExists', 'Get-OpenRouterKeySources', 'Read-OpenRouterAuth')) {
        $credDefs += (Get-ScriptFunctionDefinition $entry $name)
    }
    $credDefs += ('$script:OpenRouterAuthPath = ''' + $authPath + '''')
    $credDefs += ('$env:OPENROUTER_API_KEY = ''' + $keyB + '''')
    . ([ScriptBlock]::Create(($credDefs -join [Environment]::NewLine)))

    Assert-Eq (Test-OpenRouterCredExists) 'True' 'credentials are detected'
    $sources = @(Get-OpenRouterKeySources)
    Assert-Eq $sources.Count 2 'both key sources are read'
    Assert-Eq ($sources -contains $keyA) 'True' 'the auth file key is read'
    Assert-Eq ($sources -contains $keyB) 'True' 'the environment key is read'
    Assert-Eq (Read-OpenRouterAuth).ApiKey $keyA 'the auth file key wins over the environment'

    # ---------- 无凭证 ----------
    $script:OpenRouterAuthPath = Join-Path $sandbox 'nope.json'
    Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue
    $threw = $null
    try { Read-OpenRouterAuth | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-Eq $threw 'missing-credential' 'no credentials throws the missing-credential code'
    Assert-Eq (Test-OpenRouterCredExists) 'False' 'no credentials means the row is not offered'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- worker 必须带上新供应商的函数与变量 ----------
$fnNames = @()
$vNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
$match2 = [regex]::Match($entryText, '(?s)foreach \(\$v in (.*?)\) \{')
if ($match2.Success) { $vNames = @([regex]::Matches($match2.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
foreach ($name in @('Read-OpenRouterAuth', 'Get-OpenRouterRowData', 'Convert-OpenRouterCredits', 'Get-ConfigPropertyValue')) {
    Assert-Eq ($fnNames -contains $name) 'True' ('worker forwards ' + $name)
}
foreach ($name in @('OpenRouterAuthPath', 'OpenRouterApiBaseUrl', 'OpenRouterDisplayName')) {
    Assert-Eq ($vNames -contains $name) 'True' ('worker forwards ' + $name)
}
Assert-Eq ($entryText -match "'openrouter' \{ \`$d = Get-OpenRouterRowData") 'True' 'worker dispatch handles the openrouter kind'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0