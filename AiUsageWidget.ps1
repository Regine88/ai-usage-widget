# Combined Grok / Kimi / ChatGPT weekly usage desktop widget.
# One window, one row per provider (ChatGPT expands to one row per account).

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AddAccount,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell).Source }
    $argList = @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    if ($Install) { $argList += '-Install' }
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($AddAccount) { $argList += '-AddAccount' }
    if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $argList += @('-IntervalSeconds', "$IntervalSeconds") }
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:GrokHomeDir = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $env:USERPROFILE '.grok' }
$script:GrokAuthPath = Join-Path $script:GrokHomeDir 'auth.json'
$script:GrokUsagePageUrl = 'https://grok.com/?_s=usage'

$script:KimiHomeDir = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
$script:KimiCredPath = Join-Path $script:KimiHomeDir 'credentials\kimi-code.json'
$script:KimiRegionPath = Join-Path $script:KimiHomeDir 'region'
$script:KimiOAuthClientId = '17e5f671-d194-4dfb-9706-5516cb48c098'
$script:KimiUsagePageUrl = 'https://www.kimi.com/code/console'

$script:CodexHomeDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:CodexAuthPath = Join-Path $script:CodexHomeDir 'auth.json'
$script:CodexOAuthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann'
$script:CodexTokenUrl = 'https://auth.openai.com/oauth/token'
$script:CodexUsageUrl = 'https://chatgpt.com/backend-api/wham/usage'
$script:CodexUsagePageUrl = 'https://chatgpt.com/codex/settings/usage'

$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:WidgetDir = Split-Path -Parent $script:SelfPath
$script:StatePath = Join-Path $script:WidgetDir 'ai-state.json'
$script:LogPath = Join-Path $script:WidgetDir 'ai-widget.log'
$script:HistoryPath = Join-Path $script:WidgetDir 'ai-history.jsonl'
$script:VbsPath = Join-Path $script:WidgetDir 'Start-AiUsageWidget.vbs'

$script:Mutex = $null
$script:LastOkAt = $null
$script:FetchRunning = $false
$script:FetchJob = $null
$script:Fonts = $null
$script:Alerted = @{}
$script:LastPct = @{}
$script:IntervalItems = @{}
$script:IntervalExplicit = $PSBoundParameters.ContainsKey('IntervalSeconds')
$script:Drag = $false
$script:DragOffset = [System.Drawing.Point]::Empty
$script:State = @{ x = $null; y = $null; topMost = $false; interval = $null }

function Write-WidgetLog {
    param([string]$Message)
    try {
        $line = '{0:o} {1}' -f (Get-Date).ToUniversalTime(), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    } catch { }
}

function Hide-ConsoleWindow {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeWin {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
"@ -ErrorAction SilentlyContinue
    try { [NativeWin]::SetProcessDPIAware() | Out-Null } catch { }
    try {
        $hwnd = [NativeWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [NativeWin]::ShowWindow($hwnd, 0) | Out-Null }
    } catch { }
}

function Send-BehindWindows {
    param($Form)
    if (-not $Form -or $Form.IsDisposed) { return }
    if ($Form.TopMost) { return }
    $hwndBottom = [IntPtr]1
    [void][NativeWin]::SetWindowPos($Form.Handle, $hwndBottom, 0, 0, 0, 0, 0x0013)
}

function Get-UsageColor {
    param([double]$Percent)
    if ($Percent -ge 90) { return [System.Drawing.Color]::FromArgb(255, 107, 107) }
    if ($Percent -ge 70) { return [System.Drawing.Color]::FromArgb(255, 196, 64) }
    return [System.Drawing.Color]::FromArgb(48, 227, 160)
}

function Convert-ApiTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    return [datetime]::Parse([string]$Value, $null, [Globalization.DateTimeStyles]::RoundtripKind)
}

function New-RoundRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($R * 2, [Math]::Min($W, $H))
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:StatePath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($null -ne $raw.x) { $script:State.x = [int]$raw.x }
        if ($null -ne $raw.y) { $script:State.y = [int]$raw.y }
        if ($null -ne $raw.topMost) { $script:State.topMost = [bool]$raw.topMost }
        else { $script:State.topMost = $false }
        if ($raw.interval) { $script:State.interval = [int]$raw.interval }
    } catch { }
}

function Save-State {
    param($Form)
    try {
        if ($Form) {
            $script:State.x = $Form.Left
            $script:State.y = $Form.Top
            $script:State.topMost = [bool]$Form.TopMost
        }
        $json = @{
            x = $script:State.x
            y = $script:State.y
            topMost = $script:State.topMost
        }
        if ($script:State.interval) { $json.interval = [int]$script:State.interval }
        $json = $json | ConvertTo-Json -Compress
        $tmp = "$script:StatePath.tmp"
        Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    } catch { }
}

function Format-PercentText {
    param([double]$Percent)
    if (($Percent * 10) % 10 -ne 0) { return ('{0:0.0}%' -f $Percent) }
    return ('{0:0}%' -f $Percent)
}

function Format-ResetText {
    param($End)
    if (-not $End) { return '重置时间未知' }
    $local = $End.ToLocalTime()
    $span = $local - [datetime]::Now
    if ($span.TotalSeconds -le 0) { return '即将重置' }
    if ($span.TotalDays -ge 1) {
        return ('重置还有 {0} 天 {1} 小时' -f [int][Math]::Floor($span.TotalDays), $span.Hours)
    }
    if ($span.TotalHours -ge 1) {
        return ('重置还有 {0} 小时 {1} 分钟' -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
    }
    return ('重置还有 {0} 分钟' -f [Math]::Max(1, [int]$span.TotalMinutes))
}

function Format-ResetTime {
    param($End)
    if (-not $End) { return $null }
    return $End.ToLocalTime().ToString('M月d日 HH:mm')
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    $msg = [string]$ErrorRecord.Exception.Message
    if ($msg -match 'HTTP (\d{3})\b') { return [int]$Matches[1] }
    if ($msg -match 'status code does not indicate success: (\d{3})') { return [int]$Matches[1] }
    return $null
}

# WinForms STA + HttpClient can hang past -TimeoutSec. Run HTTP in an MTA runspace
# with a hard wait so one provider cannot freeze the whole card.
function Invoke-WidgetRest {
    param(
        [ValidateSet('Get', 'Post')]$Method = 'Get',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        $Body,
        [string]$ContentType,
        [int]$TimeoutSec = 15
    )
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $inner = {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $p = @{
            Method     = $Method
            Uri        = $Uri
            TimeoutSec = $TimeoutSec
        }
        if ($Headers) { $p.Headers = $Headers }
        if ($null -ne $Body) {
            $p.Body = $Body
            if ($ContentType) { $p.ContentType = $ContentType }
        }
        try {
            Invoke-RestMethod @p
        } catch {
            $code = $null
            try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
            $msg = $_.Exception.Message
            if ($code) { throw ("HTTP {0} {1}" -f $code, $msg) }
            throw
        }
    }
    [void]$ps.AddScript($inner)
    [void]$ps.AddArgument($Method)
    [void]$ps.AddArgument($Uri)
    [void]$ps.AddArgument($Headers)
    [void]$ps.AddArgument($Body)
    [void]$ps.AddArgument($ContentType)
    [void]$ps.AddArgument($TimeoutSec)
    try {
        $handle = $ps.BeginInvoke()
        $ok = $handle.AsyncWaitHandle.WaitOne([int](($TimeoutSec + 5) * 1000))
        if (-not $ok) {
            try { $ps.Stop() } catch { }
            throw '请求超时'
        }
        $result = $ps.EndInvoke($handle)
        if ($ps.HadErrors) {
            $err = $ps.Streams.Error[0]
            if ($err.Exception) { throw $err.Exception }
            throw $err.ToString()
        }
        if ($result.Count -eq 1) { return $result[0] }
        return $result
    } finally {
        $ps.Dispose()
        $rs.Dispose()
    }
}

# --- Grok ---

function Get-ProductLabel {
    param([string]$Name)
    switch -Regex ($Name) {
        'Build'   { 'Build'; break }
        'Chat'    { 'Chat'; break }
        'Imagine' { 'Imagine'; break }
        'Voice'   { 'Voice'; break }
        'API|Api' { 'API'; break }
        default   { $Name }
    }
}

function Read-GrokAuth {
    if (-not (Test-Path -LiteralPath $script:GrokAuthPath)) {
        throw '未找到 ~/.grok/auth.json，请先运行 grok login'
    }
    $raw = Get-Content -LiteralPath $script:GrokAuthPath -Raw -Encoding utf8 | ConvertFrom-Json
    $best = $null
    foreach ($p in $raw.PSObject.Properties) {
        $v = $p.Value
        if (-not $v -or -not $v.key) { continue }
        $prefer = 0
        if ($p.Name -like 'https://auth.x.ai*') { $prefer = 2 }
        elseif ($p.Name -like 'https://accounts.x.ai*') { $prefer = 1 }
        $exp = $null
        if ($v.expires_at) { try { $exp = [datetime]::Parse($v.expires_at, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { } }
        $score = $prefer
        if ($exp -and $exp.ToUniversalTime() -gt [datetime]::UtcNow) { $score += 10 }
        if (-not $best -or $score -gt $best.score) {
            $best = [pscustomobject]@{ score = $score; entry = $v; keyName = $p.Name; expires = $exp }
        }
    }
    if (-not $best) { throw 'auth.json 中没有可用的登录凭证' }
    [pscustomobject]@{
        KeyName      = $best.keyName
        Token        = [string]$best.entry.key
        RefreshToken = [string]$best.entry.refresh_token
        ClientId     = [string]$best.entry.oidc_client_id
        Email        = [string]$best.entry.email
        ExpiresAt    = $best.expires
        Raw          = $raw
        Entry        = $best.entry
    }
}

function Save-GrokAuth {
    param($Auth, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $entry = $Auth.Entry
    $entry.key = $AccessToken
    if ($RefreshToken) { $entry.refresh_token = $RefreshToken }
    $entry.expires_at = $ExpiresAt.ToUniversalTime().ToString('o')
    $json = $Auth.Raw | ConvertTo-Json -Depth 8
    $tmp = "$script:GrokAuthPath.tmp-ai-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:GrokAuthPath -Force
}

function Update-GrokToken {
    param($Auth)
    if (-not $Auth.RefreshToken -or -not $Auth.ClientId) {
        throw '登录已过期，请运行 grok login'
    }
    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $Auth.RefreshToken
        client_id     = $Auth.ClientId
    }
    $resp = Invoke-WidgetRest -Method Post -Uri 'https://auth.x.ai/oauth2/token' -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) { throw '刷新令牌失败，请运行 grok login' }
    $expires = [datetime]::UtcNow.AddSeconds([int]($resp.expires_in))
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.RefreshToken }
    Save-GrokAuth -Auth $Auth -AccessToken $resp.access_token -RefreshToken $newRefresh -ExpiresAt $expires
    $Auth.Token = [string]$resp.access_token
    $Auth.RefreshToken = $newRefresh
    $Auth.ExpiresAt = $expires
    Write-WidgetLog 'grok token refreshed'
    return $Auth
}

function Get-GrokAuthHeaders {
    param($Auth)
    return @{
        Authorization      = "Bearer $($Auth.Token)"
        'x-xai-token-auth' = 'xai-grok-cli'
        Accept             = 'application/json'
        'User-Agent'       = 'grok-usage-widget'
    }
}

function Invoke-GrokGet {
    param($Auth, [string]$Url)
    try {
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-GrokAuthHeaders $Auth)
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -in 401, 403) {
            $Auth = Update-GrokToken -Auth $Auth
            return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-GrokAuthHeaders $Auth)
        }
        throw
    }
}

function Get-GrokUsageSnapshot {
    $auth = Read-GrokAuth
    if ($auth.ExpiresAt -and $auth.ExpiresAt.ToUniversalTime() -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-GrokToken -Auth $auth } catch { Write-WidgetLog "grok preemptive refresh failed: $($_.Exception.Message)" }
    }

    $credits = Invoke-GrokGet -Auth $auth -Url 'https://cli-chat-proxy.grok.com/v1/billing?format=credits'
    $cfg = $credits.config
    if (-not $cfg) { throw '用量接口没有返回 config' }

    $pct = 0.0
    if ($null -ne $cfg.creditUsagePercent) {
        $pct = [double]$cfg.creditUsagePercent
    } elseif ($cfg.onDemandCap -and $cfg.onDemandCap.val -and [double]$cfg.onDemandCap.val -gt 0) {
        $used = 0.0
        if ($cfg.onDemandUsed -and $null -ne $cfg.onDemandUsed.val) { $used = [double]$cfg.onDemandUsed.val }
        $pct = [Math]::Round(100.0 * $used / [double]$cfg.onDemandCap.val, 1)
    }

    $end = $null
    if ($cfg.currentPeriod) { $end = Convert-ApiTime $cfg.currentPeriod.end }
    if (-not $end) { $end = Convert-ApiTime $cfg.billingPeriodEnd }

    $products = @()
    if ($cfg.productUsage) {
        foreach ($p in @($cfg.productUsage)) {
            $products += [pscustomobject]@{
                Name    = Get-ProductLabel ([string]$p.product)
                Percent = [double]$p.usagePercent
            }
        }
    }

    $prepaid = 0
    if ($cfg.prepaidBalance -and $null -ne $cfg.prepaidBalance.val) { $prepaid = [int]$cfg.prepaidBalance.val }

    [pscustomobject]@{
        Percent      = [Math]::Round($pct, 1)
        PeriodEnd    = $end
        Products     = $products
        PrepaidCents = $prepaid
        FetchedAt    = [datetime]::Now
    }
}

# --- Kimi ---

function Get-KimiHosts {
    $oauth = 'https://auth.kimi.com'
    $base = 'https://api.kimi.com/coding/v1'
    $region = ''
    if (Test-Path -LiteralPath $script:KimiRegionPath) {
        try { $region = (Get-Content -LiteralPath $script:KimiRegionPath -Raw -Encoding utf8).Trim() } catch { }
    }
    if ($region -match 'global') {
        $oauth = 'https://auth.kimi.ai'
        $base = 'https://api.kimi.ai/coding/v1'
    }
    if ($env:KIMI_CODE_OAUTH_HOST) { $oauth = $env:KIMI_CODE_OAUTH_HOST }
    if ($env:KIMI_CODE_BASE_URL) { $base = $env:KIMI_CODE_BASE_URL }
    [pscustomobject]@{
        OAuthHost = $oauth.TrimEnd('/')
        BaseUrl   = $base.TrimEnd('/')
    }
}

function Read-KimiAuth {
    if (-not (Test-Path -LiteralPath $script:KimiCredPath)) {
        throw '未找到 ~/.kimi-code/credentials/kimi-code.json，请先运行 kimi 登录'
    }
    $raw = Get-Content -LiteralPath $script:KimiCredPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $raw.access_token -or -not $raw.refresh_token) {
        throw 'kimi-code.json 中没有可用的登录凭证，请重新登录'
    }
    $exp = $null
    if ($raw.expires_at) {
        try { $exp = [DateTimeOffset]::FromUnixTimeSeconds([long]$raw.expires_at).UtcDateTime } catch { }
    }
    [pscustomobject]@{
        Token     = [string]$raw.access_token
        Refresh   = [string]$raw.refresh_token
        ExpiresAt = $exp
    }
}

function Save-KimiAuth {
    param([string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $raw = Get-Content -LiteralPath $script:KimiCredPath -Raw -Encoding utf8 | ConvertFrom-Json
    $raw.access_token = $AccessToken
    $raw.refresh_token = $RefreshToken
    $raw.expires_at = [long][DateTimeOffset]::new($ExpiresAt.ToUniversalTime()).ToUnixTimeSeconds()
    $json = $raw | ConvertTo-Json -Depth 8 -Compress
    $tmp = "$script:KimiCredPath.tmp-ai-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:KimiCredPath -Force
}

function Update-KimiToken {
    param($Auth)
    $hosts = Get-KimiHosts
    $body = @{
        client_id     = $script:KimiOAuthClientId
        grant_type    = 'refresh_token'
        refresh_token = $Auth.Refresh
    }
    $resp = Invoke-WidgetRest -Method Post -Uri "$($hosts.OAuthHost)/api/oauth/token" -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) { throw '刷新令牌失败，请重新运行 kimi 登录' }
    $expires = [datetime]::UtcNow.AddSeconds([int]($resp.expires_in))
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.Refresh }
    Save-KimiAuth -AccessToken $resp.access_token -RefreshToken $newRefresh -ExpiresAt $expires
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    $Auth.ExpiresAt = $expires
    Write-WidgetLog 'kimi token refreshed'
    return $Auth
}

function Invoke-KimiGet {
    param($Auth, [string]$Url)
    $headers = @{
        Authorization = "Bearer $($Auth.Token)"
        Accept        = 'application/json'
        'User-Agent'  = 'kimi-usage-widget'
    }
    try {
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -in 401, 403) {
            $Auth = Update-KimiToken -Auth $Auth
            $headers.Authorization = "Bearer $($Auth.Token)"
            return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
        }
        throw
    }
}

function Get-KimiWindowLabel {
    param($Window)
    if (-not $Window) { return $null }
    $duration = 0
    try { $duration = [int]$Window.duration } catch { return $null }
    $unit = [string]$Window.timeUnit
    $hours = 0.0
    switch ($unit) {
        'TIME_UNIT_MINUTE' { $hours = $duration / 60.0 }
        'TIME_UNIT_HOUR'   { $hours = [double]$duration }
        'TIME_UNIT_DAY'    { $hours = $duration * 24.0 }
        'TIME_UNIT_WEEK'   { $hours = $duration * 168.0 }
        default            { return $null }
    }
    if ($hours -le 0) { return $null }
    if ($hours -ge 24) { return ('{0}天窗' -f [int][Math]::Round($hours / 24.0)) }
    if ($hours -eq [int]$hours) { return ('{0}小时窗' -f [int]$hours) }
    return ('{0:0.#}小时窗' -f $hours)
}

function Get-KimiUsageSnapshot {
    $auth = Read-KimiAuth
    if ($auth.ExpiresAt -and $auth.ExpiresAt -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-KimiToken -Auth $auth } catch { Write-WidgetLog "kimi preemptive refresh failed: $($_.Exception.Message)" }
    }
    $hosts = Get-KimiHosts
    $data = Invoke-KimiGet -Auth $auth -Url "$($hosts.BaseUrl)/usages"

    if (-not $data.usage) { throw '用量接口没有返回 usage' }
    $used = [double]$data.usage.used
    $limit = [double]$data.usage.limit
    $pct = 0.0
    if ($limit -gt 0) { $pct = 100.0 * $used / $limit }
    $weekEnd = Convert-ApiTime $data.usage.resetTime

    $windows = @()
    foreach ($row in @($data.limits)) {
        $d = $row.detail
        if (-not $d) { continue }
        $wLimit = 0.0
        $wUsed = 0.0
        try { $wUsed = [double]$d.used } catch { }
        try { $wLimit = [double]$d.limit } catch { }
        $wPct = 0.0
        if ($wLimit -gt 0) { $wPct = 100.0 * $wUsed / $wLimit }
        $windows += [pscustomobject]@{
            Label   = Get-KimiWindowLabel $row.window
            Percent = $wPct
        }
    }

    $extraCents = 0
    $currency = 'CNY'
    if ($data.boosterWallet) {
        try {
            if ($data.boosterWallet.monthlyUsed.priceInCents) {
                $extraCents = [long]$data.boosterWallet.monthlyUsed.priceInCents
            }
            if ($data.boosterWallet.monthlyUsed.currency) { $currency = [string]$data.boosterWallet.monthlyUsed.currency }
        } catch { }
    }

    [pscustomobject]@{
        Percent    = [Math]::Round($pct, 1)
        Windows    = $windows
        PeriodEnd  = $weekEnd
        ExtraCents = $extraCents
        Currency   = $currency
        FetchedAt  = [datetime]::Now
    }
}

# --- ChatGPT / Codex ---

function Get-TokenEmail {
    param([string]$IdToken)
    if (-not $IdToken) { return $null }
    try {
        $payload = $IdToken.Split('.')[1]
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        if ($claims.email) { return [string]$claims.email }
    } catch { }
    return $null
}

function Read-CodexAuth {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch { return $null }
    if (-not $raw.tokens -or -not $raw.tokens.access_token -or -not $raw.tokens.refresh_token) { return $null }
    $accountId = [string]$raw.tokens.account_id
    if (-not $accountId) { return $null }
    $email = Get-TokenEmail ([string]$raw.tokens.id_token)
    [pscustomobject]@{
        Path      = $Path
        Token     = [string]$raw.tokens.access_token
        Refresh   = [string]$raw.tokens.refresh_token
        AccountId = $accountId
        Email     = $email
    }
}

function Get-AccountLabel {
    param($Auth)
    if ($Auth.Email) { return $Auth.Email }
    if ($Auth.AccountId -and $Auth.AccountId.Length -ge 8) { return $Auth.AccountId.Substring(0, 8) }
    return 'ChatGPT'
}

function Get-SnapshotPath {
    param([string]$AccountId)
    Join-Path $script:WidgetDir ("chatgpt-auth-{0}.json" -f $AccountId)
}

function Get-CodexAccounts {
    $byId = [ordered]@{}
    $active = Read-CodexAuth $script:CodexAuthPath
    if ($active) { $byId[$active.AccountId] = $active }
    foreach ($f in Get-ChildItem -LiteralPath $script:WidgetDir -Filter 'chatgpt-auth-*.json' -ErrorAction SilentlyContinue) {
        $snap = Read-CodexAuth $f.FullName
        if ($snap -and -not $byId.Contains($snap.AccountId)) { $byId[$snap.AccountId] = $snap }
    }
    return @($byId.Values)
}

function Add-CurrentAccount {
    $active = Read-CodexAuth $script:CodexAuthPath
    if (-not $active) {
        Write-Host '未找到 ~/.codex/auth.json，请先运行 codex login'
        return
    }
    $snapPath = Get-SnapshotPath $active.AccountId
    Copy-Item -LiteralPath $script:CodexAuthPath -Destination $snapPath -Force
    Write-Host ("已登记账号 {0} -> {1}" -f (Get-AccountLabel $active), $snapPath)
    Write-WidgetLog ("snapshot account {0}" -f (Get-AccountLabel $active))
}

function Save-CodexAuth {
    param([string]$Path, [string]$AccessToken, [string]$RefreshToken, [string]$IdToken)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $raw.tokens.access_token = $AccessToken
    $raw.tokens.refresh_token = $RefreshToken
    if ($IdToken) { $raw.tokens.id_token = $IdToken }
    $raw.last_refresh = (Get-Date).ToUniversalTime().ToString('o')
    $json = $raw | ConvertTo-Json -Depth 8
    $tmp = "$Path.tmp-ai-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Update-CodexToken {
    param($Auth)
    $body = @{
        client_id     = $script:CodexOAuthClientId
        grant_type    = 'refresh_token'
        refresh_token = $Auth.Refresh
    }
    $resp = Invoke-WidgetRest -Method Post -Uri $script:CodexTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) { throw '刷新令牌失败，请重新登录该账号' }
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.Refresh }
    $newId = if ($resp.id_token) { [string]$resp.id_token } else { $null }
    Save-CodexAuth -Path $Auth.Path -AccessToken $resp.access_token -RefreshToken $newRefresh -IdToken $newId
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    Write-WidgetLog ("codex token refreshed for {0}" -f (Get-AccountLabel $Auth))
    return $Auth
}

function Invoke-CodexGet {
    param($Auth, [string]$Url)
    $headers = @{
        Authorization        = "Bearer $($Auth.Token)"
        'ChatGPT-Account-Id' = $Auth.AccountId
        Accept               = 'application/json'
        'User-Agent'         = 'codex-cli'
    }
    try {
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -in 401, 403) {
            $Auth = Update-CodexToken -Auth $Auth
            $headers.Authorization = "Bearer $($Auth.Token)"
            return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
        }
        throw
    }
}

function Get-CodexWindowInfo {
    param($Window)
    if (-not $Window) { return $null }
    $secs = 0
    try { $secs = [long]$Window.limit_window_seconds } catch { }
    $pct = 0.0
    try { $pct = [double]$Window.used_percent } catch { }
    $resetAt = $null
    if ($Window.reset_at) {
        try { $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$Window.reset_at).UtcDateTime } catch { }
    }
    $label = $null
    if ($secs -gt 0) {
        $hours = $secs / 3600.0
        if ($hours -ge 24) { $label = '{0}天窗' -f [int][Math]::Round($hours / 24.0) }
        elseif ($hours -eq [int]$hours) { $label = '{0}小时窗' -f [int]$hours }
        else { $label = '{0:0.#}小时窗' -f $hours }
    }
    [pscustomobject]@{
        Seconds = $secs
        Percent = $pct
        ResetAt = $resetAt
        Label   = $label
    }
}

function Get-CodexUsageSnapshot {
    param($Auth)
    $data = Invoke-CodexGet -Auth $Auth -Url $script:CodexUsageUrl
    if (-not $data.rate_limit) { throw '用量接口没有返回 rate_limit' }

    $primary = Get-CodexWindowInfo $data.rate_limit.primary_window
    $secondary = Get-CodexWindowInfo $data.rate_limit.secondary_window

    $weekly = $null
    $burst = $null
    foreach ($w in @($primary, $secondary)) {
        if (-not $w) { continue }
        if (-not $weekly -or $w.Seconds -gt $weekly.Seconds) {
            $burst = $weekly
            $weekly = $w
        } elseif (-not $burst) {
            $burst = $w
        }
    }
    if (-not $weekly) { throw '用量接口没有返回限额窗口' }

    $creditBalance = $null
    try {
        if ($data.credits -and $data.credits.has_credits -and $null -ne $data.credits.balance) {
            $creditBalance = [double]$data.credits.balance
        }
    } catch { }

    [pscustomobject]@{
        Percent   = [Math]::Round([double]$weekly.Percent, 1)
        PeriodEnd = $weekly.ResetAt
        Burst     = $burst
        Credits   = $creditBalance
        FetchedAt = [datetime]::Now
    }
}

function Sync-ActiveCodexSnapshot {
    param($Accounts)
    foreach ($acct in $Accounts) {
        if ($acct.Path -eq $script:CodexAuthPath) {
            $snap = Get-SnapshotPath $acct.AccountId
            if (Test-Path -LiteralPath $snap) {
                try { Copy-Item -LiteralPath $script:CodexAuthPath -Destination $snap -Force } catch { }
            }
        }
    }
}

# --- Rows / UI ---

function Get-ProviderRows {
    $rows = @()
    $rows += [pscustomobject]@{
        Id      = 'grok'
        Kind    = 'grok'
        Name    = 'Grok'
        OpenUrl = $script:GrokUsagePageUrl
        Auth    = $null
    }
    $rows += [pscustomobject]@{
        Id      = 'kimi'
        Kind    = 'kimi'
        Name    = 'Kimi'
        OpenUrl = $script:KimiUsagePageUrl
        Auth    = $null
    }
    $accounts = @(Get-CodexAccounts)
    if ($accounts.Count -eq 0) {
        $rows += [pscustomobject]@{
            Id      = 'codex-missing'
            Kind    = 'codex-missing'
            Name    = 'ChatGPT'
            OpenUrl = $script:CodexUsagePageUrl
            Auth    = $null
        }
    } else {
        foreach ($acct in $accounts) {
            $rows += [pscustomobject]@{
                Id      = ('codex-{0}' -f $acct.AccountId)
                Kind    = 'codex'
                Name    = Get-AccountLabel $acct
                OpenUrl = $script:CodexUsagePageUrl
                Auth    = $acct
            }
        }
    }
    return $rows
}

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'AI 周用量.lnk'
}

function Write-LauncherVbs {
    $content = @'
Option Explicit

Dim fso, sh, dirName, ps1Path, exePath
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dirName = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = dirName & "\AiUsageWidget.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "Widget script not found:" & vbCrLf & ps1Path, vbExclamation, "AI Usage Widget"
    WScript.Quit 1
End If

exePath = FindPowerShell()
If exePath = "" Then
    MsgBox "Neither pwsh.exe nor powershell.exe was found.", vbCritical, "AI Usage Widget"
    WScript.Quit 1
End If

sh.Run """" & exePath & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1Path & """", 0, False

' Prefer PowerShell 7 at its default install path, then anything named
' pwsh.exe on PATH, and finally fall back to Windows PowerShell 5.1.
Function FindPowerShell()
    Dim p, d
    FindPowerShell = ""
    p = "C:\Program Files\PowerShell\7\pwsh.exe"
    If fso.FileExists(p) Then
        FindPowerShell = p
        Exit Function
    End If
    For Each d In Split(sh.Environment("PROCESS")("PATH"), ";")
        If Len(d) > 0 Then
            p = fso.BuildPath(d, "pwsh.exe")
            If fso.FileExists(p) Then
                FindPowerShell = p
                Exit Function
            End If
        End If
    Next
    p = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
    If fso.FileExists(p) Then FindPowerShell = p
End Function
'@
    Set-Content -LiteralPath $script:VbsPath -Value $content -Encoding ascii
}

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$WorkDir, [string]$Desc)
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = $WorkDir
    $lnk.WindowStyle = 7
    $lnk.Description = $Desc
    $lnk.Save()
}

function Install-Widget {
    Write-LauncherVbs
    New-Shortcut -Path (Get-StartupShortcutPath) -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 AI 周用量卡片'
    Write-Host "已写入开机启动。程序目录: $($script:WidgetDir)"
}

function Uninstall-Widget {
    $p = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    Write-Host "已移除开机启动。程序仍在 $($script:WidgetDir)"
}

function Ensure-SingleInstance {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\AiUsageDesktopWidget')
    if (-not $script:Mutex.WaitOne(0, $false)) {
        Write-WidgetLog 'another instance is already running'
        exit 0
    }
}

function Get-ClampedLocation {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $wa = $s.WorkingArea
        if ($X -ge ($wa.Left - 40) -and $Y -ge ($wa.Top - 40) -and $X -lt $wa.Right -and $Y -lt $wa.Bottom) {
            $nx = [Math]::Min([Math]::Max($X, $wa.Left), $wa.Right - $W)
            $ny = [Math]::Min([Math]::Max($Y, $wa.Top), $wa.Bottom - $H)
            return New-Object System.Drawing.Point $nx, $ny
        }
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return New-Object System.Drawing.Point ($wa.Right - $W - 24), ($wa.Top + 24)
}

function New-Label {
    param($Parent, [string]$Name, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $Color, [string]$Align = 'TopLeft')
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Name = $Name
    $lbl.Location = New-Object System.Drawing.Point $X, $Y
    $lbl.Size = New-Object System.Drawing.Size $W, $H
    $lbl.Font = $Font
    $lbl.ForeColor = $Color
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.TextAlign = [System.Drawing.ContentAlignment]$Align
    $lbl.Parent = $Parent
    return $lbl
}

function Bind-Drag {
    param($Control)
    $Control.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:Ui -and $script:Ui.Form) {
            $script:Drag = $true
            $script:DragOffset = $_.Location
        }
    })
    $Control.Add_MouseMove({
        if ($script:Drag -and $_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:Ui -and $script:Ui.Form) {
            $script:Ui.Form.Left += $_.X - $script:DragOffset.X
            $script:Ui.Form.Top += $_.Y - $script:DragOffset.Y
        }
    })
    $Control.Add_MouseUp({
        if ($script:Drag -and $script:Ui -and $script:Ui.Form) {
            $script:Drag = $false
            $f = $script:Ui.Form
            $clamped = Get-ClampedLocation $f.Left $f.Top $f.Width $f.Height
            $f.Location = $clamped
            Save-State $f
            Send-BehindWindows $f
        }
    })
    $Control.Add_MouseDoubleClick({
        $url = $this.Tag
        if ($url -is [string] -and $url) { Start-Process $url }
    })
}

function Get-FormHeight {
    param([int]$RowCount)
    $n = [Math]::Max(1, $RowCount)
    return 14 + $n * 74 - 10 + 26
}

function Rebuild-ProviderRows {
    param($Form, $Specs)
    if ($script:Ui.RowControls) {
        foreach ($c in $script:Ui.RowControls) {
            try { $Form.Controls.Remove($c); $c.Dispose() } catch { }
        }
    }
    $script:Ui.RowControls = New-Object System.Collections.Generic.List[object]
    $script:Ui.Rows = New-Object System.Collections.Generic.List[hashtable]

    $fg = [System.Drawing.Color]::FromArgb(244, 244, 247)
    $muted = [System.Drawing.Color]::FromArgb(152, 152, 160)
    if (-not $script:Fonts) {
        $script:Fonts = @{
            Name   = New-Object System.Drawing.Font('Segoe UI', 9)
            Pct    = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
            Detail = New-Object System.Drawing.Font('Segoe UI', 8.5)
        }
    }
    $nameFont = $script:Fonts.Name
    $pctFont = $script:Fonts.Pct
    $detailFont = $script:Fonts.Detail

    $y = 14
    foreach ($spec in $Specs) {
        $lblName = New-Label $Form "name-$y" 16 ($y + 4) 180 18 $nameFont $fg 'MiddleLeft'
        $lblName.Text = $spec.Name
        $lblName.Tag = $spec.OpenUrl
        $lblPct = New-Label $Form "pct-$y" 196 $y 68 26 $pctFont (Get-UsageColor 0) 'MiddleRight'
        $lblPct.Text = '--%'
        $lblPct.Tag = $spec.OpenUrl

        $barBack = New-Object System.Windows.Forms.Panel
        $barBack.Location = New-Object System.Drawing.Point 16, ($y + 30)
        $barBack.Size = New-Object System.Drawing.Size 248, 8
        $barBack.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 50)
        $barBack.Parent = $Form
        $barBack.Tag = $spec.OpenUrl
        $barFill = New-Object System.Windows.Forms.Panel
        $barFill.Location = New-Object System.Drawing.Point 0, 0
        $barFill.Size = New-Object System.Drawing.Size 6, 8
        $barFill.BackColor = Get-UsageColor 0
        $barFill.Parent = $barBack
        $barFill.Tag = $spec.OpenUrl

        $lblDetail = New-Label $Form "detail-$y" 16 ($y + 44) 248 16 $detailFont $muted 'MiddleLeft'
        $lblDetail.Text = ''
        $lblDetail.Tag = $spec.OpenUrl

        foreach ($c in @($lblName, $lblPct, $barBack, $barFill, $lblDetail)) {
            $c.ContextMenuStrip = $script:Ui.Menu
            Bind-Drag $c
        }
        foreach ($c in @($lblName, $lblPct, $barBack, $lblDetail)) { [void]$script:Ui.RowControls.Add($c) }
        [void]$script:Ui.Rows.Add(@{
            Id       = $spec.Id
            Kind     = $spec.Kind
            Name     = $spec.Name
            Auth     = $spec.Auth
            Pct      = $lblPct
            BarFill  = $barFill
            Detail   = $lblDetail
            Controls = @($lblName, $lblPct, $barBack, $barFill, $lblDetail)
        })
        if ($script:Ui.Tip) {
            $initTip = ("{0}`n数据加载中…`n双击打开用量页面" -f $spec.Name)
            foreach ($c in @($lblName, $lblPct, $barBack, $barFill, $lblDetail)) {
                try { $script:Ui.Tip.SetToolTip($c, $initTip) } catch { }
            }
        }
        $y += 74
    }

    $h = Get-FormHeight $Specs.Count
    $Form.Size = New-Object System.Drawing.Size(280, $h)
    $round = New-RoundRectPath 0 0 $Form.Width $Form.Height 18
    $old = $Form.Region
    $Form.Region = New-Object System.Drawing.Region($round)
    if ($old) { $old.Dispose() }
    $script:Ui.Stamp.Top = $h - 24
    $script:Ui.Sig = (($Specs | ForEach-Object { $_.Id }) -join ',')
}

function Set-RowUsage {
    param($Row, [double]$Percent, [string]$Detail)
    $color = Get-UsageColor $Percent
    $text = Format-PercentText $Percent
    if ($Row.Pct.Text -ne $text) { $Row.Pct.Text = $text }
    if ($Row.Pct.ForeColor.ToArgb() -ne $color.ToArgb()) { $Row.Pct.ForeColor = $color }
    if ($Row.BarFill.BackColor.ToArgb() -ne $color.ToArgb()) { $Row.BarFill.BackColor = $color }
    $w = [Math]::Max(6, [int](248 * $Percent / 100.0))
    if ($Row.BarFill.Width -ne $w) { $Row.BarFill.Width = $w }
    if ($Row.Detail.Text -ne $Detail) { $Row.Detail.Text = $Detail }
    $muted = [System.Drawing.Color]::FromArgb(152, 152, 160)
    if ($Row.Detail.ForeColor.ToArgb() -ne $muted.ToArgb()) { $Row.Detail.ForeColor = $muted }
    return $text
}

function Set-RowError {
    param($Row, [string]$Message)
    $Row.Detail.Text = $Message
    $Row.Detail.ForeColor = [System.Drawing.Color]::FromArgb(255, 107, 107)
}

# Row data builders are pure (no UI access) so they can run in the
# background fetch runspace; the UI thread only applies their results.
function Get-GrokRowData {
    $u = Get-GrokUsageSnapshot
    $details = @()
    foreach ($p in @($u.Products)) {
        $details += ('{0} {1:0}%' -f $p.Name, $p.Percent)
    }
    $details += Format-ResetText $u.PeriodEnd
    if ($u.PrepaidCents -gt 0) {
        $details += ('额外 ${0:0.00}' -f ($u.PrepaidCents / 100.0))
    }
    Write-WidgetLog ("usage grok {0} ok" -f $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = ('Grok {0}' -f (Format-PercentText $u.Percent))
        Reset   = (Format-ResetTime $u.PeriodEnd)
    }
}

function Get-KimiRowData {
    $u = Get-KimiUsageSnapshot
    $details = @()
    foreach ($w in @($u.Windows)) {
        if ($w.Label) { $details += ('{0} {1:0}%' -f $w.Label, $w.Percent) }
    }
    $details += Format-ResetText $u.PeriodEnd
    if ($u.ExtraCents -gt 0) {
        $symbol = if ($u.Currency -eq 'CNY') { '¥' } else { '$' }
        $details += ('本月额外 {0}{1:0.00}' -f $symbol, ($u.ExtraCents / 100.0))
    }
    Write-WidgetLog ("usage kimi {0} ok" -f $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = ('Kimi {0}' -f (Format-PercentText $u.Percent))
        Reset   = (Format-ResetTime $u.PeriodEnd)
    }
}

function Get-CodexRowData {
    param($Auth, [string]$Name, [string]$Id)
    $u = Get-CodexUsageSnapshot -Auth $Auth
    $details = @()
    if ($u.Burst -and $u.Burst.Label) { $details += ('{0} {1:0}%' -f $u.Burst.Label, $u.Burst.Percent) }
    $details += Format-ResetText $u.PeriodEnd
    if ($null -ne $u.Credits) { $details += ('余额 ${0:0.00}' -f $u.Credits) }
    Write-WidgetLog ("usage {0} {1} ok" -f $Id, $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = ('{0} {1}' -f $Name, (Format-PercentText $u.Percent))
        Reset   = (Format-ResetTime $u.PeriodEnd)
    }
}

function New-WidgetForm {
    Read-State
    Hide-ConsoleWindow

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AI 周用量'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Size = New-Object System.Drawing.Size(280, (Get-FormHeight 3))
    $form.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
    $form.Opacity = 0.96
    $form.TopMost = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true, $null)

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($null -ne $script:State.x -and $null -ne $script:State.y) {
        $form.Location = Get-ClampedLocation ([int]$script:State.x) ([int]$script:State.y) $form.Width $form.Height
    } else {
        $form.Location = New-Object System.Drawing.Point ($wa.Right - $form.Width - 24), ($wa.Top + 24)
    }
    Write-WidgetLog ("form location $($form.Left),$($form.Top)")

    $round = New-RoundRectPath 0 0 $form.Width $form.Height 18
    $form.Region = New-Object System.Drawing.Region($round)

    $dim = [System.Drawing.Color]::FromArgb(108, 108, 116)
    $footFont = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblStamp = New-Label $form 'stamp' 16 ($form.Height - 24) 248 18 $footFont $dim 'MiddleCenter'
    $lblStamp.Text = ''

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRefresh = $menu.Items.Add('立即刷新')
    $miInterval = New-Object System.Windows.Forms.ToolStripMenuItem '刷新间隔'
    foreach ($sec in 60, 300, 900, 3600) {
        $item = $miInterval.DropDownItems.Add(('{0} 分钟' -f ($sec / 60)))
        $item.Tag = $sec
        $script:IntervalItems[$sec] = $item
    }
    [void]$menu.Items.Add($miInterval)
    $miAdd = $menu.Items.Add('登记 ChatGPT 账号')
    $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem '打开用量页'
    $miOpenGrok = $miOpen.DropDownItems.Add('Grok')
    $miOpenKimi = $miOpen.DropDownItems.Add('Kimi')
    $miOpenCodex = $miOpen.DropDownItems.Add('ChatGPT')
    [void]$menu.Items.Add($miOpen)
    $miTop = $menu.Items.Add('浮在窗口上')
    $miTop.Checked = [bool]$script:State.topMost
    [void]$menu.Items.Add('-')
    $startupOn = Test-Path -LiteralPath (Get-StartupShortcutPath)
    $miStart = $menu.Items.Add($(if ($startupOn) { '取消开机启动' } else { '开机启动' }))
    [void]$menu.Items.Add('-')
    $miQuit = $menu.Items.Add('退出')
    $form.ContextMenuStrip = $menu
    $form.TopMost = [bool]$script:State.topMost

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Text = 'AI 周用量'
    $tray.Visible = $true
    $tray.ContextMenuStrip = $menu
    try {
        $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
    } catch {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.InitialDelay = 300
    $tip.ReshowDelay = 200
    $tip.ShowAlways = $true

    $script:Ui = @{
        Form        = $form
        Stamp       = $lblStamp
        Menu        = $menu
        Tray        = $tray
        Tip         = $tip
        Rows        = @()
        RowControls = @()
        Sig         = ''
    }

    $form.ContextMenuStrip = $menu
    $lblStamp.ContextMenuStrip = $menu
    Bind-Drag $form
    Bind-Drag $lblStamp

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { Update-Widget }
    })

    $miRefresh.Add_Click({ Update-Widget })
    foreach ($sec in $script:IntervalItems.Keys) {
        $script:IntervalItems[$sec].Add_Click({
            $chosen = [int]$this.Tag
            $timer.Interval = [Math]::Max(15000, $chosen * 1000)
            $script:State.interval = $chosen
            Save-State $form
            foreach ($k in $script:IntervalItems.Keys) { $script:IntervalItems[$k].Checked = ([int]$k -eq $chosen) }
            Update-Widget
        })
    }
    $miAdd.Add_Click({
        Add-CurrentAccount
        Update-Widget
    })
    $miOpenGrok.Add_Click({ Start-Process $script:GrokUsagePageUrl })
    $miOpenKimi.Add_Click({ Start-Process $script:KimiUsagePageUrl })
    $miOpenCodex.Add_Click({ Start-Process $script:CodexUsagePageUrl })
    $miTop.Add_Click({
        if ($form.TopMost) {
            $form.TopMost = $false
            $miTop.Checked = $false
        } else {
            $form.TopMost = $true
            $miTop.Checked = $true
        }
        Save-State $form
    })
    $miStart.Add_Click({
        $path = Get-StartupShortcutPath
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $miStart.Text = '开机启动'
        } else {
            Write-LauncherVbs
            New-Shortcut -Path $path -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 AI 周用量卡片'
            $miStart.Text = '取消开机启动'
        }
    })
    $miQuit.Add_Click({ $form.Close() })
    $tray.Add_DoubleClick({
        $form.Visible = -not $form.Visible
        if ($form.Visible) { $form.Activate() }
    })

    $intervalSec = $IntervalSeconds
    if (-not $script:IntervalExplicit -and $script:State.interval) { $intervalSec = [int]$script:State.interval }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(15000, $intervalSec * 1000)
    $timer.Add_Tick({ Update-Widget })
    $form.Tag = $timer
    foreach ($k in $script:IntervalItems.Keys) { $script:IntervalItems[$k].Checked = ([int]$k -eq [int]$intervalSec) }

    # Fast poll timer: picks up background fetch results on the UI thread.
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 300
    $pollTimer.Add_Tick({ Receive-BackgroundFetch })
    $script:Ui.Poll = $pollTimer

    $form.Add_Deactivate({ Send-BehindWindows $form })
    $form.Add_Shown({
        Write-WidgetLog 'form shown'
        Send-BehindWindows $form
        $timer.Start()
        Write-WidgetLog 'timer started'
        Update-Widget
    })
    $form.Add_FormClosed({
        Write-WidgetLog 'form closed'
        try { $timer.Stop(); $timer.Dispose() } catch { }
        try { $pollTimer.Stop(); $pollTimer.Dispose() } catch { }
        if ($script:FetchJob) { try { $script:FetchJob.Ps.Stop() } catch { } }
        Clear-FetchJob
        if ($script:Fonts) {
            foreach ($f in $script:Fonts.Values) { try { $f.Dispose() } catch { } }
            $script:Fonts = $null
        }
        try { $tray.Visible = $false; $tray.Dispose() } catch { }
        try { $tip.Dispose() } catch { }
        Save-State $form
        if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
    })

    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-WidgetLog 'run loop'
    [System.Windows.Forms.Application]::Run($form)
    Write-WidgetLog 'run ended'
}

function Update-Widget {
    $ui = $script:Ui
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    if ($script:FetchRunning) { return }  # skip while a refresh is in flight

    $specs = @(Get-ProviderRows)
    $accounts = @($specs | Where-Object { $_.Kind -eq 'codex' } | ForEach-Object { $_.Auth })
    if ($accounts.Count -gt 0) { Sync-ActiveCodexSnapshot $accounts }

    $sig = (($specs | ForEach-Object { $_.Id }) -join ',')
    if ($sig -ne $ui.Sig) {
        Rebuild-ProviderRows $ui.Form $specs
        Write-WidgetLog ("rows rebuilt: {0}" -f $sig)
    }

    $script:FetchRunning = $true
    $ui.Stamp.Text = '更新中…'
    try {
        Start-BackgroundFetch $specs
    } catch {
        $script:FetchRunning = $false
        $ui.Stamp.Text = ('更新失败: {0}' -f $_.Exception.Message)
        Write-WidgetLog ("start fetch failed: {0}" -f $_.Exception.Message)
    }
}

# Fetch usage off the UI thread so the card stays responsive while HTTP
# requests are in flight. The worker runspace gets fresh copies of the
# fetch functions plus the config paths they need via $script: variables.
function Get-WorkerScriptSource {
    $fnNames = @(
        'Write-WidgetLog', 'Convert-ApiTime', 'Get-HttpStatusCode', 'Invoke-WidgetRest',
        'Format-PercentText', 'Format-ResetText', 'Format-ResetTime',
        'Get-ProductLabel', 'Read-GrokAuth', 'Save-GrokAuth', 'Update-GrokToken',
        'Get-GrokAuthHeaders', 'Invoke-GrokGet', 'Get-GrokUsageSnapshot', 'Get-GrokRowData',
        'Get-KimiHosts', 'Read-KimiAuth', 'Save-KimiAuth', 'Update-KimiToken',
        'Invoke-KimiGet', 'Get-KimiWindowLabel', 'Get-KimiUsageSnapshot', 'Get-KimiRowData',
        'Get-AccountLabel', 'Save-CodexAuth', 'Update-CodexToken', 'Invoke-CodexGet',
        'Get-CodexWindowInfo', 'Get-CodexUsageSnapshot', 'Get-CodexRowData'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('param($Rows, $Cfg)')
    [void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
    foreach ($v in 'GrokAuthPath', 'KimiCredPath', 'KimiRegionPath', 'KimiOAuthClientId',
                   'CodexOAuthClientId', 'CodexTokenUrl', 'CodexUsageUrl', 'LogPath') {
        [void]$sb.AppendLine("`$script:$v = `$Cfg.$v")
    }
    foreach ($n in $fnNames) {
        [void]$sb.AppendLine(("function {0} {{" -f $n))
        [void]$sb.AppendLine((Get-Item "function:$n").Definition)
        [void]$sb.AppendLine('}')
    }
    [void]$sb.AppendLine(@'
$results = @()
foreach ($row in $Rows) {
    try {
        $d = $null
        switch ($row.Kind) {
            'grok'  { $d = Get-GrokRowData }
            'kimi'  { $d = Get-KimiRowData }
            'codex' { $d = Get-CodexRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            default { throw '未找到登录凭证，请运行 codex login' }
        }
        $results += [pscustomobject]@{ Id = $row.Id; Percent = $d.Percent; Detail = $d.Detail; Tip = $d.Tip; Reset = $d.Reset; Error = $null }
    } catch {
        $results += [pscustomobject]@{ Id = $row.Id; Percent = $null; Detail = $null; Tip = $null; Reset = $null; Error = $_.Exception.Message }
    }
}
$results
'@)
    return $sb.ToString()
}

function Start-BackgroundFetch {
    param($Specs)
    $rows = @()
    foreach ($s in $Specs) {
        $rows += [pscustomobject]@{ Id = $s.Id; Kind = $s.Kind; Name = $s.Name; Auth = $s.Auth }
    }
    $cfg = @{
        GrokAuthPath       = $script:GrokAuthPath
        KimiCredPath       = $script:KimiCredPath
        KimiRegionPath     = $script:KimiRegionPath
        KimiOAuthClientId  = $script:KimiOAuthClientId
        CodexOAuthClientId = $script:CodexOAuthClientId
        CodexTokenUrl      = $script:CodexTokenUrl
        CodexUsageUrl      = $script:CodexUsageUrl
        LogPath            = $script:LogPath
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript((Get-WorkerScriptSource))
    [void]$ps.AddArgument($rows)
    [void]$ps.AddArgument($cfg)
    $handle = $ps.BeginInvoke()
    $script:FetchJob = @{ Ps = $ps; Rs = $rs; Handle = $handle; StartedAt = (Get-Date) }
    $script:Ui.Poll.Start()
}

function Clear-FetchJob {
    try { if ($script:Ui -and $script:Ui.Poll) { $script:Ui.Poll.Stop() } } catch { }
    if ($script:FetchJob) {
        try { $script:FetchJob.Ps.Dispose() } catch { }
        try { $script:FetchJob.Rs.Dispose() } catch { }
        $script:FetchJob = $null
    }
    $script:FetchRunning = $false
}

function Receive-BackgroundFetch {
    $job = $script:FetchJob
    if (-not $job) { try { $script:Ui.Poll.Stop() } catch { } ; return }
    if (-not $job.Handle.IsCompleted) {
        # Safety net: never let a wedged worker block future refreshes.
        if ((Get-Date) - $job.StartedAt -gt [timespan]::FromMinutes(3)) {
            Write-WidgetLog 'background fetch timed out, stopping'
            try { $job.Ps.Stop() } catch { }
            Clear-FetchJob
            if ($script:Ui -and -not $script:Ui.Form.IsDisposed) { $script:Ui.Stamp.Text = '刷新超时，等待下次尝试' }
        }
        return
    }
    $out = $null
    try {
        $out = $job.Ps.EndInvoke($job.Handle)
        if ($job.Ps.HadErrors) { Write-WidgetLog ("bg fetch error: {0}" -f $job.Ps.Streams.Error[0].ToString()) }
    } catch {
        Write-WidgetLog ("bg fetch failed: {0}" -f $_.Exception.Message)
    }
    Clear-FetchJob
    Apply-FetchResults $out
}

function Set-RowTip {
    param($Row, $Lines)
    if (-not $script:Ui.Tip -or -not $Row.Controls) { return }
    $text = ($Lines | Where-Object { $_ }) -join "`n"
    foreach ($c in $Row.Controls) {
        try { $script:Ui.Tip.SetToolTip($c, $text) } catch { }
    }
}

function Write-UsageHistory {
    param([string]$Id, [double]$Percent)
    try {
        $line = [pscustomobject]@{ ts = [datetime]::Now.ToString('o'); id = $Id; pct = $Percent } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $script:HistoryPath -Value $line -Encoding utf8
        $f = Get-Item -LiteralPath $script:HistoryPath
        if ($f.Length -gt 1MB) {
            $tail = Get-Content -LiteralPath $script:HistoryPath -Tail 2000
            Set-Content -LiteralPath $script:HistoryPath -Value $tail -Encoding utf8
        }
    } catch { }
}

function Send-UsageAlert {
    param($Row, [string]$Id, [double]$Percent)
    $level = 0
    if ($Percent -ge 90) { $level = 90 } elseif ($Percent -ge 70) { $level = 70 }
    $prev = 0
    if ($script:Alerted.ContainsKey($Id)) { $prev = $script:Alerted[$Id] }
    if ($level -gt $prev) {
        $script:Alerted[$Id] = $level
        $msg = '{0} 用量已达 {1}' -f $Row.Name, (Format-PercentText $Percent)
        Write-WidgetLog ("alert {0}: {1}" -f $Id, $msg)
        try {
            $script:Ui.Tray.ShowBalloonTip(6000, 'AI 周用量', $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch { }
    } elseif ($level -eq 0 -and $prev -gt 0) {
        $script:Alerted[$Id] = 0
    }
}

function Apply-FetchResults {
    param($Results)
    $ui = $script:Ui
    if (-not $ui -or $ui.Form.IsDisposed) { return }

    $tipParts = @()
    $errors = 0
    foreach ($r in @($Results)) {
        $row = @($ui.Rows | Where-Object { $_.Id -eq $r.Id })[0]
        if (-not $row) { continue }
        if ($r.Error) {
            $errors++
            Write-WidgetLog ("error {0}: {1}" -f $r.Id, $r.Error)
            Set-RowError $row ([string]$r.Error)
            Set-RowTip $row @(('{0} — 读取失败' -f $row.Name), [string]$r.Error)
        } else {
            $pct = [double]$r.Percent
            Set-RowUsage $row $pct ([string]$r.Detail)
            $tipParts += [string]$r.Tip
            $script:LastOkAt = Get-Date

            $delta = $null
            if ($script:LastPct.ContainsKey($r.Id)) { $delta = $pct - [double]$script:LastPct[$r.Id] }
            $script:LastPct[$r.Id] = $pct

            $upd = '更新于 ' + [datetime]::Now.ToString('HH:mm')
            if ($null -ne $delta -and [Math]::Abs($delta) -ge 0.05) {
                $sign = if ($delta -gt 0) { '+' } else { '' }
                $upd += (' (较上次 {0}{1:0.0}%)' -f $sign, $delta)
            }
            Set-RowTip $row @(
                ('{0} — {1}' -f $row.Name, (Format-PercentText $pct)),
                [string]$r.Detail,
                $(if ($r.Reset) { '重置时刻: ' + [string]$r.Reset }),
                $upd,
                '双击打开用量页面'
            )

            Write-UsageHistory $r.Id $pct
            Send-UsageAlert $row $r.Id $pct
        }
    }
    $ui.Stamp.Text = ('更新于 {0}' -f [datetime]::Now.ToString('HH:mm'))
    if ($tipParts.Count -gt 0) {
        $tip = $tipParts -join '  '
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $ui.Tray.Text = $tip
    } elseif ($errors -gt 0) {
        $ui.Tray.Text = 'AI 用量读取失败'
    }
}

if ($Install) { Install-Widget; return }
if ($Uninstall) { Uninstall-Widget; return }
if ($AddAccount) { Add-CurrentAccount; return }

try {
    Write-WidgetLog 'starting widget'
    Ensure-SingleInstance
    if (-not (Test-Path -LiteralPath $script:VbsPath)) { try { Write-LauncherVbs } catch { } }
    New-WidgetForm
} catch {
    Write-WidgetLog ("fatal $($_.Exception.Message)")
    throw
}
