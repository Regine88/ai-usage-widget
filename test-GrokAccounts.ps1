# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\test-GrokAccounts.ps1
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

$gmail = [pscustomobject]@{ Email = 'user@example.com'; KeyName = 'https://auth.x.ai::aaa' }
$edu   = [pscustomobject]@{ Email = 'student@example.org'; KeyName = 'https://auth.x.ai::bbb' }
$other = [pscustomobject]@{ Email = 'someone@example.com'; KeyName = 'https://auth.x.ai::ccc' }
$mixed = [pscustomobject]@{ Email = 'User@Example.COM'; KeyName = 'k' }
$empty = [pscustomobject]@{ Email = ''; KeyName = 'https://auth.x.ai::noid' }

Assert-Eq (Get-GrokAccountId $gmail) 'user@example.com' 'id gmail lower'
Assert-Eq (Get-GrokAccountId $mixed) 'user@example.com' 'id case-insensitive'
Assert-Eq (Get-GrokAccountId $empty) 'https://auth.x.ai::noid' 'id falls back to key'

Assert-Eq (Get-GrokAccountLabel $gmail) 'a' 'label gmail -> a'
Assert-Eq (Get-GrokAccountLabel $edu)   'b' 'label edu -> b'
Assert-Eq (Get-GrokAccountLabel $mixed) 'a' 'label case-insensitive'
Assert-Eq (Get-GrokAccountLabel $other) 'someone@example.com' 'label unknown email'
Assert-Eq (Get-GrokAccountLabel $empty) 'Grok' 'label missing email'

Assert-Eq (Get-GrokRowName $gmail) 'Grok a' 'row name a'
Assert-Eq (Get-GrokRowName $edu)   'Grok b' 'row name b'
Assert-Eq (Get-GrokRowName $other) 'Grok someone@example.com' 'row name unknown'
Assert-Eq (Get-GrokRowName $empty) 'Grok' 'row name fallback'

Assert-Eq (Get-GrokRowId $gmail) 'grok-a' 'row id a'
Assert-Eq (Get-GrokRowId $edu)   'grok-b' 'row id b'
Assert-Eq (Get-GrokRowId $other) 'grok-someone@example.com' 'row id unknown'

Assert-Eq (Get-GrokSnapshotFileName 'user@example.com') 'grok-auth-user@example.com.json' 'snapshot gmail'
Assert-Eq (Get-GrokSnapshotFileName 'a<b>|c') 'grok-auth-a_b__c.json' 'snapshot sanitizes filename'

$dir = Join-Path $env:TEMP ('grok-acct-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $script:WidgetDir = $dir
    $script:GrokAuthPath = Join-Path $dir 'live-auth.json'
    Set-Content -LiteralPath (Join-Path $dir 'grok-auth-student@example.org.json') -Value '{"https://auth.x.ai::b":{"key":"tok-b","refresh_token":"r-b","oidc_client_id":"cid","email":"student@example.org"}}' -Encoding utf8
    Set-Content -LiteralPath $script:GrokAuthPath -Value '{"https://auth.x.ai::a":{"key":"tok-a","refresh_token":"r-a","oidc_client_id":"cid","email":"user@example.com"}}' -Encoding utf8

    $accounts = @(Get-GrokAccounts)
    Assert-Eq $accounts.Count 2 'discovers snapshot + live'
    Assert-Eq $accounts[0].Email 'user@example.com' 'sort a first'
    Assert-Eq $accounts[1].Email 'student@example.org' 'sort b second'
    Assert-Eq $accounts[0].Path $script:GrokAuthPath 'live account uses CLI auth path'
    Assert-Eq $accounts[1].Path (Join-Path $dir 'grok-auth-student@example.org.json') 'b uses snapshot path'

    Sync-ActiveGrokSnapshot
    $snapA = Join-Path $dir 'grok-auth-user@example.com.json'
    Assert-Eq (Test-Path -LiteralPath $snapA) 'True' 'auto-snapshot live gmail'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
