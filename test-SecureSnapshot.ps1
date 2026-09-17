# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'SecureSnapshot.ps1')

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

$root = Join-Path $env:TEMP ('ai-secure-snapshot-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $value = [pscustomobject]@{ accountId = 'account-a'; token = 'secret-value'; nested = [pscustomobject]@{ enabled = $true } }
    $path = Write-SecureSnapshot -Provider codex -AccountId 'account-a' -Value $value -Root $root
    Assert-Eq (Test-Path -LiteralPath $path) 'True' 'snapshot file created'
    Assert-Eq (Get-Content -LiteralPath $path -Raw).Contains('secret-value') 'False' 'snapshot is not plaintext'
    $roundTrip = Read-SecureSnapshot -Path $path
    Assert-Eq $roundTrip.accountId 'account-a' 'account id round trip'
    Assert-Eq $roundTrip.nested.enabled 'True' 'nested value round trip'
    $updated = [pscustomobject]@{ accountId = 'account-a'; token = 'updated-secret'; nested = [pscustomobject]@{ enabled = $false } }
    [void](Write-SecureSnapshot -Provider codex -AccountId 'account-a' -Value $updated -Root $root)
    $roundTrip2 = Read-SecureSnapshot -Path $path
    Assert-Eq $roundTrip2.token 'updated-secret' 'snapshot overwrite'
    Assert-Eq $roundTrip2.nested.enabled 'False' 'snapshot overwrite nested value'
    [void](Update-SecureSnapshot -Provider codex -AccountId 'account-a' -Root $root -Update {
        param($current)
        [void]($current.token = 'callback-secret')
        return $current
    })
    $roundTrip3 = Read-SecureSnapshot -Path $path
    Assert-Eq $roundTrip3.token 'callback-secret' 'locked snapshot update'
    $files = @(Get-SecureSnapshotFiles -Provider codex -Root $root)
    Assert-Eq $files.Count '1' 'snapshot enumeration'
    Remove-SecureSnapshot -Path $path
    Assert-Eq (Test-Path -LiteralPath $path) 'False' 'snapshot removal'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
