# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-GrokAccounts.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'GrokAccounts.ps1')

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

# 占位邮箱：真实账号标识只留在本机，仓库与测试里不出现
$aliceEmail = 'alice@example.com'
$bobEmail = 'bob@example.org'
$aliceFp = Get-AccountFingerprint -AccountId $aliceEmail -Prefix 'Grok'
$bobFp = Get-AccountFingerprint -AccountId $bobEmail -Prefix 'Grok'
$otherFp = Get-AccountFingerprint -AccountId 'someone@example.com' -Prefix 'Grok'

$alice = [pscustomobject]@{ Email = $aliceEmail; KeyName = 'https://auth.x.ai::aaa' }
$bob = [pscustomobject]@{ Email = $bobEmail; KeyName = 'https://auth.x.ai::bbb' }
$other = [pscustomobject]@{ Email = 'someone@example.com'; KeyName = 'https://auth.x.ai::ccc' }
$mixed = [pscustomobject]@{ Email = 'Alice@Example.COM'; KeyName = 'k' }
$empty = [pscustomobject]@{ Email = ''; KeyName = 'https://auth.x.ai::noid' }

Assert-Eq (Get-GrokAccountId $alice) $aliceEmail 'id gmail lower'
Assert-Eq (Get-GrokAccountId $mixed) $aliceEmail 'id case-insensitive'
Assert-Eq (Get-GrokAccountId $empty) 'https://auth.x.ai::noid' 'id falls back to key'

# 没有别名时行名与行 id 都退化为指纹，仓库源码里没有任何账号硬编码
$script:GrokAccountAliases = @{}
Assert-Eq (Get-GrokAccountLabel $alice) $aliceFp 'label without alias is fingerprint'
Assert-Eq (Get-GrokRowName $alice) $aliceFp 'row name without alias keeps a single prefix'
Assert-Eq (Get-GrokRowName $other) $otherFp 'row name without alias is fingerprint'
Assert-Eq ((Get-GrokRowId $other) -like 'grok-acct-????????') 'True' 'row id without alias is acct fingerprint'

# 进程内别名映射
$script:GrokAccountAliases = @{ $aliceFp = 'a'; $bobFp = 'b' }
Assert-Eq (Get-GrokAccountLabel $alice) 'a' 'label mapped to a'
Assert-Eq (Get-GrokAccountLabel $bob) 'b' 'label mapped to b'
Assert-Eq (Get-GrokAccountLabel $mixed) 'a' 'label mapping is case-insensitive'
Assert-Eq ((Get-GrokAccountLabel $other) -like 'Grok-????????') 'True' 'label unknown email is fingerprint'
Assert-Eq (Get-GrokAccountLabel $empty) 'Grok' 'label missing email'

Assert-Eq (Get-GrokRowName $alice) 'Grok a' 'row name a'
Assert-Eq (Get-GrokRowName $bob) 'Grok b' 'row name b'
Assert-Eq (Get-GrokRowName $empty) 'Grok' 'row name fallback'

Assert-Eq ((Get-GrokRowId $alice) -like 'grok-acct-????????') 'True' 'row id a ignores the display alias'
Assert-Eq ((Get-GrokRowId $bob) -like 'grok-acct-????????') 'True' 'row id b ignores the display alias'
Assert-Eq ((Get-GrokRowId $alice) -ne (Get-GrokRowId $bob)) 'True' 'different aliases keep different stable row ids'

Assert-Eq (Get-GrokSnapshotFileName $aliceEmail) ('grok-auth-{0}.json' -f $aliceEmail) 'snapshot name follows account id'
Assert-Eq (Get-GrokSnapshotFileName 'a<b>|c') 'grok-auth-a_b__c.json' 'snapshot sanitizes filename'

$dir = Join-Path $env:TEMP ('grok-acct-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    # 别名文件只在本机存在：.gitignore 已排除，缺失时回退到指纹
    $script:GrokAccountAliases = @{}
    $script:WidgetDir = $dir
    $script:SecureSnapshotRoot = Join-Path $dir 'secure'
    $script:GrokAuthPath = Join-Path $dir 'live-auth.json'
    $aliasPath = Join-Path $dir 'grok-aliases.json'
    $aliasJson = @{ $aliceFp = 'a'; $bobFp = 'b' } | ConvertTo-Json -Compress

    Set-Content -LiteralPath $aliasPath -Value $aliasJson -Encoding utf8
    Assert-Eq (Get-GrokAccountLabel $alice) 'a' 'alias file drives label'
    Assert-Eq (Get-GrokRowName $bob) 'Grok b' 'alias file drives row name'
    Remove-Item -LiteralPath $aliasPath -Force
    Assert-Eq ((Get-GrokAccountLabel $alice) -like 'Grok-????????') 'True' 'missing alias file falls back to fingerprint'

    Set-Content -LiteralPath $aliasPath -Value $aliasJson -Encoding utf8
    $bobJson = @{ 'https://auth.x.ai::b' = @{ key = 'tok-b'; refresh_token = 'r-b'; oidc_client_id = 'cid'; email = $bobEmail } } | ConvertTo-Json -Depth 6 -Compress
    $aliceJson = @{ 'https://auth.x.ai::a' = @{ key = 'tok-a'; refresh_token = 'r-a'; oidc_client_id = 'cid'; email = $aliceEmail } } | ConvertTo-Json -Depth 6 -Compress
    Set-Content -LiteralPath (Join-Path $dir ('grok-auth-{0}.json' -f $bobEmail)) -Value $bobJson -Encoding utf8
    Set-Content -LiteralPath $script:GrokAuthPath -Value $aliceJson -Encoding utf8

    $accounts = @(Get-GrokAccounts)
    Assert-Eq $accounts.Count 2 'discovers snapshot + live'
    Assert-Eq $accounts[0].Email $aliceEmail 'sort a first'
    Assert-Eq $accounts[1].Email $bobEmail 'sort b second'
    Assert-Eq $accounts[0].Path $script:GrokAuthPath 'live account uses CLI auth path'
    Assert-Eq ($accounts[1].Path -like (Join-Path $dir 'secure\grok-*.snapshot')) 'True' 'b uses protected snapshot path'

    Sync-ActiveGrokSnapshot
    $snapA = Join-Path $dir ('grok-auth-{0}.json' -f $aliceEmail)
    Assert-Eq (Test-Path -LiteralPath $snapA) 'False' 'legacy plaintext snapshot removed'
    Assert-Eq (@(Get-SecureSnapshotFiles -Provider grok -Root $script:SecureSnapshotRoot).Count) '2' 'protected snapshots retained'
} finally {
    $script:SecureSnapshotRoot = $null
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
