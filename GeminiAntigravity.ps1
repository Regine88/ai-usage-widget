# Antigravity Gemini quota helpers. Tokens live in Windows Credential
# Manager target "gemini:antigravity" (same store Antigravity uses).

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}
if (-not (Get-Command Get-SecureSnapshotPath -ErrorAction SilentlyContinue)) {
    $snapshotHelper = Join-Path $PSScriptRoot 'SecureSnapshot.ps1'
    if (Test-Path -LiteralPath $snapshotHelper) { . $snapshotHelper }
}

$script:AntigravityCredTarget = 'gemini:antigravity'
$script:AntigravityClientId = '1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com'
$script:AntigravityClientSecret = $env:ANTIGRAVITY_CLIENT_SECRET
$script:AntigravityTokenUrl = 'https://oauth2.googleapis.com/token'
$script:AntigravityQuotaUrl = 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary'
$script:GeminiUsagePageUrl = 'https://one.google.com/ai'

function Ensure-AntigravityCredType {
    if ('NativeAgCred' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeAgCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr cred);
    public static byte[] ReadBlob(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlob == IntPtr.Zero || c.CredentialBlobSize <= 0) return new byte[0];
            byte[] b = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, b, 0, c.CredentialBlobSize);
            return b;
        } finally { CredFree(p); }
    }
    public static void WriteBlob(string target, string userName, byte[] blob, int persist) {
        IntPtr blobPtr = Marshal.AllocHGlobal(blob.Length);
        try {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);
            CREDENTIAL c = new CREDENTIAL();
            c.Type = 1;
            c.TargetName = Marshal.StringToCoTaskMemUni(target);
            c.UserName = Marshal.StringToCoTaskMemUni(userName);
            c.CredentialBlobSize = blob.Length;
            c.CredentialBlob = blobPtr;
            c.Persist = persist;
            try {
                if (!CredWrite(ref c, 0)) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
            } finally {
                if (c.TargetName != IntPtr.Zero) Marshal.FreeCoTaskMem(c.TargetName);
                if (c.UserName != IntPtr.Zero) Marshal.FreeCoTaskMem(c.UserName);
            }
        } finally {
            Marshal.FreeHGlobal(blobPtr);
        }
    }
}
"@
}

function Test-AntigravityCredExists {
    try {
        Ensure-AntigravityCredType
        $blob = [NativeAgCred]::ReadBlob($script:AntigravityCredTarget)
        return ($blob -and $blob.Length -gt 0)
    } catch {
        return $false
    }
}

function Get-GeminiPropertyText {
    param($Object, [string]$Name)
    if (-not $Object -or -not $Name) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return $null }
    $text = ([string]$prop.Value).Trim()
    if (-not $text) { return $null }
    return $text
}

function Get-GeminiJwtEmail {
    param([string]$Jwt)
    if (-not $Jwt -or $Jwt -notmatch '\.') { return $null }
    try {
        $payload = $Jwt.Split('.')[1]
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $pad = (4 - ($payload.Length % 4)) % 4
        if ($pad -gt 0) { $payload += ('=' * $pad) }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        return (Get-GeminiPropertyText $claims 'email')
    } catch {
        return $null
    }
}

function Get-GeminiAccountId {
    param($Raw)
    if (-not $Raw) { return $null }
    $email = Get-GeminiPropertyText $Raw 'email'
    if (-not $email -and $Raw.user) { $email = Get-GeminiPropertyText $Raw.user 'email' }
    if (-not $email -and $Raw.account) { $email = Get-GeminiPropertyText $Raw.account 'email' }
    if (-not $email -and $Raw.token) { $email = Get-GeminiPropertyText $Raw.token 'email' }
    if (-not $email -and $Raw.token) { $email = Get-GeminiJwtEmail ([string]$Raw.token.id_token) }
    if ($email) { return $email.Trim().ToLowerInvariant() }
    $project = Get-GeminiPropertyText $Raw 'project_id'
    if (-not $project) { $project = Get-GeminiPropertyText $Raw 'projectId' }
    if ($project) { return ('project:' + $project) }
    $refresh = $null
    if ($Raw.token) { $refresh = Get-GeminiPropertyText $Raw.token 'refresh_token' }
    if ($refresh) { return ('refresh:' + (Get-AccountFingerprint -AccountId $refresh -Prefix 'tok')) }
    return $null
}

function Convert-GeminiRawAuth {
    param(
        $Raw,
        [string]$Path,
        [string]$Source = 'credential'
    )
    if (-not $Raw -or -not $Raw.token -or -not $Raw.token.refresh_token) { throw 'missing-credential' }
    $exp = $null
    if ($Raw.token.expiry) {
        try { $exp = [datetime]::Parse([string]$Raw.token.expiry, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    $accountId = Get-GeminiAccountId $Raw
    if (-not $accountId) { throw 'missing-credential' }
    $authObject = [pscustomobject]@{
        AccessToken  = [string]$Raw.token.access_token
        RefreshToken = [string]$Raw.token.refresh_token
        ExpiresAt    = $exp
        AccountId    = $accountId
        Path         = $Path
        Source       = $Source
        Raw          = $Raw
    }
    return (Set-CredentialVersion -Auth $authObject -AccessToken $authObject.AccessToken -RefreshToken $authObject.RefreshToken -AccountId $accountId)
}

function Read-AntigravityCred {
    Ensure-AntigravityCredType
    $blob = [NativeAgCred]::ReadBlob($script:AntigravityCredTarget)
    if (-not $blob -or $blob.Length -eq 0) { throw 'missing-credential' }
    $raw = [Text.Encoding]::UTF8.GetString($blob) | ConvertFrom-Json
    return (Convert-GeminiRawAuth -Raw $raw -Path $script:AntigravityCredTarget -Source 'credential')
}

function Read-GeminiSnapshot {
    param([string]$Path)
    if (-not $Path) { throw 'missing-credential' }
    $raw = Read-SecureSnapshot -Path $Path
    return (Convert-GeminiRawAuth -Raw $raw -Path $Path -Source 'snapshot')
}

function Get-GeminiRowId {
    param($Auth)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'acct'
    if ($fingerprint) { return ('gemini-{0}' -f $fingerprint) }
    return 'gemini-unknown'
}

function Get-GeminiRowName {
    param($Auth)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'Gemini'
    if ($fingerprint) { return $fingerprint }
    return 'Gemini'
}

function Get-GeminiAccounts {
    $active = $null
    try {
        if (Test-AntigravityCredExists) { $active = Read-AntigravityCred }
    } catch {
        $active = $null
    }
    return @(Get-MergedProviderAccounts -Provider gemini -Active $active -ReadPath {
        param($Path)
        Read-GeminiSnapshot -Path $Path
    })
}

function Test-GeminiCredExists {
    try { return (@(Get-GeminiAccounts).Count -gt 0) } catch { return $false }
}

function Sync-ActiveGeminiSnapshot {
    $active = $null
    try {
        if (Test-AntigravityCredExists) { $active = Read-AntigravityCred }
    } catch {
        return
    }
    if (-not $active -or -not $active.AccountId -or -not $active.Raw) { return }
    [void](Write-SecureSnapshot -Provider gemini -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentGeminiAccount {
    $active = $null
    try {
        if (Test-AntigravityCredExists) { $active = Read-AntigravityCred }
    } catch { }
    if (-not $active -or -not $active.AccountId -or -not $active.Raw) {
        Write-Host (T 'cli.geminiAuthMissing')
        return [pscustomobject]@{ Status = 'missing'; Name = $null; Path = $null }
    }
    $name = Get-GeminiRowName $active
    $snapPath = Get-SecureSnapshotPath -Provider gemini -AccountId $active.AccountId
    $existed = Test-Path -LiteralPath $snapPath
    [void](Write-SecureSnapshot -Provider gemini -AccountId $active.AccountId -Value $active.Raw)
    $status = if ($existed) { 'same-account' } else { 'registered' }
    Write-Host (T 'cli.registered' @($name, $snapPath))
    if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
        Write-WidgetLog ("snapshot gemini {0} status={1}" -f $name, $status)
    }
    return [pscustomobject]@{ Status = $status; Name = $name; Path = $snapPath }
}

function Set-GeminiAuthFields {
    param($Raw, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    if (-not $Raw -or -not $Raw.token) { throw 'Gemini credential is missing token' }
    $Raw.token.access_token = $AccessToken
    if ($RefreshToken) { $Raw.token.refresh_token = $RefreshToken }
    if ($ExpiresAt) { $Raw.token.expiry = $ExpiresAt.ToString('o') }
    return $Raw
}

function Save-GeminiSnapshot {
    param($Auth)
    if (-not $Auth -or -not $Auth.AccountId) { throw 'Gemini snapshot is missing an account id' }
    $path = Get-SecureSnapshotPath -Provider gemini -AccountId $Auth.AccountId
    if (Test-Path -LiteralPath $path) {
        try {
            $updated = Update-SecureSnapshot -Provider gemini -AccountId $Auth.AccountId -Update {
                param($current)
                $currentAuth = Convert-GeminiRawAuth -Raw $current -Path $path -Source 'snapshot'
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                return (Set-GeminiAuthFields -Raw $current -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
            }
        } catch {
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('gemini snapshot is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return $Auth.Raw
            }
            throw
        }
    } else {
        $updated = Set-GeminiAuthFields -Raw $Auth.Raw -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt
        [void](Write-SecureSnapshot -Provider gemini -AccountId $Auth.AccountId -Value $updated)
    }
    $Auth.Raw = $updated
    return $updated
}

function Save-GeminiAuth {
    param($Auth)
    if (-not $Auth -or -not $Auth.Raw) { return }
    $source = [string]$Auth.Source
    if (-not $source) {
        if ([string]$Auth.Path -like '*.snapshot') { $source = 'snapshot' } else { $source = 'credential' }
    }
    if ($source -eq 'snapshot') {
        [void](Save-GeminiSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        return
    }
    try {
        Invoke-SecureSnapshotFileLock -Path ('credential:' + $script:AntigravityCredTarget) -Action {
            $current = Read-AntigravityCred
            Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $current.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $current.RefreshToken
            $current.AccessToken = $Auth.AccessToken
            $current.RefreshToken = $Auth.RefreshToken
            $current.ExpiresAt = $Auth.ExpiresAt
            $current.Raw = Set-GeminiAuthFields -Raw $current.Raw -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt
            Save-AntigravityCred $current
            $Auth.Raw = $current.Raw
        }
    } catch {
        if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
        if (Test-CredentialStale $_) {
            Write-WidgetLog ('gemini active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
            return
        }
        $Auth.Raw = Set-GeminiAuthFields -Raw $Auth.Raw -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt
        $Auth.Path = Get-SecureSnapshotPath -Provider gemini -AccountId $Auth.AccountId
        $Auth.Source = 'snapshot'
        [void](Save-GeminiSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        Write-WidgetLog ('gemini active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        return
    }
    if ($Auth.AccountId -and $Auth.Raw) { [void](Save-GeminiSnapshot $Auth) }
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
}

function Save-AntigravityCred {
    param($Auth)
    Ensure-AntigravityCredType
    $raw = $Auth.Raw
    $raw.token.access_token = $Auth.AccessToken
    if ($Auth.RefreshToken) { $raw.token.refresh_token = $Auth.RefreshToken }
    if ($Auth.ExpiresAt) { $raw.token.expiry = $Auth.ExpiresAt.ToString('o') }
    $json = $raw | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    [NativeAgCred]::WriteBlob($script:AntigravityCredTarget, 'antigravity', $bytes, 2)
}

function Update-AntigravityToken {
    param($Auth)
    if (-not $script:AntigravityClientSecret) { throw 'missing-secret' }
    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $Auth.RefreshToken
        client_id     = $script:AntigravityClientId
        client_secret = $script:AntigravityClientSecret
    }
    $resp = Invoke-WidgetRest -Method Post -Uri $script:AntigravityTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) { throw 'token-refresh' }
    $Auth.AccessToken = [string]$resp.access_token
    if ($resp.refresh_token) { $Auth.RefreshToken = [string]$resp.refresh_token }
    $expiresIn = Assert-PositiveFiniteNumber $resp.expires_in 'Gemini expires_in'
    $Auth.ExpiresAt = [datetime]::UtcNow.AddSeconds($expiresIn)
    try {
        Save-GeminiAuth $Auth
    } catch {
        if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
            Write-WidgetLog ("gemini credential save failed: {0}" -f (Convert-SafeLogText $_.Exception.Message))
        }
        throw
    }
    if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
        Write-WidgetLog 'gemini token refreshed'
    }
    return $Auth
}

function Get-AntigravityAuth {
    param($Auth)
    if (-not $Auth) { $Auth = Read-AntigravityCred }
    $needRefresh = $true
    if ($Auth.ExpiresAt) {
        $needRefresh = ($Auth.ExpiresAt.ToUniversalTime() -lt [datetime]::UtcNow.AddMinutes(2))
    }
    if ($needRefresh -or -not $Auth.AccessToken) {
        $Auth = Update-AntigravityToken $Auth
    }
    return $Auth
}

function Convert-GeminiQuota {
    param($Data)
    $group = $null
    foreach ($g in @($Data.groups)) {
        $name = [string]$g.displayName
        if ($name -match 'Gemini') { $group = $g; break }
    }
    if (-not $group) { throw 'bad-payload' }
    $remain5h = $null
    $remainWeek = $null
    $reset5h = $null
    $resetWeek = $null
    foreach ($b in @($group.buckets)) {
        $id = ([string]$b.bucketId + ' ' + [string]$b.window).ToLowerInvariant()
        $isFiveHour = $id -match '5h|five'
        $isWeekly = $id -match 'week'
        if (-not $isFiveHour -and -not $isWeekly) { continue }
        if ($null -eq $b.remainingFraction -or -not (Test-FiniteNumber $b.remainingFraction)) { throw 'bad-payload' }
        $frac = [double]$b.remainingFraction
        if ($frac -gt 1.0) { $frac = $frac / 100.0 }
        if ($frac -lt 0.0 -or $frac -gt 1.0) { throw 'bad-payload' }
        $pct = Assert-UsagePercent ([Math]::Round($frac * 100.0, 1)) 'Gemini remaining percent'
        $reset = $null
        if ($b.resetTime) {
            try { $reset = [datetime]::Parse([string]$b.resetTime, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }
        if ($isFiveHour) {
            $remain5h = $pct
            $reset5h = $reset
        } elseif ($id -match 'week') {
            $remainWeek = $pct
            $resetWeek = $reset
        }
    }
    if ($null -eq $remain5h -and $null -eq $remainWeek) { throw 'bad-payload' }
    $remaining = if ($null -ne $remain5h -and $null -ne $remainWeek) {
        [Math]::Min($remain5h, $remainWeek)
    } elseif ($null -ne $remain5h) { $remain5h } else { $remainWeek }
    $periodEnd = $resetWeek
    if ($null -ne $remain5h -and $remain5h -le $remainWeek) { $periodEnd = $reset5h }
    if (-not $periodEnd) { $periodEnd = $reset5h }
    if (-not $periodEnd) { $periodEnd = $resetWeek }
    [pscustomobject]@{
        Remaining     = [double]$remaining
        Used          = [Math]::Round(100.0 - [double]$remaining, 1)
        Remain5h      = $remain5h
        RemainWeekly  = $remainWeek
        PeriodEnd     = $periodEnd
        Reset5h       = $reset5h
        ResetWeekly   = $resetWeek
    }
}

function Invoke-AntigravityQuota {
    param($Auth)
    $headers = @{
        Authorization = "Bearer $($Auth.AccessToken)"
        'User-Agent'  = 'antigravity'
        Accept        = 'application/json'
    }
    try {
        return Invoke-WidgetRest -Method Post -Uri $script:AntigravityQuotaUrl -Headers $headers -Body '{}' -ContentType 'application/json'
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -notin 401, 403) { throw }
        $Auth = Update-AntigravityToken $Auth
        $headers.Authorization = "Bearer $($Auth.AccessToken)"
        return Invoke-WidgetRest -Method Post -Uri $script:AntigravityQuotaUrl -Headers $headers -Body '{}' -ContentType 'application/json'
    }
}

function Get-GeminiUsageSnapshot {
    param($Auth)
    $auth = Get-AntigravityAuth -Auth $Auth
    $data = Invoke-AntigravityQuota $auth
    Convert-GeminiQuota $data
}
