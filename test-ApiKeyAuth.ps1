# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ApiKeyAuth.ps1
# 共享的 API key 读取：文件优先、环境变量兜底、坏文件不炸、请求头与 URL 拼接。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetConfig.ps1')
. (Join-Path $here 'ApiKeyAuth.ps1')

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

$sandbox = Join-Path $env:TEMP ('apikeyauth-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    $authPath = Join-Path $sandbox 'auth.json'
    $keyA = 'sk-' + ('a' * 32)
    $keyB = 'sk-' + ('b' * 32)
    $utf8 = New-Object Text.UTF8Encoding $false

    # ---------- 无凭证 ----------
    Assert-Eq (Test-ApiKeyCredExists -AuthPath $authPath -EnvironmentValue '') 'False' 'a missing file and empty env means no credential'
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '').Count) 0 'no sources without credentials'
    Assert-Eq (@(Get-ApiKeyFileSources -Path $authPath).Count) 0 'a missing file yields no keys'
    $threw = $null
    try { Read-ApiKeyAuth -AuthPath $authPath -EnvironmentValue '' | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-Eq $threw 'missing-credential' 'reading without credentials throws the shared code'

    # ---------- 文件来源 ----------
    [IO.File]::WriteAllText($authPath, ('{ "apiKey": "' + $keyA + '" }'), $utf8)
    Assert-Eq (Test-ApiKeyCredExists -AuthPath $authPath -EnvironmentValue '') 'True' 'the auth file counts as a credential'
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '')[0]) $keyA 'the file key is read'
    Assert-Eq (Read-ApiKeyAuth -AuthPath $authPath -EnvironmentValue '').ApiKey $keyA 'the file key is used'

    foreach ($name in @('apiKey', 'api_key', 'key', 'token')) {
        [IO.File]::WriteAllText($authPath, ('{ "' + $name + '": "' + $keyA + '" }'), $utf8)
        Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '').Count) 1 ('"' + $name + '" is a known key name')
    }

    # ---------- 环境变量兜底 ----------
    [IO.File]::WriteAllText($authPath, '{ "apiKey": "" }', $utf8)
    Assert-Eq (Test-ApiKeyCredExists -AuthPath $authPath -EnvironmentValue $keyB) 'True' 'the environment variable is a credential'
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue $keyB).Count) 1 'an empty file value falls back to the environment'
    Assert-Eq (Read-ApiKeyAuth -AuthPath $authPath -EnvironmentValue $keyB).ApiKey $keyB 'the environment key is used'
    Assert-Eq (Read-ApiKeyAuth -AuthPath $authPath -EnvironmentValue $keyB).ApiKeyCount 1 'one credential is reported'

    # ---------- 优先级与去重 ----------
    [IO.File]::WriteAllText($authPath, ('{ "key": "' + $keyA + '" }'), $utf8)
    $auth = Read-ApiKeyAuth -AuthPath $authPath -EnvironmentValue $keyB
    Assert-Eq $auth.ApiKey $keyA 'the file wins over the environment'
    Assert-Eq $auth.ApiKeyCount 2 'both sources are reported'
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue $keyA).Count) 1 'the same key in both sources is collapsed'

    # ---------- 坏文件 ----------
    [IO.File]::WriteAllText($authPath, '{ not json', $utf8)
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '').Count) 0 'a broken file is ignored'
    Assert-Eq (Test-ApiKeyCredExists -AuthPath $authPath -EnvironmentValue '') 'True' 'a broken file is still a credential source'
    [IO.File]::WriteAllText($authPath, '{ "apiKey": null }', $utf8)
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '').Count) 0 'a null key is ignored'
    [IO.File]::WriteAllText($authPath, '{ "apiKey": "   " }', $utf8)
    Assert-Eq (@(Get-ApiKeySources -AuthPath $authPath -EnvironmentValue '').Count) 1 'a blank key is passed through for the caller to reject'

    # ---------- 请求头与 URL ----------
    $headers = Get-ApiKeyAuthHeaders ([pscustomobject]@{ ApiKey = $keyA })
    Assert-Eq $headers.Authorization ('Bearer ' + $keyA) 'the header carries the bearer token'
    Assert-Eq $headers.Accept 'application/json' 'the header asks for json'
    Assert-Eq $headers['User-Agent'] 'ai-usage-widget' 'the header identifies the widget'

    $script:seenUri = ''
    $script:seenHeaders = $null
    function Invoke-WidgetRest {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $script:seenUri = $Uri
        $script:seenHeaders = $Headers
        return 'payload'
    }
    $result = Invoke-ApiKeyGet -Auth ([pscustomobject]@{ ApiKey = $keyA }) -BaseUrl 'https://example.test/api/v1' -Path '/probe'
    Assert-Eq $result 'payload' 'the payload is returned untouched'
    Assert-Eq $script:seenUri 'https://example.test/api/v1/probe' 'the base url and path are joined'
    Assert-Eq $script:seenHeaders.Authorization ('Bearer ' + $keyA) 'the GET carries the bearer token'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0