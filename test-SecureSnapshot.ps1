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

    $jsonPath = Join-Path $root 'plain-auth.json'
    [IO.File]::WriteAllText($jsonPath, '{"keep":"yes","token":"old"}', [Text.UTF8Encoding]::new($false))
    $plain = Update-JsonFile -Path $jsonPath -Update {
        param($current)
        $current.token = 'new'
        return $current
    }
    Assert-Eq $plain.keep 'yes' 'plain JSON update keeps unrelated fields'
    Assert-Eq $plain.token 'new' 'plain JSON update changes the target field'
    Assert-Eq ((Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).keep) 'yes' 'plain JSON update persists unrelated fields'
    Assert-Eq (@(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -File).Count) '0' 'plain JSON update leaves no temp file'

    $files = @(Get-SecureSnapshotFiles -Provider codex -Root $root)
    Assert-Eq $files.Count '1' 'snapshot enumeration'
    [void](Write-SecureSnapshot -Provider gemini -AccountId 'kept' -Value ([pscustomobject]@{ AccountId = 'kept' }) -Root $root)
    $active = [pscustomobject]@{ AccountId = 'active'; Token = 'live' }
    $merged = @(Get-MergedProviderAccounts -Provider gemini -Active $active -Root $root -ReadPath {
        param($Path)
        $raw = Read-SecureSnapshot -Path $Path
        [pscustomobject]@{ AccountId = [string]$raw.AccountId }
    })
    Assert-Eq $merged.Count '2' 'active account and snapshot stay distinct'
    Assert-Eq $merged[0].AccountId 'active' 'the live account stays ahead of snapshots'
    $replaced = @(Get-MergedProviderAccounts -Provider gemini -Active ([pscustomobject]@{ AccountId = 'kept'; Token = 'live' }) -Root $root -ReadPath {
        param($Path)
        $raw = Read-SecureSnapshot -Path $Path
        [pscustomobject]@{ AccountId = [string]$raw.AccountId; Token = 'snapshot' }
    })
    Assert-Eq $replaced.Count '1' 'the live account replaces its own snapshot'
    Assert-Eq $replaced[0].Token 'live' 'the live credential wins over the stored copy'
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
