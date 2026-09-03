# Antigravity Gemini quota helpers. Tokens live in Windows Credential
# Manager target "gemini:antigravity" (same store Antigravity uses).

$script:AntigravityCredTarget = 'gemini:antigravity'
$script:AntigravityClientId = '1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com'
$script:AntigravityClientSecret = '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'
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

function Read-AntigravityCred {
    Ensure-AntigravityCredType
    $blob = [NativeAgCred]::ReadBlob($script:AntigravityCredTarget)
    if (-not $blob -or $blob.Length -eq 0) { throw '未找到 Antigravity 登录，请先在 Antigravity 中登录 Google 账号' }
    $raw = [Text.Encoding]::UTF8.GetString($blob) | ConvertFrom-Json
    if (-not $raw.token -or -not $raw.token.refresh_token) {
        throw 'Antigravity 凭据不完整，请重新登录'
    }
    $exp = $null
    if ($raw.token.expiry) {
        try { $exp = [datetime]::Parse([string]$raw.token.expiry, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    [pscustomobject]@{
        AccessToken  = [string]$raw.token.access_token
        RefreshToken = [string]$raw.token.refresh_token
        ExpiresAt    = $exp
        Raw          = $raw
    }
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
    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $Auth.RefreshToken
        client_id     = $script:AntigravityClientId
        client_secret = $script:AntigravityClientSecret
    }
    $resp = Invoke-WidgetRest -Method Post -Uri $script:AntigravityTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) { throw '刷新 Gemini 登录失败，请打开 Antigravity 重新登录' }
    $Auth.AccessToken = [string]$resp.access_token
    if ($resp.refresh_token) { $Auth.RefreshToken = [string]$resp.refresh_token }
    $Auth.ExpiresAt = [datetime]::UtcNow.AddSeconds([int]$resp.expires_in)
    try { Save-AntigravityCred $Auth } catch { }
    if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
        Write-WidgetLog 'gemini token refreshed'
    }
    return $Auth
}

function Get-AntigravityAuth {
    $auth = Read-AntigravityCred
    $needRefresh = $true
    if ($auth.ExpiresAt) {
        $needRefresh = ($auth.ExpiresAt.ToUniversalTime() -lt [datetime]::UtcNow.AddMinutes(2))
    }
    if ($needRefresh -or -not $auth.AccessToken) {
        $auth = Update-AntigravityToken $auth
    }
    return $auth
}

function Convert-GeminiQuota {
    param($Data)
    $group = $null
    foreach ($g in @($Data.groups)) {
        $name = [string]$g.displayName
        if ($name -match 'Gemini') { $group = $g; break }
    }
    if (-not $group) { throw '用量接口没有返回 Gemini 配额' }
    $remain5h = $null
    $remainWeek = $null
    $reset5h = $null
    $resetWeek = $null
    foreach ($b in @($group.buckets)) {
        $frac = 0.0
        try { $frac = [double]$b.remainingFraction } catch { continue }
        if ($frac -gt 1.0) { $frac = $frac / 100.0 }
        $frac = [Math]::Max(0.0, [Math]::Min(1.0, $frac))
        $pct = [Math]::Round($frac * 100.0, 1)
        $reset = $null
        if ($b.resetTime) {
            try { $reset = [datetime]::Parse([string]$b.resetTime, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
        }
        $id = ([string]$b.bucketId + ' ' + [string]$b.window).ToLowerInvariant()
        if ($id -match '5h|five') {
            $remain5h = $pct
            $reset5h = $reset
        } elseif ($id -match 'week') {
            $remainWeek = $pct
            $resetWeek = $reset
        }
    }
    if ($null -eq $remain5h -and $null -eq $remainWeek) { throw 'Gemini 配额缺少 5 小时/周窗口' }
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
    $auth = Get-AntigravityAuth
    $data = Invoke-AntigravityQuota $auth
    Convert-GeminiQuota $data
}
