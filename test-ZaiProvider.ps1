# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ZaiProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetConfig.ps1')
. (Join-Path $here 'ApiKeyAuth.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
. (Join-Path $here 'ZaiQuota.ps1')

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
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return $fn.Extent.Text }
    }
    throw ('function not found: ' + $Name)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8
$script:Language = 'en-US'
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
$script:payload = $null
$script:seenUri = ''
$script:seenAuth = ''
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $script:seenUri = $Uri
    $script:seenAuth = $Headers['Authorization']
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) }

$definitions = @()
foreach ($name in @('Get-ZaiZcodeKey', 'Resolve-ZaiCredential', 'Test-ZaiCredExists', 'Get-ZaiAuthHeaders', 'Get-ZaiUsageSnapshot', 'Get-ZaiRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:ZaiAuthPath = ''no-such-zai.json'''
$definitions += '$script:ZhipuAuthPath = ''no-such-zhipu.json'''
$definitions += '$script:BigModelAuthPath = ''no-such-bigmodel.json'''
$definitions += '$script:ZcodeConfigPath = ''no-such-zcode-config.json'''
$definitions += '$script:ZaiApiBaseUrl = ''https://api.z.ai'''
$definitions += '$script:ZhipuApiBaseUrl = ''https://open.bigmodel.cn'''
$definitions += '$script:ZaiDisplayName = ''GLM'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

# 环境变量优先级最高，先清空，免得开发机上的真实密钥影响断言。
$savedZai = $env:ZAI_API_KEY
$savedZhipu = $env:ZHIPU_API_KEY
$savedBigModel = $env:BIGMODEL_API_KEY
$env:ZAI_API_KEY = ''
$env:ZHIPU_API_KEY = ''
$env:BIGMODEL_API_KEY = ''
try {
    Assert-Eq (Test-ZaiCredExists) 'False' 'no credential source means no row'

    $env:BIGMODEL_API_KEY = 'env-bigmodel-key'
    $credential = Resolve-ZaiCredential
    Assert-Eq $credential.Key 'env-bigmodel-key' 'BIGMODEL_API_KEY is used'
    Assert-Eq $credential.BaseUrl 'https://open.bigmodel.cn' 'bigmodel keys use the China host'
    $env:BIGMODEL_API_KEY = ''

    # ZCode 的配置藏在 provider.<id>.options.apiKey，用临时配置文件验证解析链路。
    $dir = Join-Path $env:TEMP ('zai-provider-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $configPath = Join-Path $dir 'config.json'
        $json = '{ "provider": { "builtin:bigmodel-coding-plan": { "options": { "apiKey": "zcode-key" } } } }'
        [IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
        $script:ZcodeConfigPath = $configPath
        Assert-Eq (Test-ZaiCredExists) 'True' 'the ZCode config counts as a credential'
        $credential = Resolve-ZaiCredential
        Assert-Eq $credential.Key 'zcode-key' 'the ZCode key is used'
        Assert-Eq $credential.BaseUrl 'https://open.bigmodel.cn' 'the ZCode key uses the China host'
        $script:payload = '{"data":{"limits":[{"type":"TOKENS_FIVE_HOURS","percentage":5}]}}' | ConvertFrom-Json
        $row = Get-ZaiRowData -Auth $null -Name 'GLM'
        Assert-Eq $script:seenUri 'https://open.bigmodel.cn/api/monitor/usage/quota/limit' 'the ZCode credential hits the China endpoint'
        Assert-Eq $row.Percent '5' 'the ZCode credential still parses the quota'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:ZAI_API_KEY = $savedZai
    $env:ZHIPU_API_KEY = $savedZhipu
    $env:BIGMODEL_API_KEY = $savedBigModel
}

$script:payload = '{"data":{"level":"pro","limits":[{"type":"TOKENS_FIVE_HOURS","percentage":8},{"type":"TOKENS_SEVEN_DAYS","percentage":22}]}}' | ConvertFrom-Json
$row = Get-ZaiRowData -Auth ([pscustomobject]@{ ApiKey = 'zai-test-key' }) -Name 'GLM'
Assert-Eq $script:seenUri 'https://api.z.ai/api/monitor/usage/quota/limit' 'glm hits the monitor quota endpoint'
Assert-Eq $script:seenAuth 'zai-test-key' 'glm sends the raw key without Bearer'
Assert-Eq $row.Percent '22' 'glm percent follows the tighter window'
Assert-Eq ($row.Detail -like 'pro*') 'True' 'glm detail includes the plan level'

$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Get-ZaiRowData') 'True' 'worker forwards Get-ZaiRowData'
Assert-Eq ($entryText -match "'glm' \{ \`$d = Get-ZaiRowData") 'True' 'worker dispatch handles glm'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
