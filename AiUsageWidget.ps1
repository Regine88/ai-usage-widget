# Combined weekly usage card for Grok / Kimi / ChatGPT / Gemini / Command Code with
# the OpenRouter and DeepSeek balances. One window, one row per provider; Grok and
# ChatGPT expand to one row per account.

# Switches:
#   -Version         print the widget version and exit
#   -Demo            render fixed demo rows without credentials or network access
#   -Theme <name>    force the dark or light palette for this run
#   -Install         register the widget in the current user's startup folder
#   -Uninstall       remove the startup registration
#   -AddAccount      register the current ChatGPT / Codex account
#   -AddGrokAccount  register the current Grok account
#   -MigrateSecrets  migrate legacy project-local snapshots into DPAPI storage

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AddAccount,
    [switch]$AddGrokAccount,
    [switch]$MigrateSecrets,
    [switch]$Version,
    [switch]$Demo,
    [string]$Theme = '',
    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'

# Demo mode renders fixed rows so screenshots and UI checks need neither
# credentials nor network access; it never touches credentials, history or state.
$script:AppVersion = '0.11.0'
$script:DemoMode = $false

if ($Version) {
    Write-Host ('AI Usage Widget {0}' -f $script:AppVersion)
    return
}

function Get-TrustedPowerShellPath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw '未找到受信任的 PowerShell 路径'
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = Get-TrustedPowerShellPath
    $argList = @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden',
        '-File', $PSCommandPath
    )
    if ($Install) { $argList += '-Install' }
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($AddAccount) { $argList += '-AddAccount' }
    if ($AddGrokAccount) { $argList += '-AddGrokAccount' }
    if ($MigrateSecrets) { $argList += '-MigrateSecrets' }
    if ($Demo) { $argList += '-Demo' }
    if ($Theme) { $argList += @('-Theme', $Theme) }
    if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $argList += @('-IntervalSeconds', "$IntervalSeconds") }
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

$script:DemoMode = [bool]$Demo

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

$script:CommandCodeHomeDir = if ($env:COMMAND_CODE_HOME) { $env:COMMAND_CODE_HOME } else { Join-Path $env:USERPROFILE '.commandcode' }
$script:CommandCodeAuthPath = Join-Path $script:CommandCodeHomeDir 'auth.json'
$script:CommandCodeApiBaseUrl = 'https://api.commandcode.ai'
$script:CommandCodeUsagePageUrl = 'https://commandcode.ai/usage'
$script:CommandCodeShowBalance = $false
$script:CommandCodeDisplayName = 'Command Code'

$script:OpenRouterHomeDir = if ($env:OPENROUTER_HOME) { $env:OPENROUTER_HOME } else { Join-Path $env:USERPROFILE '.openrouter' }
$script:OpenRouterAuthPath = Join-Path $script:OpenRouterHomeDir 'auth.json'
$script:OpenRouterApiBaseUrl = 'https://openrouter.ai/api/v1'
$script:OpenRouterUsagePageUrl = 'https://openrouter.ai/settings/keys'
$script:OpenRouterDisplayName = 'OpenRouter'

$script:DeepSeekHomeDir = if ($env:DEEPSEEK_HOME) { $env:DEEPSEEK_HOME } else { Join-Path $env:USERPROFILE '.deepseek' }
$script:DeepSeekAuthPath = Join-Path $script:DeepSeekHomeDir 'auth.json'
$script:DeepSeekApiBaseUrl = 'https://api.deepseek.com'
$script:DeepSeekUsagePageUrl = 'https://platform.deepseek.com/usage'
$script:DeepSeekDisplayName = 'DeepSeek'

$script:UpdateRepoSlug = 'Regine88/ai-usage-widget'
$script:UpdateUserAgent = 'ai-usage-widget'
$script:UpdatePageUrl = 'https://github.com/' + $script:UpdateRepoSlug
$script:UpdateReleasesUrl = $script:UpdatePageUrl + '/releases'
$script:UpdateApiUrl = 'https://api.github.com/repos/' + $script:UpdateRepoSlug + '/releases/latest'

$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:WidgetDir = Split-Path -Parent $script:SelfPath
$script:SecureSnapshotRoot = Join-Path $env:LOCALAPPDATA 'AIUsageWidget\accounts'
$script:StatePath = Join-Path $script:WidgetDir 'ai-state.json'
$script:LogPath = Join-Path $script:WidgetDir 'ai-widget.log'
$script:HistoryPath = Join-Path $script:WidgetDir 'ai-history.jsonl'
$script:RequestEventsPath = Join-Path $script:WidgetDir 'ai-request-events.jsonl'
$script:VbsPath = Join-Path $script:WidgetDir 'Start-AiUsageWidget.vbs'
. (Join-Path $script:WidgetDir 'UsageValidation.ps1')
. (Join-Path $script:WidgetDir 'SecureSnapshot.ps1')
. (Join-Path $script:WidgetDir 'ApiKeyAuth.ps1')
. (Join-Path $script:WidgetDir 'GrokAccounts.ps1')
. (Join-Path $script:WidgetDir 'GeminiAntigravity.ps1')
. (Join-Path $script:WidgetDir 'KimiQuota.ps1')
. (Join-Path $script:WidgetDir 'CommandCodeQuota.ps1')
. (Join-Path $script:WidgetDir 'OpenRouterQuota.ps1')
. (Join-Path $script:WidgetDir 'DeepSeekQuota.ps1')
. (Join-Path $script:WidgetDir 'WidgetUpdates.ps1')
. (Join-Path $script:WidgetDir 'ModelRequestRecorder.ps1')
. (Join-Path $script:WidgetDir 'UsageHistory.ps1')
. (Join-Path $script:WidgetDir 'WidgetConfig.ps1')
. (Join-Path $script:WidgetDir 'WidgetPalette.ps1')
. (Join-Path $script:WidgetDir 'WidgetStrings.ps1')
. (Join-Path $script:WidgetDir 'WidgetLayout.ps1')
. (Join-Path $script:WidgetDir 'WidgetFormat.ps1')

# 配置与语言包要在任何输出之前就绪：CLI 开关（-Install 等）也会用到同一套文案。
try {
    $script:Config = Read-WidgetConfig
    $script:Language = ConvertTo-WidgetLanguage $script:Config.language
    $script:WidgetStrings = Read-WidgetStrings -Language $script:Language -Dir $script:WidgetDir
} catch {
    $script:Config = Convert-WidgetConfig $null
    $script:Language = ConvertTo-WidgetLanguage 'auto'
    $script:WidgetStrings = Get-WidgetStringFallback
}

# -Theme 只覆盖本次运行；配置文件仍然由设置面板写入。
if ($PSBoundParameters.ContainsKey('Theme')) {
    $script:Config.theme = ConvertTo-WidgetTheme $Theme
}

$script:Mutex = $null
$script:LastOkAt = $null
$script:FetchRunning = $false
$script:FetchJob = $null
$script:WorkerSrc = $null
$script:WorkerRs = $null
$script:Fonts = $null
$script:Alerted = @{}
$script:LastPct = @{}
$script:LastUsagePct = @{}
$script:FailCount = @{}
$script:BackoffUntil = @{}
$script:IntervalItems = @{}
$script:IntervalExplicit = $PSBoundParameters.ContainsKey('IntervalSeconds')
$script:Drag = $false
$script:DragOffset = [System.Drawing.Point]::Empty
$script:UiScale = $null
$script:UiMetrics = $null
$script:State = @{ x = $null; y = $null; topMost = $false; interval = $null }
# 配置在 CLI 文案之前就已读取，这里按主题取一次调色板：界面颜色全部来自它。
$script:Palette = Get-WidgetPalette $script:Config.theme
$script:TrendSeries = @{}

function Write-WidgetLog {
    param([string]$Message)
    try {
        $line = '{0:o} {1}' -f (Get-Date).ToUniversalTime(), (Convert-SafeLogText $Message)
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
        $f = Get-Item -LiteralPath $script:LogPath
        if ($f.Length -gt 512KB) {
            $tail = Get-Content -LiteralPath $script:LogPath -Tail 800
            Set-Content -LiteralPath $script:LogPath -Value $tail -Encoding utf8
        }
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
    try {
        $hwnd = [IntPtr]$Form.Handle
        $behind = [IntPtr]1
        $flags = [uint32]0x0013
        [void][NativeWin]::SetWindowPos($hwnd, $behind, 0, 0, 0, 0, $flags)
    } catch {
        Write-WidgetLog ("zorder $($_.Exception.Message)")
    }
}

function Set-UiColor {
    param($Control, [string]$Property, [int]$Argb)
    if (-not $Control) { return }
    try {
        $color = [System.Drawing.Color]::FromArgb($Argb)
        $prop = $Control.GetType().GetProperty($Property)
        if ($prop) { $prop.SetValue($Control, $color, $null) }
    } catch {
        try { $Control.$Property = [System.Drawing.Color]::FromArgb($Argb) } catch { }
    }
}

# Every UI colour comes from the palette: a missing key paints magenta, so a
# half-themed window is impossible to miss instead of silently turning black.
function Get-WidgetColor {
    param([string]$Name)
    $rgb = $null
    try { if ($script:Palette) { $rgb = $script:Palette[$Name] } } catch { }
    if (-not $rgb) { return [System.Drawing.Color]::FromArgb(255, 0, 255) }
    return [System.Drawing.Color]::FromArgb([int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
}

function Set-UiThemeColor {
    param($Control, [string]$Property, [string]$Name)
    Set-UiColor $Control $Property ((Get-WidgetColor $Name).ToArgb())
}

function Register-UiExceptionHandlers {
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
            [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    } catch { }
    try {
        [System.Windows.Forms.Application]::add_ThreadException({
            param($sender, $e)
            try {
                $ex = $e.Exception
                Write-WidgetLog ("thread $($ex.GetType().FullName): $($ex.Message)")
            } catch { }
        })
    } catch { }
    try {
        [AppDomain]::CurrentDomain.add_UnhandledException({
            param($sender, $e)
            try { Write-WidgetLog ("unhandled $($e.ExceptionObject)") } catch { }
        })
    } catch { }
}

function Get-UsageColor {
    param([double]$Percent)
    if ($Percent -ge 90) { return (Get-WidgetColor 'Danger') }
    if ($Percent -ge 70) { return (Get-WidgetColor 'Warning') }
    return (Get-WidgetColor 'Ok')
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
        if ($script:DemoMode) { return }
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

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    $msg = [string]$ErrorRecord.Exception.Message
    try {
        if ($ErrorRecord.Exception.InnerException) {
            $msg = $msg + ' ' + $ErrorRecord.Exception.InnerException.Message
        }
    } catch { }
    if ($msg -match 'HTTP (\d{3})\b') { return [int]$Matches[1] }
    if ($msg -match 'status code does not indicate success: (\d{3})') { return [int]$Matches[1] }
    return $null
}

# HttpClient can ignore -TimeoutSec on STA/MTA edges. Run each request in a
# nested runspace with a hard WaitOne so one slow provider cannot stall the worker.
function Invoke-WidgetRest {
    param(
        [ValidateSet('Get', 'Post')]$Method = 'Get',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        $Body,
        [string]$ContentType,
        [int]$TimeoutSec = 15
    )
    $Uri = Assert-TrustedHttpsHost $Uri
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
            $err = $null
            try { $err = $ps.Streams.Error | Select-Object -First 1 } catch { }
            if ($err -and $err.Exception) { throw $err.Exception }
            if ($err) { throw $err.ToString() }
            throw '请求失败'
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
    param([string]$Path = $script:GrokAuthPath)
    Read-GrokAuthFromFile -Path $Path
}

function Save-GrokAuth {
    param($Auth, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $path = $Auth.Path
    if (-not $path) { $path = $script:GrokAuthPath }
    if ($path -like '*.snapshot') {
        $raw = Update-SecureSnapshot -Provider grok -AccountId $Auth.AccountId -Update {
            param($current)
            $entry = if ($Auth.KeyName -and $current.PSObject.Properties[$Auth.KeyName]) {
                $current.PSObject.Properties[$Auth.KeyName].Value
            }
            if (-not $entry) { throw 'Grok 受保护凭据缺少账号条目' }
            [void]($entry.key = $AccessToken)
            if ($RefreshToken) { [void]($entry.refresh_token = $RefreshToken) }
            [void]($entry.expires_at = $ExpiresAt.ToUniversalTime().ToString('o'))
            return $current
        }
        $entry = if ($Auth.KeyName -and $raw.PSObject.Properties[$Auth.KeyName]) { $raw.PSObject.Properties[$Auth.KeyName].Value } else { $null }
        if (-not $entry) { throw 'Grok 受保护凭据缺少账号条目' }
    } else {
        Invoke-SecureSnapshotFileLock -Path $path -Action {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            $entry = if ($Auth.KeyName -and $raw.PSObject.Properties[$Auth.KeyName]) { $raw.PSObject.Properties[$Auth.KeyName].Value } else { $Auth.Entry }
            if (-not $entry) { throw 'Grok 登录文件缺少账号条目' }
            $entry.key = $AccessToken
            if ($RefreshToken) { $entry.refresh_token = $RefreshToken }
            $entry.expires_at = $ExpiresAt.ToUniversalTime().ToString('o')
            $json = $raw | ConvertTo-Json -Depth 8
            $tmp = "{0}.{1}.tmp" -f $path, ([guid]::NewGuid().ToString('n'))
            try {
                [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
                Move-SecureSnapshotFile -Source $tmp -Destination $path
            } finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        $entry = if ($Auth.KeyName -and $raw.PSObject.Properties[$Auth.KeyName]) { $raw.PSObject.Properties[$Auth.KeyName].Value } else { $Auth.Entry }
    }
    $Auth.Raw = $raw
    $Auth.Entry = $entry
    $Auth.Path = $path
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
    $expiresIn = Assert-PositiveFiniteNumber $resp.expires_in 'Grok expires_in'
    $expires = [datetime]::UtcNow.AddSeconds($expiresIn)
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.RefreshToken }
    Save-GrokAuth -Auth $Auth -AccessToken $resp.access_token -RefreshToken $newRefresh -ExpiresAt $expires
    $Auth.Token = [string]$resp.access_token
    $Auth.RefreshToken = $newRefresh
    $Auth.ExpiresAt = $expires
    Write-WidgetLog ('grok token refreshed for {0}' -f (Get-GrokRowName $Auth))
    return $Auth
}

function Sync-GrokAuthFromDisk {
    param($Auth)
    $path = $Auth.Path
    if (-not $path) { $path = $script:GrokAuthPath }
    $fresh = Read-GrokAuthFromFile -Path $path
    if (-not $fresh) { return $false }
    $changed = ($fresh.Token -ne $Auth.Token)
    $Auth.Token = $fresh.Token
    $Auth.RefreshToken = $fresh.RefreshToken
    $Auth.ClientId = $fresh.ClientId
    $Auth.ExpiresAt = $fresh.ExpiresAt
    $Auth.Raw = $fresh.Raw
    $Auth.Entry = $fresh.Entry
    $Auth.KeyName = $fresh.KeyName
    $Auth.Email = $fresh.Email
    $Auth.AccountId = $fresh.AccountId
    $Auth.Path = $fresh.Path
    return $changed
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
        if ($code -notin 401, 403) { throw }
        try {
            if (Sync-GrokAuthFromDisk $Auth) {
                return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-GrokAuthHeaders $Auth)
            }
        } catch { }
        $Auth = Update-GrokToken -Auth $Auth
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-GrokAuthHeaders $Auth)
    }
}

function Get-GrokUsageSnapshot {
    param($Auth)
    if (-not $Auth) { $Auth = Read-GrokAuthFromFile -Path $script:GrokAuthPath }
    $auth = $Auth
    if ($auth.ExpiresAt -and $auth.ExpiresAt.ToUniversalTime() -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-GrokToken -Auth $auth } catch { Write-WidgetLog "grok preemptive refresh failed: $($_.Exception.Message)" }
    }

    $credits = Invoke-GrokGet -Auth $auth -Url 'https://cli-chat-proxy.grok.com/v1/billing?format=credits'
    $cfg = $credits.config
    if (-not $cfg) { throw '用量接口没有返回 config' }

    $pct = $null
    if ($null -ne $cfg.creditUsagePercent) {
        $pct = Assert-UsagePercent $cfg.creditUsagePercent 'Grok creditUsagePercent'
    } elseif ($cfg.onDemandCap -and $null -ne $cfg.onDemandCap.val -and (Test-FiniteNumber $cfg.onDemandCap.val) -and [double]$cfg.onDemandCap.val -gt 0) {
        if (-not $cfg.onDemandUsed -or $null -eq $cfg.onDemandUsed.val -or -not (Test-FiniteNumber $cfg.onDemandUsed.val)) {
            throw 'Grok 用量接口缺少 onDemandUsed'
        }
        $used = [double]$cfg.onDemandUsed.val
        if ($used -lt 0) { throw 'Grok onDemandUsed 无效' }
        $pct = Assert-UsagePercent ([Math]::Round(100.0 * $used / [double]$cfg.onDemandCap.val, 1)) 'Grok calculated percent'
    } else {
        throw 'Grok 用量接口缺少 creditUsagePercent'
    }

    $end = $null
    if ($cfg.currentPeriod) { $end = Convert-ApiTime $cfg.currentPeriod.end }
    if (-not $end) { $end = Convert-ApiTime $cfg.billingPeriodEnd }

    $products = @()
    if ($cfg.productUsage) {
        foreach ($p in @($cfg.productUsage)) {
            $products += [pscustomobject]@{
                Name    = Get-ProductLabel ([string]$p.product)
                Percent = Assert-UsagePercent $p.usagePercent 'Grok product usagePercent'
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
    $oauth = Resolve-TrustedHttpsEndpoint $oauth @('auth.kimi.com', 'auth.kimi.ai')
    $base = Resolve-TrustedHttpsEndpoint $base @('api.kimi.com', 'api.kimi.ai')
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
    Invoke-SecureSnapshotFileLock -Path $script:KimiCredPath -Action {
        $raw = Get-Content -LiteralPath $script:KimiCredPath -Raw -Encoding utf8 | ConvertFrom-Json
        $raw.access_token = $AccessToken
        $raw.refresh_token = $RefreshToken
        $raw.expires_at = [long][DateTimeOffset]::new($ExpiresAt.ToUniversalTime()).ToUnixTimeSeconds()
        $json = $raw | ConvertTo-Json -Depth 8 -Compress
        $tmp = "{0}.{1}.tmp" -f $script:KimiCredPath, ([guid]::NewGuid().ToString('n'))
        try {
            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
            Move-SecureSnapshotFile -Source $tmp -Destination $script:KimiCredPath
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
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
    $expiresIn = Assert-PositiveFiniteNumber $resp.expires_in 'Kimi expires_in'
    $expires = [datetime]::UtcNow.AddSeconds($expiresIn)
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
        if ($code -notin 401, 403) { throw }
        try {
            $fresh = Read-KimiAuth
            if ($fresh.Token -and $fresh.Token -ne $Auth.Token) {
                $Auth.Token = $fresh.Token
                $Auth.Refresh = $fresh.Refresh
                $Auth.ExpiresAt = $fresh.ExpiresAt
                $headers.Authorization = "Bearer $($Auth.Token)"
                return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
            }
        } catch { }
        $Auth = Update-KimiToken -Auth $Auth
        $headers.Authorization = "Bearer $($Auth.Token)"
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
    }
}

function Get-KimiUsageSnapshot {
    $auth = Read-KimiAuth
    if ($auth.ExpiresAt -and $auth.ExpiresAt -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-KimiToken -Auth $auth } catch { Write-WidgetLog "kimi preemptive refresh failed: $($_.Exception.Message)" }
    }
    $hosts = Get-KimiHosts
    $data = Invoke-KimiGet -Auth $auth -Url "$($hosts.BaseUrl)/usages"
    $usage = Convert-KimiUsagePayload -Data $data
    Add-Member -InputObject $usage -NotePropertyName FetchedAt -NotePropertyValue ([datetime]::Now)
    return $usage
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

function Convert-CodexRawAuth {
    param(
        [Parameter(Mandatory)]$Raw,
        [string]$Path
    )
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
        Raw       = $raw
    }
}

function Read-CodexAuth {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        if ($Path -like '*.snapshot') {
            $raw = Read-SecureSnapshot -Path $Path
        } else {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        }
        return (Convert-CodexRawAuth -Raw $raw -Path $Path)
    } catch { return $null }
}

function Get-AccountLabel {
    param($Auth)
    if ($Auth.Email) { return (Get-AccountFingerprint -AccountId ([string]$Auth.Email) -Prefix 'ChatGPT') }
    if ($Auth.AccountId -and $Auth.AccountId.Length -ge 8) { return $Auth.AccountId.Substring(0, 8) }
    return 'ChatGPT'
}

function Get-CodexRowId {
    param($Auth)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'acct'
    if ($fingerprint) { return ('codex-{0}' -f $fingerprint) }
    return 'codex-unknown'
}

function Get-SnapshotPath {
    param([string]$AccountId)
    return (Get-SecureSnapshotPath -Provider codex -AccountId $AccountId)
}

function Get-LegacySnapshotPath {
    param([string]$AccountId)
    Join-Path $script:WidgetDir ("chatgpt-auth-{0}.json" -f ($AccountId -replace '[<>:"/\\|?*]', '_'))
}

function Get-CodexAccounts {
    $byId = [ordered]@{}
    $active = Read-CodexAuth $script:CodexAuthPath
    if ($active) { $byId[$active.AccountId] = $active }
    foreach ($f in @(Get-SecureSnapshotFiles -Provider codex)) {
        $snap = Read-CodexAuth $f.FullName
        if ($snap -and $snap.AccountId -and -not $byId.Contains($snap.AccountId)) { $byId[$snap.AccountId] = $snap }
    }
    foreach ($f in Get-ChildItem -LiteralPath $script:WidgetDir -Filter 'chatgpt-auth-*.json' -ErrorAction SilentlyContinue) {
        $snap = Read-CodexAuth $f.FullName
        if ($snap -and $snap.AccountId) {
            try {
                $securePath = Write-SecureSnapshot -Provider codex -AccountId $snap.AccountId -Value $snap.Raw
                $snap.Path = $securePath
                if (-not $byId.Contains($snap.AccountId)) { $byId[$snap.AccountId] = $snap }
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            } catch { }
        }
    }
    return @($byId.Values)
}

function Add-CurrentAccount {
    $active = Read-CodexAuth $script:CodexAuthPath
    if (-not $active) {
        Write-Host (T 'cli.codexAuthMissing')
        return
    }
    $snapPath = Write-SecureSnapshot -Provider codex -AccountId $active.AccountId -Value $active.Raw
    Write-Host (T 'cli.registered' @((Get-AccountLabel $active), $snapPath))
    Write-WidgetLog ("snapshot account {0}" -f (Get-AccountLabel $active))
}

function Add-CurrentGrokAccount {
    if (-not (Test-Path -LiteralPath $script:GrokAuthPath)) {
        Write-Host (T 'cli.grokAuthMissing')
        return
    }
    Sync-ActiveGrokSnapshot
    try {
        $active = Read-GrokAuthFromFile -Path $script:GrokAuthPath
        Write-Host (T 'cli.registeredGrok' @((Get-GrokRowName $active)))
        Write-WidgetLog ("snapshot grok {0}" -f (Get-GrokRowName $active))
    } catch {
        Write-WidgetLog ("snapshot grok failed: {0}" -f $_.Exception.Message)
    }
}

function Migrate-ProjectSnapshots {
    [void](Get-CodexAccounts)
    [void](Get-GrokAccounts)
    $remaining = @(
        Get-ChildItem -LiteralPath $script:WidgetDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'chatgpt-auth-*.json' -or $_.Name -like 'grok-auth-*.json' }
    )
    if ($remaining.Count -gt 0) {
        throw (T 'cli.migrateLeft' @((($remaining | ForEach-Object Name) -join ', ')))
    }
    Write-Host (T 'cli.migrateDone')
}

function Save-CodexAuth {
    param([string]$Path, [string]$AccessToken, [string]$RefreshToken, [string]$IdToken)
    if ($Path -like '*.snapshot') {
        $accountId = [string](Read-SecureSnapshot -Path $Path).tokens.account_id
        if (-not $accountId) { throw 'Codex 受保护凭据缺少 account_id' }
        $raw = Update-SecureSnapshot -Provider codex -AccountId $accountId -Update {
            param($current)
            if (-not $current.tokens) { throw 'Codex 受保护凭据缺少 tokens' }
            [void]($current.tokens.access_token = $AccessToken)
            [void]($current.tokens.refresh_token = $RefreshToken)
            if ($IdToken) { [void]($current.tokens.id_token = $IdToken) }
            [void]($current.last_refresh = (Get-Date).ToUniversalTime().ToString('o'))
            return $current
        }
        return
    }
    Invoke-SecureSnapshotFileLock -Path $Path -Action {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        $raw.tokens.access_token = $AccessToken
        $raw.tokens.refresh_token = $RefreshToken
        if ($IdToken) { $raw.tokens.id_token = $IdToken }
        $raw.last_refresh = (Get-Date).ToUniversalTime().ToString('o')
        $json = $raw | ConvertTo-Json -Depth 8
        $tmp = "{0}.{1}.tmp" -f $Path, ([guid]::NewGuid().ToString('n'))
        try {
            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
            Move-SecureSnapshotFile -Source $tmp -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
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

function Sync-CodexAuthFromDisk {
    param($Auth)
    $fresh = Read-CodexAuth -Path $Auth.Path
    if (-not $fresh) { return $false }
    $changed = ($fresh.Token -ne $Auth.Token)
    $Auth.Token = $fresh.Token
    $Auth.Refresh = $fresh.Refresh
    if ($fresh.AccountId) { $Auth.AccountId = $fresh.AccountId }
    if ($fresh.Email) { $Auth.Email = $fresh.Email }
    return $changed
}

function Get-CodexAuthHeaders {
    param($Auth)
    return @{
        Authorization        = "Bearer $($Auth.Token)"
        'ChatGPT-Account-Id' = $Auth.AccountId
        Accept               = 'application/json'
        'User-Agent'         = 'codex-cli'
    }
}

function Invoke-CodexGet {
    param($Auth, [string]$Url)
    try {
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-CodexAuthHeaders $Auth)
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -notin 401, 403) { throw }
        if (Sync-CodexAuthFromDisk $Auth) {
            try {
                return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-CodexAuthHeaders $Auth)
            } catch {
                $code = Get-HttpStatusCode $_
                if ($code -notin 401, 403) { throw }
            }
        }
        $Auth = Update-CodexToken -Auth $Auth
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers (Get-CodexAuthHeaders $Auth)
    }
}

function Get-CodexWindowInfo {
    param($Window)
    if (-not $Window) { return $null }
    if ($null -eq $Window.limit_window_seconds -or -not (Test-FiniteNumber $Window.limit_window_seconds)) { throw 'Codex 限额窗口缺少 limit_window_seconds' }
    if ($null -eq $Window.used_percent) { throw 'Codex 限额窗口缺少 used_percent' }
    $secs = [long]$Window.limit_window_seconds
    if ($secs -le 0) { throw 'Codex 限额窗口 limit_window_seconds 无效' }
    $pct = Assert-UsagePercent $Window.used_percent 'Codex used_percent'
    $resetAt = $null
    if ($Window.reset_at) {
        try { $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$Window.reset_at).UtcDateTime } catch { }
    }
    $label = $null
    if ($secs -gt 0) {
        $hours = $secs / 3600.0
        if ($hours -ge 24) { $label = T 'row.windowDays' @([int][Math]::Round($hours / 24.0)) }
        elseif ($hours -eq [int]$hours) { $label = T 'row.windowHours' @([int]$hours) }
        else { $label = T 'row.windowHoursFraction' @($hours) }
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
                try { [void](Write-SecureSnapshot -Provider codex -AccountId $acct.AccountId -Value $acct.Raw) } catch { }
            }
        }
    }
}

# --- Command Code ---

function Test-CommandCodeCredExists {
    return Test-Path -LiteralPath $script:CommandCodeAuthPath
}

function Read-CommandCodeAuth {
    if (-not (Test-Path -LiteralPath $script:CommandCodeAuthPath)) {
        throw '未找到 ~/.commandcode/auth.json，请先安装 Command Code 并登录'
    }
    $raw = Get-Content -LiteralPath $script:CommandCodeAuthPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $raw.apiKey) { throw 'auth.json 缺少 apiKey，请重新登录' }
    return [pscustomobject]@{
        ApiKey   = [string]$raw.apiKey
        UserId   = [string]$raw.userId
        UserName = [string]$raw.userName
        KeyName  = [string]$raw.keyName
    }
}

function Get-CommandCodeAuthHeaders {
    param($Auth)
    return @{
        Authorization = "Bearer $($Auth.ApiKey)"
        Accept        = 'application/json'
        'User-Agent'  = 'command-code'
    }
}

function Invoke-CommandCodeGet {
    param($Auth, [string]$Path)
    # Command Code auth.json is a login snapshot with no refresh flow: a 401 is
    # surfaced directly to Format-FetchError ("登录已过期") instead of retried.
    return Invoke-WidgetRest -Method Get -Uri "$($script:CommandCodeApiBaseUrl)$Path" -Headers (Get-CommandCodeAuthHeaders $Auth)
}

function Get-CommandCodeOrgId {
    param($Auth)
    try {
        $resp = Invoke-WidgetRest -Method Get -Uri "$($script:CommandCodeApiBaseUrl)/alpha/whoami" -Headers (Get-CommandCodeAuthHeaders $Auth)
        if ($resp.org -and $resp.org.id) { return [string]$resp.org.id }
    } catch { }
    return $null
}

function Get-CommandCodeUsageSnapshot {
    $auth = Read-CommandCodeAuth
    $orgId = Get-CommandCodeOrgId $auth
    $path = '/alpha/billing/credits'
    if ($orgId) { $path += '?orgId=' + [uri]::EscapeDataString($orgId) }
    $data = Invoke-CommandCodeGet -Auth $auth -Path $path
    return Convert-CommandCodeCredits $data
}

function Get-CommandCodeRowData {
    $u = Get-CommandCodeUsageSnapshot
    $details = @()
    if ($u.FiveHour) { $details += (T 'row.window5hPercent' @($u.FiveHour.Percent)) }
    if ($u.Weekly)   { $details += (T 'row.windowWeekPercent' @($u.Weekly.Percent)) }
    $details += Format-ResetText $u.PeriodEnd
    if ($script:CommandCodeShowBalance -and $null -ne $u.TotalRemaining) {
        $details += (T 'row.balanceUsd' @($u.TotalRemaining))
    }
    Write-WidgetLog ("usage commandcode {0} ok" -f $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.codexTip' @($script:CommandCodeDisplayName, (Format-PercentText $u.Percent)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
    }
}

# --- Bearer-token providers ---
# Credentials, auth headers and the authenticated GET are shared in ApiKeyAuth.ps1,
# so each provider below only keeps what is genuinely its own.

# --- OpenRouter ---

function Get-OpenRouterUsageSnapshot {
    param($Auth)
    $data = Invoke-ApiKeyGet -Auth $Auth -BaseUrl $script:OpenRouterApiBaseUrl -Path '/key'
    return Convert-OpenRouterCredits $data
}

function Get-OpenRouterRowData {
    param($Auth, [string]$Name, [string]$Id)
    $auth = if ($Auth) { $Auth } else { Read-ApiKeyAuth -AuthPath $script:OpenRouterAuthPath -EnvironmentValue $env:OPENROUTER_API_KEY }
    $usage = Get-OpenRouterUsageSnapshot -Auth $auth
    $display = if ($Name) { $Name } else { $script:OpenRouterDisplayName }
    $details = @()
    if ($usage.IsUnlimited) {
        $details += (T 'row.unlimited' @($usage.Spent))
    } else {
        $details += (T 'row.limitUsage' @($usage.Spent, $usage.Limit, $usage.Percent))
    }
    $percent = $usage.Percent
    if ($null -eq $percent) { $percent = 0.0 }
    Write-WidgetLog ("usage openrouter {0} ok" -f $percent)
    [pscustomobject]@{
        Percent = $percent
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.codexTip' @($display, (Format-PercentText $percent)))
        Reset   = $null
        ResetAt = $null
        FetchedAt = $usage.FetchedAt
    }
}

# --- DeepSeek ---

function Get-DeepSeekUsageSnapshot {
    param($Auth)
    $data = Invoke-ApiKeyGet -Auth $Auth -BaseUrl $script:DeepSeekApiBaseUrl -Path '/user/balance'
    return Convert-DeepSeekBalance $data
}

function Get-DeepSeekRowData {
    param($Auth, [string]$Name)
    $auth = if ($Auth) { $Auth } else { Read-ApiKeyAuth -AuthPath $script:DeepSeekAuthPath -EnvironmentValue $env:DEEPSEEK_API_KEY }
    $usage = Get-DeepSeekUsageSnapshot -Auth $auth
    $display = if ($Name) { $Name } else { $script:DeepSeekDisplayName }
    # 余额供应商没有可展示的百分比：主数值直接放金额，明细行只说充值与赠额的构成。
    $details = @()
    if (-not $usage.IsAvailable) { $details += (T 'row.balanceInsufficient') }
    $details += (T 'row.balanceToppedUp' @((Format-DeepSeekAmount $usage.ToppedUp $usage.Currency)))
    if ($usage.Granted -gt 0) {
        $details += (T 'row.balanceGranted' @((Format-DeepSeekAmount $usage.Granted $usage.Currency)))
    }
    Write-WidgetLog ("usage deepseek {0} ok" -f $usage.Display)
    [pscustomobject]@{
        Percent   = 0.0
        Display   = $usage.Display
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.balanceTip' @($display, $usage.Display))
        Reset     = $null
        ResetAt   = $null
        FetchedAt = $usage.FetchedAt
    }
}

# --- Rows / UI ---

function Get-DemoRowTable {
    return @(
        [pscustomobject]@{ Id = 'demo-grok'; Kind = 'grok'; Name = 'Grok a'; OpenUrl = $script:GrokUsagePageUrl; Percent = 9.0; Detail = ('Build 9% · ' + (T 'reset.daysHours' @(4, 22))); TrendPct = @(2, 3, 4, 5, 6, 7, 9) }
        [pscustomobject]@{ Id = 'demo-kimi'; Kind = 'kimi'; Name = 'Kimi'; OpenUrl = $script:KimiUsagePageUrl; Percent = 46.0; Detail = ((T 'row.window5hPercent' @(12)) + ' · ' + (T 'reset.daysHours' @(4, 4))); TrendPct = @(18, 24, 30, 35, 39, 43, 46) }
        [pscustomobject]@{ Id = 'demo-codex'; Kind = 'codex'; Name = 'ChatGPT-1f4a2c7e'; OpenUrl = $script:CodexUsagePageUrl; Percent = 74.0; Detail = ((T 'row.window5hPercent' @(31)) + ' · ' + (T 'reset.daysHours' @(5, 4))); TrendPct = @(52, 58, 63, 67, 70, 72, 74) }
        [pscustomobject]@{ Id = 'demo-commandcode'; Kind = 'commandcode'; Name = $script:CommandCodeDisplayName; OpenUrl = $script:CommandCodeUsagePageUrl; Percent = 93.0; Detail = ((T 'row.window5hPercent' @(41)) + ' · ' + (T 'row.windowWeekPercent' @(93)) + ' · ' + (T 'reset.daysHours' @(3, 6))); TrendPct = @(41, 55, 68, 79, 86, 90, 93) }
        [pscustomobject]@{ Id = 'demo-openrouter'; Kind = 'openrouter'; Name = 'OpenRouter-3ad9f1c7'; OpenUrl = $script:OpenRouterUsagePageUrl; Percent = 12.5; Detail = (T 'row.limitUsage' @(12.5, 100, 12.5)); TrendPct = @(1.5, 3, 4.5, 6, 8, 10, 12.5) }
        [pscustomobject]@{ Id = 'demo-deepseek'; Kind = 'deepseek'; Name = $script:DeepSeekDisplayName; OpenUrl = $script:DeepSeekUsagePageUrl; Percent = 0.0; Display = '¥14.00'; Detail = ((T 'row.balanceToppedUp' @('¥12.40')) + ' · ' + (T 'row.balanceGranted' @('¥1.60'))); TrendPct = @(0, 0, 0, 0, 0, 0, 0) }
    )
}

function Get-DemoFetchResults {
    param($Rows)
    $results = @()
    foreach ($row in @($Rows)) {
        $results += [pscustomobject]@{
            Id      = $row.Id
            Percent = [double]$row.Percent
            Display = [string]$row.Display
            Detail  = [string]$row.Detail
            Tip     = ('{0} {1}' -f $row.Name, (Format-PercentText $row.Percent))
            Reset   = $null
            ResetAt = (Get-Date).AddDays(4).ToString('o')
            Error   = $null
        }
    }
    return $results
}

function Get-ProviderRows {
    if ($script:DemoMode) { return @(Get-DemoRowTable) }
    $rows = @()
    try { Sync-ActiveGrokSnapshot } catch { Write-WidgetLog ("grok snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-GrokAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-GrokRowId $acct
            Kind    = 'grok'
            Name    = Get-GrokRowName $acct
            OpenUrl = $script:GrokUsagePageUrl
            Auth    = $acct
        }
    }
    if (Test-AntigravityCredExists) {
        $rows += [pscustomobject]@{
            Id      = 'gemini'
            Kind    = 'gemini'
            Name    = 'Gemini'
            OpenUrl = $script:GeminiUsagePageUrl
            Auth    = $null
        }
    }
    if (Test-Path -LiteralPath $script:KimiCredPath) {
        $rows += [pscustomobject]@{
            Id      = 'kimi'
            Kind    = 'kimi'
            Name    = 'Kimi'
            OpenUrl = $script:KimiUsagePageUrl
            Auth    = $null
        }
    }
    foreach ($acct in @(Get-CodexAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-CodexRowId $acct
            Kind    = 'codex'
            Name    = Get-AccountLabel $acct
            OpenUrl = $script:CodexUsagePageUrl
            Auth    = $acct
        }
    }
    if (Test-CommandCodeCredExists) {
        $rows += [pscustomobject]@{
            Id      = 'commandcode'
            Kind    = 'commandcode'
            Name    = $script:CommandCodeDisplayName
            OpenUrl = $script:CommandCodeUsagePageUrl
            Auth    = $null
        }
    }
    if (Test-ApiKeyCredExists -AuthPath $script:OpenRouterAuthPath -EnvironmentValue $env:OPENROUTER_API_KEY) {
        # 每个本机密钥一行，行名用密钥指纹，密钥本身不进入界面与日志。
        foreach ($key in @(Get-ApiKeySources -AuthPath $script:OpenRouterAuthPath -EnvironmentValue $env:OPENROUTER_API_KEY)) {
            $rowId = Get-OpenRouterRowId $key
            if (-not $rowId) { continue }
            $rows += [pscustomobject]@{
                Id      = $rowId
                Kind    = 'openrouter'
                Name    = (Get-OpenRouterKeyFingerprint $key)
                OpenUrl = $script:OpenRouterUsagePageUrl
                Auth    = [pscustomobject]@{ ApiKey = $key; ApiKeyCount = 1 }
            }
        }
    }
    if (Test-ApiKeyCredExists -AuthPath $script:DeepSeekAuthPath -EnvironmentValue $env:DEEPSEEK_API_KEY) {
        # DeepSeek 的余额挂在账号上，多把密钥仍然只显示一行。
        $rows += [pscustomobject]@{
            Id      = 'deepseek'
            Kind    = 'deepseek'
            Name    = $script:DeepSeekDisplayName
            OpenUrl = $script:DeepSeekUsagePageUrl
            Auth    = $null
        }
    }
    return $rows
}

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'AI 周用量.lnk'
}

function Get-LegacyStartupShortcutPaths {
    $dir = [Environment]::GetFolderPath('Startup')
    @(
        (Join-Path $dir 'Grok 周用量.lnk'),
        (Join-Path $dir 'Kimi 周用量.lnk'),
        (Join-Path $dir 'ChatGPT 周用量.lnk')
    )
}

function Remove-LegacyStartupShortcuts {
    foreach ($p in (Get-LegacyStartupShortcutPaths)) {
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Force } catch { }
        }
    }
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

sh.Run """" & exePath & """ -NoProfile -STA -WindowStyle Hidden -File """ & ps1Path & """", 0, False

' Prefer PowerShell 7 at its default install path, then Windows PowerShell 5.1.
Function FindPowerShell()
    Dim p
    FindPowerShell = ""
    p = "C:\Program Files\PowerShell\7\pwsh.exe"
    If fso.FileExists(p) Then
        FindPowerShell = p
        Exit Function
    End If
    p = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
    If fso.FileExists(p) Then FindPowerShell = p
End Function
'@
    # Write the bytes verbatim: Set-Content appends a platform newline, which turned the
    # tracked launcher into a permanently "modified" file in a git checkout.
    [IO.File]::WriteAllText($script:VbsPath, ($content.TrimEnd("`r", "`n") + "`n"), [Text.Encoding]::ASCII)
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
    Remove-LegacyStartupShortcuts
    New-Shortcut -Path (Get-StartupShortcutPath) -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc (T 'shortcut.desc')
    Write-Host (T 'startup.added' @($script:WidgetDir))
}

function Uninstall-Widget {
    $p = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    Remove-LegacyStartupShortcuts
    Write-Host (T 'startup.removed' @($script:WidgetDir))
}

function Ensure-SingleInstance {
    $name = if ($script:DemoMode) { 'Local\AiUsageDesktopWidgetDemo' } else { 'Local\AiUsageDesktopWidget' }
    $script:Mutex = New-Object System.Threading.Mutex($false, $name)
    $owned = $false
    try {
        $owned = $script:Mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # 上一实例崩溃后锁被遗弃，当前进程接管即可，不要让启动失败。
        $owned = $true
        Write-WidgetLog 'took over an abandoned single-instance mutex'
    }
    if (-not $owned) {
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
    Set-UiColor $lbl 'ForeColor' $Color.ToArgb()
    Set-UiColor $lbl 'BackColor' ([System.Drawing.Color]::Transparent.ToArgb())
    $lbl.TextAlign = [System.Drawing.ContentAlignment]$Align
    $lbl.Parent = $Parent
    return $lbl
}

function Test-WidgetPositionLocked {
    try { return [bool]$script:Config.lockPosition } catch { return $false }
}

function Bind-Drag {
    param($Control)
    $Control.Add_MouseDown({
        try {
            if ((Test-WidgetPositionLocked)) { return }
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:Ui -and $script:Ui.Form) {
                $script:Drag = $true
                $script:DragOffset = $_.Location
            }
        } catch { }
    })
    $Control.Add_MouseMove({
        try {
            if ((Test-WidgetPositionLocked)) { return }
            if ($script:Drag -and $_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:Ui -and $script:Ui.Form) {
                $script:Ui.Form.Left += [int]$_.X - [int]$script:DragOffset.X
                $script:Ui.Form.Top += [int]$_.Y - [int]$script:DragOffset.Y
            }
        } catch { }
    })
    $Control.Add_MouseUp({
        try {
            if ((Test-WidgetPositionLocked)) { $script:Drag = $false; return }
            if ($script:Drag -and $script:Ui -and $script:Ui.Form) {
                $script:Drag = $false
                $f = $script:Ui.Form
                $clamped = Get-ClampedLocation $f.Left $f.Top $f.Width $f.Height
                $f.Location = New-Object System.Drawing.Point ([int]$clamped.X), ([int]$clamped.Y)
                Save-State $f
                Send-BehindWindows $f
            }
        } catch { Write-WidgetLog ("drag $($_.Exception.Message)") }
    })
    $Control.Add_MouseDoubleClick({
        try {
            $tag = $this.Tag
            $url = if ($tag -is [hashtable]) { [string]$tag.Url } else { [string]$tag }
            if ($url) { Start-Process $url }
        } catch { }
    })
}

# The layout below is authored in 96-DPI pixels, but the widget runs DPI aware
# (Hide-ConsoleWindow calls SetProcessDPIAware), so fonts declared in points
# render at the device DPI. Scaling every literal by the device scale keeps the
# design proportions on 125%/150%/200% displays; otherwise the percent label and
# the detail line overflow their fixed-size boxes and get clipped.
function Get-UiScale {
    param($Form)
    if ($null -ne $script:UiScale) { return $script:UiScale }
    $dpi = 0.0
    try {
        if ($Form -and -not $Form.IsDisposed) {
            $null = $Form.Handle
            $dpi = [double]$Form.DeviceDpi
        }
    } catch { }
    if ($dpi -le 0) {
        try {
            $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
            try { $dpi = [double]$g.DpiX } finally { $g.Dispose() }
        } catch { }
    }
    if ($dpi -le 0 -or $dpi -gt 960) { $dpi = 96.0 }
    $script:UiScale = $dpi / 96.0
    return $script:UiScale
}

function Scale-Px {
    param([double]$Value)
    return [int][Math]::Round($Value * (Get-UiScale))
}

function Get-UiMetrics {
    param($Form)
    if ($null -ne $script:UiMetrics) { return $script:UiMetrics }
    $null = Get-UiScale $Form
    $layout = 'full'
    $showTrend = $true
    try {
        if ($script:Config) {
            $layout = [string]$script:Config.layout
            $showTrend = [bool]$script:Config.showTrend
        }
    } catch { }
    $script:UiMetrics = Get-WidgetLayoutMetrics -Scale (Get-UiScale) -Layout $layout -ShowTrend $showTrend
    return $script:UiMetrics
}

function Get-FormHeight {
    param([int]$RowCount)
    return (Get-WidgetFormHeight -Metrics (Get-UiMetrics) -RowCount $RowCount)
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

    $fg = (Get-WidgetColor 'Text')
    $muted = (Get-WidgetColor 'Muted')
    $m = Get-UiMetrics $Form
    if (-not $script:Fonts) {
        $script:Fonts = @{
            Name   = New-Object System.Drawing.Font('Segoe UI', [float]$m.FontName)
            Pct    = New-Object System.Drawing.Font('Segoe UI Semibold', [float]$m.FontPct)
            Detail = New-Object System.Drawing.Font('Segoe UI', [float]$m.FontDetail)
        }
    }
    $nameFont = $script:Fonts.Name
    $pctFont = $script:Fonts.Pct
    $detailFont = $script:Fonts.Detail
    $y = $m.TopPad
    foreach ($spec in $Specs) {
        $lblName = New-Label $Form "name-$y" $m.MarginX ($y + $m.NameTop) $m.NameW $m.NameH $nameFont $fg 'MiddleLeft'
        $lblName.Text = $spec.Name
        $lblName.Tag = $spec.OpenUrl
        $lblName.AutoEllipsis = $true
        $lblPct = New-Label $Form "pct-$y" ($m.MarginX + $m.NameW) $y $m.PctW $m.PctH $pctFont (Get-UsageColor 0) 'MiddleRight'
        $lblPct.Text = '--%'
        $lblPct.Tag = $spec.OpenUrl
        $lblPct.AutoEllipsis = $true

        $barBack = New-Object System.Windows.Forms.Panel
        $barBack.Location = New-Object System.Drawing.Point $m.MarginX, ($y + $m.BarTop)
        $barBack.Size = New-Object System.Drawing.Size $m.BarTrackW, $m.BarH
        Set-UiThemeColor $barBack 'BackColor' 'Track'
        $barBack.Parent = $Form
        $barBack.Tag = $spec.OpenUrl
        $barFill = New-Object System.Windows.Forms.Panel
        $barFill.Location = New-Object System.Drawing.Point 0, 0
        $barFill.Size = New-Object System.Drawing.Size $m.BarSeedW, $m.BarH
        Set-UiColor $barFill 'BackColor' ((Get-UsageColor 0).ToArgb())
        $barFill.Parent = $barBack
        $barFill.Tag = $spec.OpenUrl

        $lblDetail = $null
        if ($m.DetailH -gt 0) {
            $lblDetail = New-Label $Form "detail-$y" $m.MarginX ($y + $m.DetailTop) $m.ContentW $m.DetailH $detailFont $muted 'MiddleLeft'
            $lblDetail.Text = ''
            $lblDetail.Tag = $spec.OpenUrl
            $lblDetail.AutoEllipsis = $true
        }

        # The sparkline shares the progress-bar row; when it is hidden the bar
        # keeps the full width (BarTrackW == ContentW).
        $trend = $null
        if ($m.BarTrackW -lt $m.ContentW) {
            $trend = New-Object System.Windows.Forms.Panel
            $trend.Location = New-Object System.Drawing.Point ($m.MarginX + $m.BarTrackW + $m.TrendGap), ($y + $m.BarTop - $m.TrendPad)
            $trend.Size = New-Object System.Drawing.Size $m.TrendW, $m.TrendH
            Set-UiColor $trend 'BackColor' ([System.Drawing.Color]::Transparent.ToArgb())
            $trend.Tag = @{ Url = $spec.OpenUrl; Points = @(); Argb = (Get-UsageColor 0).ToArgb() }
            $trend.Parent = $Form
            # The event args only bind through an explicit param block; $this is
            # the panel and its Tag carries the points and the line color.
            $trend.Add_Paint({
                param($sender, $e)
                try {
                    $data = $sender.Tag
                    if (-not $data -or -not $data.Points -or $data.Points.Count -lt 2) { return }
                    $pts = New-Object 'System.Drawing.PointF[]' $data.Points.Count
                    for ($i = 0; $i -lt $data.Points.Count; $i++) {
                        $pts[$i] = [System.Drawing.PointF]::new([float]$data.Points[$i].X, [float]$data.Points[$i].Y)
                    }
                    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb([int]$data.Argb)), 1.4
                    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                    $e.Graphics.DrawLines($pen, $pts)
                    $pen.Dispose()
                } catch { }
            })
        }

        $rowControls = @($lblName, $lblPct, $barBack, $barFill)
        if ($lblDetail) { $rowControls += $lblDetail }
        if ($trend) { $rowControls += $trend }
        foreach ($c in $rowControls) {
            $c.ContextMenuStrip = $script:Ui.Menu
            Bind-Drag $c
        }
        foreach ($c in @($lblName, $lblPct, $barBack)) { [void]$script:Ui.RowControls.Add($c) }
        if ($lblDetail) { [void]$script:Ui.RowControls.Add($lblDetail) }
        if ($trend) { [void]$script:Ui.RowControls.Add($trend) }
        [void]$script:Ui.Rows.Add(@{
            Id       = $spec.Id
            Kind     = $spec.Kind
            Name     = $spec.Name
            Auth     = $spec.Auth
            Pct      = $lblPct
            BarFill  = $barFill
            Detail   = $lblDetail
            Trend    = $trend
            Controls = $rowControls
        })
        if ($script:Ui.Tip) {
            $initTip = (T 'tip.loading' @($spec.Name))
            foreach ($c in @($lblName, $lblPct, $barBack, $barFill)) {
                try { $script:Ui.Tip.SetToolTip($c, $initTip) } catch { }
            }
            if ($lblDetail) {
                try { $script:Ui.Tip.SetToolTip($lblDetail, $initTip) } catch { }
            }
        }
        $y += $m.RowH
    }

    if ($script:DemoMode) {
        foreach ($rowState in $script:Ui.Rows) {
            if (-not $rowState.Trend) { continue }
            $spec = @($Specs | Where-Object { $_.Id -eq $rowState.Id })[0]
            if (-not $spec -or -not $spec.TrendPct) { continue }
            $values = @($spec.TrendPct)
            $today = (Get-Date).Date
            $series = @()
            for ($i = 0; $i -lt $values.Count; $i++) {
                $series += @{ Day = $today.AddDays(-($values.Count - 1 - $i)); Pct = $values[$i] }
            }
            $lastValue = $values[$values.Count - 1]
            Set-RowTrend $rowState $series $lastValue
        }
    }

    $h = Get-FormHeight $Specs.Count
    $Form.Size = New-Object System.Drawing.Size($m.FormWidth, $h)
    $round = New-RoundRectPath 0 0 $Form.Width $Form.Height $m.Radius
    $old = $Form.Region
    try {
        $region = New-Object System.Drawing.Region($round)
        $Form.GetType().GetProperty('Region').SetValue($Form, $region, $null)
    } catch {
        $Form.Region = New-Object System.Drawing.Region($round)
    }
    if ($old) { try { $old.Dispose() } catch { } }
    $script:Ui.Stamp.Top = $h - $m.StampInset
    $script:Ui.Sig = (($Specs | ForEach-Object { $_.Id }) -join ',')
}

function Set-RowUsage {
    param($Row, [double]$Percent, [string]$Detail, [string]$Display)
    $colorPct = $Percent
    if ($Row.Kind -eq 'gemini') { $colorPct = [Math]::Max(0, [Math]::Min(100, 100.0 - $Percent)) }
    $argb = (Get-UsageColor $colorPct).ToArgb()
    $text = Format-RowValueText -Display $Display -Percent $Percent
    if ($Row.Pct.Text -ne $text) { $Row.Pct.Text = [string]$text }
    Set-UiColor $Row.Pct 'ForeColor' $argb
    Set-UiColor $Row.BarFill 'BackColor' $argb
    $track = (Get-UiMetrics).BarTrackW
    $w = [Math]::Max(0, [Math]::Min($track, [int][Math]::Round($track * $colorPct / 100.0)))
    if ($Row.BarFill.Width -ne $w) { $Row.BarFill.Width = $w }
    if ($Row.Detail) {
        if ($Row.Detail.Text -ne $Detail) { $Row.Detail.Text = [string]$Detail }
        Set-UiThemeColor $Row.Detail 'ForeColor' 'Muted'
    }
    return $text
}

function Set-RowError {
    param($Row, [string]$Message)
    if ($Row.Detail) {
        $Row.Detail.Text = [string]$Message
        Set-UiThemeColor $Row.Detail 'ForeColor' 'Danger'
    } elseif ($Row.Pct) {
        $Row.Pct.Text = [string]$Message
        Set-UiThemeColor $Row.Pct 'ForeColor' 'Danger'
    }
}

function Get-RecentRequestLabel {
    param($Row, [object[]]$Events)
    if (-not $Row) { return $null }
    $accountId = $null
    try { if ($Row.Auth -and $Row.Auth.AccountId) { $accountId = [string]$Row.Auth.AccountId } } catch { }
    $event = Get-LatestModelRequest -Path $script:RequestEventsPath -Provider $Row.Kind -AccountId $accountId -Events $Events
    if (-not $event -or -not $event.model) { return $null }
    $when = $null
    try { $when = [datetime]::Parse([string]$event.ts).ToLocalTime().ToString('HH:mm') } catch { }
    $state = if ($event.status -eq 'failed') { T 'row.requestFailed' } elseif ($event.status -eq 'started') { T 'row.requestRunning' } else { T 'row.requestDone' }
    $timeText = if ($when) { ' · ' + $when } else { '' }
    return (T 'row.latestRequest' @([string]$event.model, $state, $timeText))
}

# Row data builders are pure (no UI access) so they can run in the
# background fetch runspace; the UI thread only applies their results.
function Get-GrokRowData {
    param($Auth, [string]$Name, [string]$Id)
    if (-not $Auth) { $Auth = Read-GrokAuthFromFile -Path $script:GrokAuthPath }
    $u = Get-GrokUsageSnapshot -Auth $Auth
    $details = @()
    foreach ($p in @($u.Products)) {
        $details += ('{0} {1:0}%' -f $p.Name, $p.Percent)
    }
    $details += Format-ResetText $u.PeriodEnd
    if ($u.PrepaidCents -gt 0) {
        $details += (T 'row.extra' @($u.PrepaidCents / 100.0))
    }
    $logId = if ($Id) { $Id } else { 'grok' }
    $tipName = if ($Name) { $Name } else { 'Grok' }
    Write-WidgetLog ("usage {0} {1} ok" -f $logId, $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.grokTip' @($tipName, (Format-PercentText $u.Percent)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
    }
}

function Get-GeminiRowData {
    $u = Get-GeminiUsageSnapshot
    $details = @()
    if ($null -ne $u.Remain5h) { $details += (T 'row.remain5h' @($u.Remain5h)) }
    if ($null -ne $u.RemainWeekly) { $details += (T 'row.remainWeek' @($u.RemainWeekly)) }
    $details += Format-ResetText $u.PeriodEnd
    Write-WidgetLog ("usage gemini remain={0} ok" -f $u.Remaining)
    [pscustomobject]@{
        Percent = $u.Remaining
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.geminiTip' @((Format-PercentText $u.Remaining)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
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
        $details += (T 'row.monthlyExtra' @($symbol, ($u.ExtraCents / 100.0)))
    }
    Write-WidgetLog ("usage kimi {0} ok" -f $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.kimiTip' @((Format-PercentText $u.Percent)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
    }
}

function Get-CodexRowData {
    param($Auth, [string]$Name, [string]$Id)
    Write-WidgetLog ("codex fetch start {0}" -f $Id)
    $u = Get-CodexUsageSnapshot -Auth $Auth
    $details = @()
    if ($u.Burst -and $u.Burst.Label) { $details += ('{0} {1:0}%' -f $u.Burst.Label, $u.Burst.Percent) }
    $details += Format-ResetText $u.PeriodEnd
    if ($null -ne $u.Credits) { $details += (T 'row.balanceUsd' @($u.Credits)) }
    Write-WidgetLog ("usage {0} {1} ok" -f $Id, $u.Percent)
    [pscustomobject]@{
        Percent = $u.Percent
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.codexTip' @($Name, (Format-PercentText $u.Percent)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
    }
}

function New-SettingLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, $Color)
    if (-not $Color) { $Color = (Get-WidgetColor 'Text') }
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lbl = New-Label $Parent ("lbl-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) $X $Y 10 20 $font $Color 'MiddleLeft'
    $lbl.Text = $Text
    $lbl.AutoSize = $true
    return $lbl
}

function New-SettingCheckBox {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$Checked)
    $box = New-Object System.Windows.Forms.CheckBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point $X, $Y
    $box.AutoSize = $true
    $box.Checked = $Checked
    $box.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    Set-UiThemeColor $box 'ForeColor' 'Text'
    $box.Parent = $Parent
    return $box
}

function New-SettingNumber {
    param($Parent, [int]$X, [int]$Y, [int]$W, [double]$Value, [double]$Min, [double]$Max, [double]$Step, [int]$Decimals = 0)
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point $X, $Y
    $num.Size = New-Object System.Drawing.Size $W, (Scale-Px 24)
    $num.Minimum = [decimal]$Min
    $num.Maximum = [decimal]$Max
    $num.Increment = [decimal]$Step
    $num.DecimalPlaces = $Decimals
    $num.Value = [decimal]([Math]::Max($Min, [Math]::Min($Max, $Value)))
    $num.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-UiThemeColor $num 'BackColor' 'Field'
    Set-UiThemeColor $num 'ForeColor' 'Text'
    $num.Parent = $Parent
    return $num
}

function New-SettingText {
    param($Parent, [int]$X, [int]$Y, [int]$W, [string]$Value)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point $X, $Y
    $box.Size = New-Object System.Drawing.Size $W, (Scale-Px 24)
    $box.Text = $Value
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-UiThemeColor $box 'BackColor' 'Field'
    Set-UiThemeColor $box 'ForeColor' 'Text'
    $box.Parent = $Parent
    return $box
}

function New-SettingCombo {
    param($Parent, [int]$X, [int]$Y, [int]$W, [string[]]$Items, [int]$Index)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point $X, $Y
    $combo.Size = New-Object System.Drawing.Size $W, (Scale-Px 24)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$combo.Items.AddRange([object[]]$Items)
    if ($Index -ge 0 -and $Index -lt $Items.Count) { $combo.SelectedIndex = $Index }
    $combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    Set-UiThemeColor $combo 'BackColor' 'Field'
    Set-UiThemeColor $combo 'ForeColor' 'Text'
    $combo.Parent = $Parent
    return $combo
}

function New-SettingButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size (Scale-Px 84), (Scale-Px 28)
    $button.Location = New-Object System.Drawing.Point $X, $Y
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    Set-UiThemeColor $button 'BackColor' 'Button'
    Set-UiThemeColor $button 'ForeColor' 'Text'
    $button.Parent = $Parent
    return $button
}

# Settings dialog for ai-config.json. Everything is scaled with Scale-Px and
# uses auto-sized labels, so the 150% DPI layout stays readable.
# Saving applies the interval, opacity and row layout immediately; provider
# switches rebuild the rows on the next update.
function Show-WidgetSettings {
    $current = Convert-WidgetConfig $script:Config
    $muted = (Get-WidgetColor 'Muted')
    $languages = @('auto', 'zh-CN', 'en-US')
    $languageIndex = [Math]::Max(0, [Array]::IndexOf($languages, [string]$current.language))

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = (T 'settings.title')
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size ((Scale-Px 360), (Scale-Px 508))
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-UiThemeColor $dialog 'BackColor' 'Background'
    Set-UiThemeColor $dialog 'ForeColor' 'Text'

    $colLabel = Scale-Px 18
    $colValue = Scale-Px 124

    $chkTrend = New-SettingCheckBox $dialog (T 'settings.trend') $colLabel (Scale-Px 16) ([bool]$current.showTrend)
    $chkForecast = New-SettingCheckBox $dialog (T 'settings.forecast') (Scale-Px 208) (Scale-Px 16) ([bool]$current.showForecast)

    [void](New-SettingLabel $dialog (T 'settings.trendDays') $colLabel (Scale-Px 48) $muted)
    $numDays = New-SettingNumber $dialog $colValue (Scale-Px 48) (Scale-Px 70) $current.trendDays 1 14 1
    [void](New-SettingLabel $dialog (T 'settings.unitDays') (Scale-Px 204) (Scale-Px 48) $muted)

    [void](New-SettingLabel $dialog (T 'settings.interval') $colLabel (Scale-Px 78) $muted)
    $numInterval = New-SettingNumber $dialog $colValue (Scale-Px 78) (Scale-Px 70) $current.intervalSeconds 15 86400 15
    [void](New-SettingLabel $dialog (T 'settings.intervalHint') (Scale-Px 204) (Scale-Px 78) $muted)

    [void](New-SettingLabel $dialog (T 'settings.opacity') $colLabel (Scale-Px 108) $muted)
    $numOpacity = New-SettingNumber $dialog $colValue (Scale-Px 108) (Scale-Px 70) $current.opacity 0.5 1.0 0.02 2
    [void](New-SettingLabel $dialog (T 'settings.opacityHint') (Scale-Px 204) (Scale-Px 108) $muted)

    [void](New-SettingLabel $dialog (T 'settings.thresholds') $colLabel (Scale-Px 138) $muted)
    $txtThresholds = New-SettingText $dialog $colValue (Scale-Px 138) (Scale-Px 90) (($current.alertThresholds) -join ',')
    [void](New-SettingLabel $dialog (T 'settings.thresholdsHint') (Scale-Px 224) (Scale-Px 138) $muted)

    $chkQuiet = New-SettingCheckBox $dialog (T 'settings.quietHours') $colLabel (Scale-Px 170) ([bool]$current.quietHours.enabled)
    $txtQuietStart = New-SettingText $dialog (Scale-Px 124) (Scale-Px 170) (Scale-Px 62) ([string]$current.quietHours.start)
    [void](New-SettingLabel $dialog (T 'settings.quietTo') (Scale-Px 190) (Scale-Px 170) $muted)
    $txtQuietEnd = New-SettingText $dialog (Scale-Px 208) (Scale-Px 170) (Scale-Px 62) ([string]$current.quietHours.end)

    [void](New-SettingLabel $dialog (T 'settings.providers') $colLabel (Scale-Px 202) $muted)
    $chkGrok = New-SettingCheckBox $dialog 'Grok' $colValue (Scale-Px 200) ([bool]$current.providers.grok)
    $chkGemini = New-SettingCheckBox $dialog 'Gemini' (Scale-Px 208) (Scale-Px 200) ([bool]$current.providers.gemini)
    $chkKimi = New-SettingCheckBox $dialog 'Kimi' $colValue (Scale-Px 226) ([bool]$current.providers.kimi)
    $chkCodex = New-SettingCheckBox $dialog 'ChatGPT' (Scale-Px 208) (Scale-Px 226) ([bool]$current.providers.codex)
    $chkCommandCode = New-SettingCheckBox $dialog 'Command Code' $colValue (Scale-Px 252) ([bool]$current.providers.commandcode)
    $chkOpenRouter = New-SettingCheckBox $dialog 'OpenRouter' (Scale-Px 208) (Scale-Px 252) ([bool]$current.providers.openrouter)
    $chkDeepSeek = New-SettingCheckBox $dialog 'DeepSeek' $colValue (Scale-Px 278) ([bool]$current.providers.deepseek)

    [void](New-SettingLabel $dialog (T 'settings.language') $colLabel (Scale-Px 310) $muted)
    $comboItems = @((T 'settings.languageAuto'), (T 'settings.languageZh'), (T 'settings.languageEn'))
    $cmbLanguage = New-SettingCombo $dialog $colValue (Scale-Px 310) (Scale-Px 150) $comboItems $languageIndex

    [void](New-SettingLabel $dialog (T 'settings.theme') $colLabel (Scale-Px 340) $muted)
    $themes = @('dark', 'light')
    $themeIndex = [Math]::Max(0, [Array]::IndexOf($themes, [string]$current.theme))
    $themeItems = @((T 'settings.themeDark'), (T 'settings.themeLight'))
    $cmbTheme = New-SettingCombo $dialog $colValue (Scale-Px 340) (Scale-Px 150) $themeItems $themeIndex

    $chkCompact = New-SettingCheckBox $dialog (T 'settings.compact') $colLabel (Scale-Px 370) ([string]$current.layout -eq 'compact')
    $chkLock = New-SettingCheckBox $dialog (T 'settings.lockPosition') (Scale-Px 208) (Scale-Px 370) ([bool]$current.lockPosition)

    $lblStatus = New-SettingLabel $dialog (T 'settings.restartHint') $colLabel (Scale-Px 398) $muted

    $btnSave = New-SettingButton $dialog (T 'settings.save') (Scale-Px 176) (Scale-Px 428)
    $btnCancel = New-SettingButton $dialog (T 'settings.cancel') (Scale-Px 268) (Scale-Px 428)

    $dialog.AcceptButton = $btnSave
    $dialog.CancelButton = $btnCancel
    $btnCancel.Add_Click({ $dialog.Close() })
    $btnSave.Add_Click({
        try {
            $picked = @{
                intervalSeconds = [int]$numInterval.Value
                opacity         = [double]$numOpacity.Value
                showTrend       = [bool]$chkTrend.Checked
                showForecast    = [bool]$chkForecast.Checked
                trendDays       = [int]$numDays.Value
                language        = $languages[$cmbLanguage.SelectedIndex]
                alertThresholds = ConvertTo-ConfigThresholds ($txtThresholds.Text -split '[,;\s]+') @(70, 90)
                quietHours      = @{
                    enabled = [bool]$chkQuiet.Checked
                    start   = $txtQuietStart.Text
                    end     = $txtQuietEnd.Text
                }
                providers       = @{
                    grok        = [bool]$chkGrok.Checked
                    gemini      = [bool]$chkGemini.Checked
                    kimi        = [bool]$chkKimi.Checked
                    codex       = [bool]$chkCodex.Checked
                    commandcode = [bool]$chkCommandCode.Checked
                    openrouter  = [bool]$chkOpenRouter.Checked
                    deepseek    = [bool]$chkDeepSeek.Checked
                }
                theme           = $themes[$cmbTheme.SelectedIndex]
                layout          = $(if ($chkCompact.Checked) { 'compact' } else { 'full' })
                lockPosition    = [bool]$chkLock.Checked
                providerAlertThresholds = $current.providerAlertThresholds
            }
            $script:Config = Convert-WidgetConfig $picked
            $script:State.interval = [int]$script:Config.intervalSeconds
            if (-not $script:DemoMode) {
                [void](Write-WidgetConfig -Config $script:Config)
                Save-State $script:Ui.Form
            }
            Write-WidgetLog ('settings saved: interval={0}s opacity={1} trend={2} forecast={3} days={4} language={5} openrouter={6} deepseek={7} theme={8} layout={9} lock={10}' -f $script:Config.intervalSeconds, $script:Config.opacity, $script:Config.showTrend, $script:Config.showForecast, $script:Config.trendDays, $script:Config.language, $script:Config.providers.openrouter, $script:Config.providers.deepseek, $script:Config.theme, $script:Config.layout, $script:Config.lockPosition)
            Apply-WidgetConfig
            $dialog.Close()
        } catch {
            Write-WidgetLog ("settings save failed: $($_.Exception.Message)")
            $lblStatus.ForeColor = (Get-WidgetColor 'ErrorText')
            $lblStatus.Text = (T 'settings.saveFailed' @((Convert-SafeLogText $_.Exception.Message 80)))
        }
    })

    [void]$dialog.ShowDialog($script:Ui.Form)
    $dialog.Dispose()
}

# About dialog: version, licence, project link and a manual GitHub update check.
# The check runs synchronously on the UI thread; a manual click tolerates the
# short freeze and keeps the dialog free of extra moving parts. The version
# comparison itself lives in WidgetUpdates.ps1 and is covered by offline tests.
function Show-WidgetAbout {
    $muted = (Get-WidgetColor 'Muted')
    $linkColor = (Get-WidgetColor 'Link')

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = (T 'about.title')
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size ((Scale-Px 420), (Scale-Px 268))
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-UiThemeColor $dialog 'BackColor' 'Background'
    Set-UiThemeColor $dialog 'ForeColor' 'Text'

    $lblApp = New-SettingLabel $dialog (T 'app.title') (Scale-Px 18) (Scale-Px 16) $null
    $lblApp.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    [void](New-SettingLabel $dialog (T 'about.version' @($script:AppVersion)) (Scale-Px 18) (Scale-Px 48) $muted)
    [void](New-SettingLabel $dialog (T 'about.license') (Scale-Px 18) (Scale-Px 70) $muted)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $script:UpdatePageUrl
    $link.AutoSize = $true
    $link.Location = New-Object System.Drawing.Point ((Scale-Px 18), (Scale-Px 94))
    $link.LinkColor = $linkColor
    $link.ActiveLinkColor = $linkColor
    $link.VisitedLinkColor = $linkColor
    $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $link.Add_LinkClicked({ Start-Process $script:UpdatePageUrl })
    $link.Parent = $dialog

    $lblStatus = New-SettingLabel $dialog '' (Scale-Px 18) (Scale-Px 126) $null
    $lblStatus.MaximumSize = New-Object System.Drawing.Size ((Scale-Px 384), 0)

    $lblNotes = New-SettingLabel $dialog '' (Scale-Px 18) (Scale-Px 152) $muted
    $lblNotes.MaximumSize = New-Object System.Drawing.Size ((Scale-Px 384), 0)

    # 按钮宽度跟着文案走：英文按钮比中文长，固定宽度会把 Open download page 裁掉。
    $btnCheck = New-SettingButton $dialog (T 'about.checkUpdate') 0 (Scale-Px 222)
    $btnOpen = New-SettingButton $dialog (T 'about.openReleases') 0 (Scale-Px 222)
    $btnOpen.Visible = $false
    $btnClose = New-SettingButton $dialog (T 'about.close') 0 (Scale-Px 222)
    foreach ($button in @($btnClose, $btnOpen, $btnCheck)) {
        $button.AutoSize = $true
        $button.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $button.Padding = New-Object System.Windows.Forms.Padding ((Scale-Px 10), (Scale-Px 3), (Scale-Px 10), (Scale-Px 3))
    }
    # 隐藏的按钮不占位：先排「检查更新 + 关闭」，出现新版本后再把「打开下载页」排进去。
    $layoutButtons = {
        $order = @($btnCheck)
        if ($btnOpen.Visible) { $order += $btnOpen }
        $order += $btnClose
        $gap = Scale-Px 10
        $right = (Scale-Px 420) - (Scale-Px 18)
        $total = 0
        foreach ($button in $order) { $total += $button.Width }
        if (($total + $gap * ($order.Count - 1)) -gt ($right - (Scale-Px 18))) { $gap = Scale-Px 6 }
        $x = $right - $total - ($gap * ($order.Count - 1))
        foreach ($button in $order) {
            $button.Location = New-Object System.Drawing.Point $x, (Scale-Px 222)
            $x += $button.Width + $gap
        }
    }
    & $layoutButtons

    $btnClose.Add_Click({ $dialog.Close() })
    $dialog.CancelButton = $btnClose
    $btnOpen.Add_Click({ Start-Process $script:UpdateReleasesUrl })
    $btnCheck.Add_Click({
        $btnCheck.Enabled = $false
        $btnOpen.Visible = $false
        & $layoutButtons
        $lblNotes.Text = ''
        $lblStatus.ForeColor = $muted
        $lblStatus.Text = (T 'about.checking')
        # 同步请求前先把「正在检查…」画出来，否则窗口看起来像卡住了。
        $dialog.Refresh()
        try {
            $headers = @{
                'User-Agent' = $script:UpdateUserAgent
                'Accept'     = 'application/vnd.github+json'
            }
            $release = Invoke-WidgetRest -Uri $script:UpdateApiUrl -Headers $headers -TimeoutSec 15
            $info = Get-WidgetUpdateInfo -Release $release -CurrentVersion $script:AppVersion
            Write-WidgetLog ('update check: reason={0} latest={1}' -f $info.Reason, $info.LatestVersion)
            if ($info.HasUpdate) {
                $lblStatus.ForeColor = (Get-WidgetColor 'Success')
                $lblStatus.Text = (T 'about.updateAvailable' @($info.LatestVersion, $script:AppVersion))
                $lblNotes.Text = $(if ($info.Notes) { $info.Notes } else { $info.Name })
                $btnOpen.Visible = $true
                & $layoutButtons
            } elseif ($info.Reason -eq 'not-newer') {
                $lblStatus.Text = (T 'about.upToDate' @($script:AppVersion))
            } else {
                $lblStatus.Text = (T 'about.noRelease')
            }
        } catch {
            Write-WidgetLog ('update check failed: ' + (Convert-SafeLogText $_.Exception.Message 160))
            $lblStatus.ForeColor = (Get-WidgetColor 'ErrorText')
            $lblStatus.Text = (T 'about.checkFailed' @((Format-FetchError $_.Exception.Message)))
        } finally {
            $btnCheck.Enabled = $true
        }
    })

    [void]$dialog.ShowDialog($script:Ui.Form)
    $dialog.Dispose()
}
# Push the saved config into the live window without a restart.
function Apply-WidgetConfig {
    # 主题先换掉调色板，再重画窗口底色；行控件会在下一次 Update-Widget 时按新主题重建。
    try { $script:Palette = Get-WidgetPalette $script:Config.theme } catch { }
    try {
        if ($script:Ui -and $script:Ui.Form) {
            Set-UiThemeColor $script:Ui.Form 'BackColor' 'Background'
            $script:Ui.Form.Opacity = [double]$script:Config.opacity
        }
        if ($script:Ui -and $script:Ui.Stamp) {
            Set-UiThemeColor $script:Ui.Stamp 'ForeColor' 'Dim'
        }
    } catch { }
    try {
        if ($script:Ui -and $script:Ui.Form -and $script:Ui.Form.Tag) {
            $timer = $script:Ui.Form.Tag
            $timer.Interval = [Math]::Max(15000, [int]$script:Config.intervalSeconds * 1000)
        }
    } catch { }
    foreach ($sec in $script:IntervalItems.Keys) {
        try { $script:IntervalItems[$sec].Checked = ([int]$sec -eq [int]$script:Config.intervalSeconds) } catch { }
    }
    try {
        if ($script:Ui -and $script:Ui.LockItem) {
            $script:Ui.LockItem.Checked = [bool]$script:Config.lockPosition
        }
    } catch { }
    # Trend / layout switches change the bar track width and row height, so the
    # cached metrics, fonts and row signature are cleared to force a rebuild.
    $script:UiMetrics = $null
    $script:Fonts = $null
    if ($script:Ui) { $script:Ui.Sig = $null }
    Update-Widget
}
function New-WidgetForm {
    Read-State
    Hide-ConsoleWindow

    $form = New-Object System.Windows.Forms.Form
    $form.Text = (T 'app.title')
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $m = Get-UiMetrics $form
    $form.Size = New-Object System.Drawing.Size($m.FormWidth, (Get-FormHeight 3))
    Set-UiThemeColor $form 'BackColor' 'Background'
    $form.Opacity = [double]$script:Config.opacity
    $form.TopMost = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true, $null)

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($null -ne $script:State.x -and $null -ne $script:State.y) {
        $form.Location = Get-ClampedLocation ([int]$script:State.x) ([int]$script:State.y) $form.Width $form.Height
    } else {
        $form.Location = New-Object System.Drawing.Point ($wa.Right - $form.Width - $m.EdgeInset), ($wa.Top + $m.EdgeInset)
    }
    Write-WidgetLog ("form location $($form.Left),$($form.Top)")

    $round = New-RoundRectPath 0 0 $form.Width $form.Height $m.Radius
    try {
        $region = New-Object System.Drawing.Region($round)
        $form.GetType().GetProperty('Region').SetValue($form, $region, $null)
    } catch {
        $form.Region = New-Object System.Drawing.Region($round)
    }

    $dim = (Get-WidgetColor 'Dim')
    $footFont = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblStamp = New-Label $form 'stamp' $m.MarginX ($form.Height - $m.StampInset) $m.ContentW $m.StampH $footFont $dim 'MiddleCenter'
    $lblStamp.Text = ''

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRefresh = $menu.Items.Add((T 'menu.refresh'))
    $miInterval = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.interval')
    foreach ($sec in 60, 300, 900, 3600) {
        $item = $miInterval.DropDownItems.Add((T 'menu.intervalMinutes' @($sec / 60)))
        $item.Tag = $sec
        $script:IntervalItems[$sec] = $item
    }
    [void]$menu.Items.Add($miInterval)
    $miAddGrok = $menu.Items.Add((T 'menu.registerGrok'))
    $miAdd = $menu.Items.Add((T 'menu.registerChatgpt'))
    $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.openUsage')
    $miOpenGrok = $miOpen.DropDownItems.Add('Grok')
    $miOpenGemini = $miOpen.DropDownItems.Add('Gemini')
    $miOpenKimi = $miOpen.DropDownItems.Add('Kimi')
    $miOpenCodex = $miOpen.DropDownItems.Add('ChatGPT')
    $miOpenCommandCode = $miOpen.DropDownItems.Add('Command Code')
    $miOpenOpenRouter = $miOpen.DropDownItems.Add('OpenRouter')
    $miOpenDeepSeek = $miOpen.DropDownItems.Add('DeepSeek')
    [void]$menu.Items.Add($miOpen)
    $miExportCsv = $menu.Items.Add((T 'menu.exportCsv'))
    $miSettings = $menu.Items.Add((T 'menu.settings'))
    $miAbout = $menu.Items.Add((T 'menu.about'))
    $miTop = $menu.Items.Add((T 'menu.topMost'))
    $miTop.Checked = [bool]$script:State.topMost
    $miLock = $menu.Items.Add((T 'menu.lockPosition'))
    $miLock.Checked = [bool]$script:Config.lockPosition
    [void]$menu.Items.Add('-')
    $startupOn = Test-Path -LiteralPath (Get-StartupShortcutPath)
    $miStart = $menu.Items.Add($(if ($startupOn) { T 'menu.startupOff' } else { T 'menu.startupOn' }))
    [void]$menu.Items.Add('-')
    $miQuit = $menu.Items.Add((T 'menu.quit'))
    $form.ContextMenuStrip = $menu
    $form.TopMost = [bool]$script:State.topMost

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Text = (T 'app.trayTip')
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
        LockItem    = $miLock
        Rows        = @()
        RowControls = @()
        Sig         = ''
    }

    $form.ContextMenuStrip = $menu
    $lblStamp.ContextMenuStrip = $menu
    Bind-Drag $form
    Bind-Drag $lblStamp

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { try { Update-Widget } catch { Write-WidgetLog ("f5 $($_.Exception.Message)") } }
    })

    $miRefresh.Add_Click({ try { Update-Widget } catch { Write-WidgetLog ("refresh $($_.Exception.Message)") } })
    $miExportCsv.Add_Click({ Export-UsageHistoryInteractive })
    $miSettings.Add_Click({ Show-WidgetSettings })
    $miAbout.Add_Click({ Show-WidgetAbout })
    foreach ($sec in $script:IntervalItems.Keys) {
        $script:IntervalItems[$sec].Add_Click({
            $chosen = [int]$this.Tag
            $timer.Interval = [Math]::Max(15000, $chosen * 1000)
            if ($script:Config) { $script:Config.intervalSeconds = $chosen }
            $script:State.interval = $chosen
            if (-not $script:DemoMode) {
                try { [void](Write-WidgetConfig -Config $script:Config) } catch { }
                Save-State $form
            }
            foreach ($k in $script:IntervalItems.Keys) { $script:IntervalItems[$k].Checked = ([int]$k -eq $chosen) }
            try { Update-Widget } catch { Write-WidgetLog ("interval $($_.Exception.Message)") }
        })
    }
    $miAddGrok.Add_Click({
        Add-CurrentGrokAccount
        Update-Widget
    })
    $miAdd.Add_Click({
        Add-CurrentAccount
        Update-Widget
    })
    $miOpenGrok.Add_Click({ Start-Process $script:GrokUsagePageUrl })
    $miOpenGemini.Add_Click({ Start-Process $script:GeminiUsagePageUrl })
    $miOpenKimi.Add_Click({ Start-Process $script:KimiUsagePageUrl })
    $miOpenCodex.Add_Click({ Start-Process $script:CodexUsagePageUrl })
    $miOpenCommandCode.Add_Click({ Start-Process $script:CommandCodeUsagePageUrl })
    $miOpenOpenRouter.Add_Click({ Start-Process $script:OpenRouterUsagePageUrl })
    $miOpenDeepSeek.Add_Click({ Start-Process $script:DeepSeekUsagePageUrl })
    $miLock.Add_Click({
        $script:Config.lockPosition = -not [bool]$script:Config.lockPosition
        $miLock.Checked = [bool]$script:Config.lockPosition
        if (-not $script:DemoMode) {
            try { [void](Write-WidgetConfig -Config $script:Config) } catch { }
        }
    })
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
            $miStart.Text = (T 'menu.startupOn')
        } else {
            Write-LauncherVbs
            Remove-LegacyStartupShortcuts
            New-Shortcut -Path $path -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc (T 'shortcut.desc')
            $miStart.Text = (T 'menu.startupOff')
        }
    })
    $miQuit.Add_Click({ $form.Close() })
    $tray.Add_DoubleClick({
        $form.Visible = -not $form.Visible
        if ($form.Visible) { $form.Activate() }
    })

    $configPath = Get-WidgetConfigPath
    $intervalSec = Resolve-RefreshInterval -Explicit $script:IntervalExplicit -ExplicitValue $IntervalSeconds -Config $script:Config -State $script:State -ConfigFileExists (Test-Path -LiteralPath $configPath)
    if (-not $script:IntervalExplicit -and -not (Test-Path -LiteralPath $configPath) -and $script:State.interval -and $script:Config) {
        $script:Config.intervalSeconds = $intervalSec
        if (-not $script:DemoMode) {
            try { [void](Write-WidgetConfig -Config $script:Config) } catch { }
        }
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(15000, $intervalSec * 1000)
    $timer.Add_Tick({
        try { Update-Widget } catch { Write-WidgetLog ("tick $($_.Exception.Message)`n$($_.ScriptStackTrace)") }
    })
    $form.Tag = $timer
    foreach ($k in $script:IntervalItems.Keys) { $script:IntervalItems[$k].Checked = ([int]$k -eq [int]$intervalSec) }

    # Fast poll timer: picks up background fetch results on the UI thread.
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 300
    $pollTimer.Add_Tick({
        try { Receive-BackgroundFetch } catch { Write-WidgetLog ("poll $($_.Exception.Message)`n$($_.ScriptStackTrace)") }
    })
    $script:Ui.Poll = $pollTimer

    $form.Add_Deactivate({
        try { Send-BehindWindows $form } catch { Write-WidgetLog ("deactivate $($_.Exception.Message)") }
    })
    $form.Add_Shown({
        try {
            Write-WidgetLog 'form shown'
            Send-BehindWindows $form
            $timer.Start()
            Write-WidgetLog 'timer started'
            Update-Widget
        } catch { Write-WidgetLog ("shown $($_.Exception.Message)`n$($_.ScriptStackTrace)") }
    })
    $form.Add_FormClosed({
        Write-WidgetLog 'form closed'
        try { $timer.Stop(); $timer.Dispose() } catch { }
        try { $pollTimer.Stop(); $pollTimer.Dispose() } catch { }
        Close-WorkerRunspace
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
    Register-UiExceptionHandlers

    Write-WidgetLog 'run loop'
    [System.Windows.Forms.Application]::Run([System.Windows.Forms.Form]$form)
    Write-WidgetLog 'run ended'
}

function Test-ProviderBackoff {
    param([string]$Id)
    if (-not $script:BackoffUntil.ContainsKey($Id)) { return $false }
    if ([datetime]::UtcNow -ge $script:BackoffUntil[$Id]) {
        $script:BackoffUntil.Remove($Id)
        return $false
    }
    return $true
}

function Register-ProviderSuccess {
    param([string]$Id)
    if (-not $Id) { return }
    $script:FailCount[$Id] = 0
    if ($script:BackoffUntil.ContainsKey($Id)) { $script:BackoffUntil.Remove($Id) }
}

function Register-ProviderFailure {
    param([string]$Id)
    $n = 1
    if ($script:FailCount.ContainsKey($Id)) { $n = [int]$script:FailCount[$Id] + 1 }
    $script:FailCount[$Id] = $n
    $sec = [int][Math]::Min(900, 30 * [Math]::Pow(2, [Math]::Min($n - 1, 5)))
    $script:BackoffUntil[$Id] = [datetime]::UtcNow.AddSeconds($sec)
    Write-WidgetLog ("backoff {0} for {1}s after {2} fail(s)" -f $Id, $sec, $n)
}

function Update-Widget {
    $ui = $script:Ui
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    if ($script:FetchRunning) { return }

    try {
        $specs = @(Get-ProviderRows | Where-Object { Test-ProviderEnabled $script:Config $_.Kind })
    } catch {
        Write-WidgetLog ("rows $($_.Exception.Message)")
        return
    }
    $accounts = @($specs | Where-Object { $_.Kind -eq 'codex' } | ForEach-Object { $_.Auth })
    if ($accounts.Count -gt 0) { Sync-ActiveCodexSnapshot $accounts }

    $sig = (($specs | ForEach-Object { $_.Id }) -join ',')
    if ($sig -ne $ui.Sig) {
        Rebuild-ProviderRows $ui.Form $specs
        Write-WidgetLog ("rows rebuilt: {0}" -f $sig)
    }

    if ($specs.Count -eq 0) {
        $ui.Stamp.Text = (T 'status.noCredentials')
        if ($ui.Tray) { $ui.Tray.Text = (T 'app.trayTip') }
        return
    }
    if ($script:DemoMode) {
        Apply-FetchResults (Get-DemoFetchResults $specs)
        $ui.Stamp.Text = (T 'app.demoStamp')
        return
    }

    $script:FetchRunning = $true
    try {
        Start-BackgroundFetch $specs
    } catch {
        $script:FetchRunning = $false
        $safeError = Convert-SafeLogText $_.Exception.Message 80
        $ui.Stamp.Text = (T 'status.startFailed' @($safeError))
        Write-WidgetLog ("start fetch failed: {0}" -f $safeError)
    }
}

# Fetch usage off the UI thread so the card stays responsive while HTTP
# requests are in flight. One MTA worker fetches every provider (each in
# its own try/catch) so WinForms STA is never blocked. The worker gets
# copies of the fetch functions plus config paths via $script: variables.
function Get-WorkerScriptSource {
    $fnNames = @(
        'Write-WidgetLog', 'Convert-ApiTime', 'Get-HttpStatusCode', 'Invoke-WidgetRest',
        'Get-WidgetText', 'T',
        'Format-PercentText', 'Format-RowValueText', 'Format-ResetText', 'Format-ResetTime', 'ConvertTo-ResetStamp', 'Format-FetchError',
        'Test-FiniteNumber', 'Assert-UsagePercent', 'Assert-PositiveFiniteNumber', 'Convert-UsageRatioPercent',
        'Resolve-TrustedHttpsEndpoint', 'Get-WidgetTrustedHosts', 'Assert-TrustedHttpsHost', 'Get-AccountFingerprint', 'Convert-SafeLogText',
        'Get-SecureSnapshotRoot', 'Get-SecureSnapshotPath', 'ConvertTo-SnapshotCipherText',
        'ConvertFrom-SnapshotCipherText', 'Set-SecureSnapshotAcl', 'Invoke-SecureSnapshotFileLock', 'Move-SecureSnapshotFile',
        'Write-SecureSnapshotLocked', 'Write-SecureSnapshot', 'Update-SecureSnapshot', 'Read-SecureSnapshot',
        'Get-SecureSnapshotFiles', 'Remove-SecureSnapshot',
        'Get-GrokAccountId', 'Get-GrokAccountFingerprint', 'Get-GrokAccountAlias', 'Get-GrokAliasPath', 'Get-GrokAliasMap',
        'Get-GrokAccountLabel', 'Get-GrokRowName', 'Get-GrokRowId',
        'Get-GrokSnapshotFileName', 'Get-GrokSnapshotPath', 'Get-GrokLegacySnapshotPath', 'Convert-GrokRawAuth', 'Read-GrokAuthFromFile',
        'Get-GrokAccounts', 'Sync-ActiveGrokSnapshot', 'Sync-GrokAuthFromDisk',
        'Get-ProductLabel', 'Read-GrokAuth', 'Save-GrokAuth', 'Update-GrokToken',
        'Get-GrokAuthHeaders', 'Invoke-GrokGet', 'Get-GrokUsageSnapshot', 'Get-GrokRowData',
        'Ensure-AntigravityCredType', 'Test-AntigravityCredExists', 'Read-AntigravityCred',
        'Save-AntigravityCred', 'Update-AntigravityToken', 'Get-AntigravityAuth',
        'Convert-GeminiQuota', 'Invoke-AntigravityQuota', 'Get-GeminiUsageSnapshot', 'Get-GeminiRowData',
        'Get-KimiHosts', 'Read-KimiAuth', 'Save-KimiAuth', 'Update-KimiToken',
        'Invoke-KimiGet', 'Get-KimiWindowLabel', 'Resolve-KimiUsedLimit', 'Convert-KimiUsagePayload',
        'Get-KimiUsageSnapshot', 'Get-KimiRowData',
        'Get-TokenEmail', 'Convert-CodexRawAuth', 'Read-CodexAuth', 'Get-AccountLabel', 'Save-CodexAuth',
        'Update-CodexToken', 'Sync-CodexAuthFromDisk', 'Get-CodexAuthHeaders',
        'Invoke-CodexGet', 'Get-CodexWindowInfo', 'Get-CodexUsageSnapshot', 'Get-CodexRowData',
        'Test-CommandCodeCredExists', 'Read-CommandCodeAuth', 'Get-CommandCodeAuthHeaders',
        'Invoke-CommandCodeGet', 'Get-CommandCodeOrgId', 'Convert-CCWindow',
        'Convert-CommandCodeTime', 'Convert-CommandCodeCredits', 'Get-CommandCodeUsageSnapshot', 'Get-CommandCodeRowData',
        'Get-ConfigPropertyValue',
        'Get-ApiKeyFileSources', 'Get-ApiKeySources', 'Test-ApiKeyCredExists', 'Read-ApiKeyAuth', 'Get-ApiKeyAuthHeaders', 'Invoke-ApiKeyGet',
        'Get-OpenRouterKeyFingerprint', 'Get-OpenRouterRowId',
        'Convert-OpenRouterCredits', 'Get-OpenRouterUsageSnapshot', 'Get-OpenRouterRowData',
        'Get-DeepSeekCurrencySymbol', 'Format-DeepSeekAmount', 'ConvertTo-DeepSeekPurse', 'Convert-DeepSeekBalance',
        'Get-DeepSeekUsageSnapshot', 'Get-DeepSeekRowData'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('param($Rows, $Cfg)')
    [void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
    foreach ($v in 'GrokAuthPath', 'WidgetDir', 'KimiCredPath', 'KimiRegionPath', 'KimiOAuthClientId',
                   'CodexOAuthClientId', 'CodexTokenUrl', 'CodexUsageUrl', 'LogPath',
                   'AntigravityCredTarget', 'AntigravityClientId', 'AntigravityClientSecret',
                   'AntigravityTokenUrl', 'AntigravityQuotaUrl',
                   'CommandCodeAuthPath', 'CommandCodeApiBaseUrl', 'CommandCodeShowBalance', 'CommandCodeDisplayName',
                   'OpenRouterAuthPath', 'OpenRouterApiBaseUrl', 'OpenRouterDisplayName',
                   'DeepSeekAuthPath', 'DeepSeekApiBaseUrl', 'DeepSeekDisplayName', 'SecureSnapshotRoot',
                   'WidgetStrings', 'Language') {
        [void]$sb.AppendLine("`$script:$v = `$Cfg.$v")
    }
    foreach ($n in $fnNames) {
        [void]$sb.AppendLine(("function {0} {{" -f $n))
        [void]$sb.AppendLine((Get-Item "function:$n").Definition)
        [void]$sb.AppendLine('}')
    }
    [void]$sb.AppendLine(@'
$results = @()
foreach ($row in @($Rows)) {
    try {
        $d = $null
        switch ($row.Kind) {
            'grok'  { $d = Get-GrokRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            'gemini' { $d = Get-GeminiRowData }
            'kimi'  { $d = Get-KimiRowData }
            'codex' { $d = Get-CodexRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            'commandcode' { $d = Get-CommandCodeRowData }
            'openrouter' { $d = Get-OpenRouterRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            'deepseek' { $d = Get-DeepSeekRowData -Auth $row.Auth -Name $row.Name }
            default { throw '未找到登录凭证' }
        }
        $results += [pscustomobject]@{ Id = $row.Id; Percent = $d.Percent; Display = $d.Display; Detail = $d.Detail; Tip = $d.Tip; Reset = $d.Reset; ResetAt = $d.ResetAt; Error = $null }
    } catch {
            $results += [pscustomobject]@{ Id = $row.Id; Percent = $null; Detail = $null; Tip = $null; Reset = $null; ResetAt = $null; Error = (Convert-SafeLogText $_.Exception.Message 240) }
    }
}
$results
'@)
    return $sb.ToString()
}

function Start-BackgroundFetch {
    param($Specs)
    $cfg = @{
        GrokAuthPath       = $script:GrokAuthPath
        WidgetDir          = $script:WidgetDir
        KimiCredPath       = $script:KimiCredPath
        KimiRegionPath     = $script:KimiRegionPath
        KimiOAuthClientId  = $script:KimiOAuthClientId
        CodexOAuthClientId = $script:CodexOAuthClientId
        CodexTokenUrl      = $script:CodexTokenUrl
        CodexUsageUrl            = $script:CodexUsageUrl
        LogPath                  = $script:LogPath
        AntigravityCredTarget    = $script:AntigravityCredTarget
        AntigravityClientId      = $script:AntigravityClientId
        AntigravityClientSecret  = $script:AntigravityClientSecret
        AntigravityTokenUrl      = $script:AntigravityTokenUrl
        AntigravityQuotaUrl      = $script:AntigravityQuotaUrl
        CommandCodeAuthPath      = $script:CommandCodeAuthPath
        CommandCodeApiBaseUrl    = $script:CommandCodeApiBaseUrl
        CommandCodeShowBalance   = $script:CommandCodeShowBalance
        CommandCodeDisplayName   = $script:CommandCodeDisplayName
        OpenRouterAuthPath       = $script:OpenRouterAuthPath
        OpenRouterApiBaseUrl     = $script:OpenRouterApiBaseUrl
        OpenRouterDisplayName    = $script:OpenRouterDisplayName
        DeepSeekAuthPath         = $script:DeepSeekAuthPath
        DeepSeekApiBaseUrl       = $script:DeepSeekApiBaseUrl
        DeepSeekDisplayName      = $script:DeepSeekDisplayName
        SecureSnapshotRoot       = $script:SecureSnapshotRoot
        WidgetStrings            = $script:WidgetStrings
        Language                 = $script:Language
    }
    $rows = @()
    foreach ($s in $Specs) {
        if (Test-ProviderBackoff $s.Id) {
            Write-WidgetLog ("skip {0} (backoff)" -f $s.Id)
            continue
        }
        $rows += [pscustomobject]@{ Id = $s.Id; Kind = $s.Kind; Name = $s.Name; Auth = $s.Auth }
    }
    if ($rows.Count -eq 0) {
        $script:FetchRunning = $false
        return
    }
    if (-not $script:WorkerSrc) { $script:WorkerSrc = Get-WorkerScriptSource }
    if (-not $script:WorkerRs) {
        $script:WorkerRs = [runspacefactory]::CreateRunspace()
        $script:WorkerRs.ApartmentState = 'MTA'
        $script:WorkerRs.ThreadOptions = 'ReuseThread'
        $script:WorkerRs.Open()
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:WorkerRs
    [void]$ps.AddScript($script:WorkerSrc)
    [void]$ps.AddArgument($rows)
    [void]$ps.AddArgument($cfg)
    $handle = $ps.BeginInvoke()
    $script:FetchJob = @{
        Ps        = $ps
        Handle    = $handle
        StartedAt = Get-Date
    }
    $script:Ui.Stamp.Text = (T 'status.refreshing')
    $script:Ui.Poll.Start()
}

function Convert-FetchRow {
    param($Raw, [string]$FallbackId, [string]$FallbackError)
    $id = $FallbackId
    $err = $FallbackError
    $pct = $null
    $detail = $null
    $tip = $null
    $reset = $null
    $resetAt = $null
    $display = $null
    if ($null -ne $Raw) {
        try { if ($Raw.Id) { $id = [string]$Raw.Id } } catch { }
        try { if ($Raw.Error) { $err = [string]$Raw.Error } } catch { }
        try {
            if (-not $err) { $pct = Convert-OptionalNumber -Value $Raw.Percent -Field 'provider percent' }
        } catch { if (-not $err) { $err = $_.Exception.Message } }
        try { if ($Raw.Detail) { $detail = [string]$Raw.Detail } } catch { }
        try { if ($Raw.Tip) { $tip = [string]$Raw.Tip } } catch { }
        try { if ($Raw.Reset) { $reset = [string]$Raw.Reset } } catch { }
        try { if ($Raw.ResetAt) { $resetAt = [string]$Raw.ResetAt } } catch { }
        try { if ($Raw.Display) { $display = [string]$Raw.Display } } catch { }
    }
    if (-not $id) { $id = $FallbackId }
    [pscustomobject]@{
        Id      = $id
        Percent = $pct
        Display = $display
        Detail  = $detail
        Tip     = $tip
        Reset   = $reset
        ResetAt = $resetAt
        Error   = $err
    }
}

function Clear-FetchJobs {
    try { if ($script:Ui -and $script:Ui.Poll) { $script:Ui.Poll.Stop() } } catch { }
    if ($script:FetchJob) {
        try { $script:FetchJob.Ps.Stop() } catch { }
        try { $script:FetchJob.Ps.Dispose() } catch { }
        $script:FetchJob = $null
    }
    $script:FetchRunning = $false
}

function Close-WorkerRunspace {
    Clear-FetchJobs
    if ($script:WorkerRs) {
        try { $script:WorkerRs.Dispose() } catch { }
        $script:WorkerRs = $null
    }
}

function Receive-BackgroundFetch {
    $job = $script:FetchJob
    if (-not $job) {
        try { $script:Ui.Poll.Stop() } catch { }
        $script:FetchRunning = $false
        return
    }
    $done = $false
    try { $done = [bool]$job.Handle.IsCompleted } catch { $done = $false }
    if (-not $done) {
        if ((Get-Date) - $job.StartedAt -gt [timespan]::FromMinutes(3)) {
            Write-WidgetLog 'background fetch timed out, stopping'
            try { $job.Ps.Stop() } catch { }
            Clear-FetchJobs
            if ($script:Ui -and -not $script:Ui.Form.IsDisposed) { $script:Ui.Stamp.Text = (T 'status.refreshTimeout') }
        }
        return
    }
    $out = $null
    try {
        $iar = $job.Handle
        try { if ($iar.PSObject -and $iar.PSObject.BaseObject) { $iar = $iar.PSObject.BaseObject } } catch { }
        $out = $job.Ps.EndInvoke([System.IAsyncResult]$iar)
        if ($job.Ps.HadErrors) {
            $err0 = $null
            try { $err0 = $job.Ps.Streams.Error | Select-Object -First 1 } catch { }
            if ($err0) { Write-WidgetLog ("bg fetch error: {0}" -f $err0.ToString()) }
        }
    } catch {
        Write-WidgetLog ("bg fetch failed: {0}" -f $_.Exception.Message)
    }
    $batch = @()
    foreach ($item in @($out)) {
        $rowData = Convert-FetchRow $item
        if ($rowData.Id) { $batch += ,$rowData }
    }
    $psOld = $job.Ps
    $script:FetchJob = $null
    $script:FetchRunning = $false
    if (@($batch).Count -gt 0) {
        try {
            Apply-FetchResults @($batch)
            Write-WidgetLog ("applied {0}" -f @($batch).Count)
        } catch {
            Write-WidgetLog ("apply $($_.Exception.Message)`n$($_.ScriptStackTrace)")
        }
    } elseif ($script:Ui -and -not $script:Ui.Form.IsDisposed) {
        $script:Ui.Stamp.Text = (T 'status.updated' @([datetime]::Now.ToString('HH:mm')))
    }
    try { $psOld.Dispose() } catch { }
    try { if ($script:Ui -and $script:Ui.Poll) { $script:Ui.Poll.Stop() } } catch { }
}

function Set-RowTip {
    param($Row, $Lines)
    if (-not $script:Ui.Tip -or -not $Row.Controls) { return }
    $text = ($Lines | Where-Object { $_ }) -join "`n"
    foreach ($c in $Row.Controls) {
        try { $script:Ui.Tip.SetToolTip($c, $text) } catch { }
    }
}

function Set-RowTrend {
    param($Row, $Series, [double]$UsagePercent)
    if (-not $Row -or -not $Row.Trend) { return }
    $items = @($Series)
    if ($items.Count -lt 2) { return }
    $points = @(New-SparklinePath $items $Row.Trend.Width $Row.Trend.Height 2 8)
    $url = $null
    try { $url = $Row.Trend.Tag.Url } catch { }
    $Row.Trend.Tag = @{ Url = $url; Points = $points; Argb = (Get-UsageColor $UsagePercent).ToArgb() }
    $Row.Trend.Invalidate()
}

function Export-UsageHistoryInteractive {
    try {
        $stamp = [datetime]::Now.ToString('yyyyMMdd-HHmmss')
        $target = Join-Path $script:WidgetDir ('ai-usage-{0}.csv' -f $stamp)
        if (-not (Export-UsageHistoryCsv -Path $target -SourcePath $script:HistoryPath)) {
            [System.Windows.Forms.MessageBox]::Show((T 'csv.failed'), (T 'csv.title'), 'OK', 'Warning') | Out-Null
            return
        }
        Write-WidgetLog ("csv export {0}" -f $target)
        [System.Windows.Forms.MessageBox]::Show(
            (T 'csv.exported' @([Environment]::NewLine, $target)),
            (T 'csv.title'), 'OK', 'Information') | Out-Null
    } catch {
        Write-WidgetLog ("csv export failed: $($_.Exception.Message)")
    }
}

function Write-UsageHistory {
    param([string]$Id, [double]$Percent)
    try {
        if ($script:DemoMode) { return }
        $line = [pscustomobject]@{ ts = [datetime]::Now.ToString('o'); id = $Id; pct = $Percent } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $script:HistoryPath -Value $line -Encoding utf8
        $f = Get-Item -LiteralPath $script:HistoryPath
        if ($f.Length -gt 1MB) {
            $tail = Get-Content -LiteralPath $script:HistoryPath -Tail 2000
            Set-Content -LiteralPath $script:HistoryPath -Value $tail -Encoding utf8
        }
    } catch { }
}

function Send-UsageResetAlert {
    param($Row)
    if ($script:DemoMode) { return }
    if (Test-QuietHours $script:Config) { return }
    if (-not $Row -or $Row.Kind -eq 'deepseek') { return }
    $msg = T 'alert.reset' @($Row.Name)
    Write-WidgetLog ("reset-alert {0}" -f $Row.Id)
    try {
        $script:Ui.Tray.ShowBalloonTip(6000, (T 'alert.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

function Send-UsageAlert {
    param($Row, [string]$Id, [double]$Percent)
    if ($script:DemoMode) { return }
    if (Test-QuietHours $script:Config) { return }
    $usagePercent = Convert-DisplayPercentToUsagePercent $Percent $Row.Kind
    $level = 0
    foreach ($threshold in @(Resolve-AlertThresholds $script:Config $Row.Kind | Sort-Object)) {
        if ($usagePercent -ge $threshold) { $level = $threshold }
    }
    $prev = 0
    if ($script:Alerted.ContainsKey($Id)) { $prev = $script:Alerted[$Id] }
    if ($level -gt $prev) {
        $script:Alerted[$Id] = $level
        $msg = T 'alert.body' @($Row.Name, (Format-PercentText $usagePercent))
        Write-WidgetLog ("alert {0}: {1}" -f $Id, $msg)
        try {
            $script:Ui.Tray.ShowBalloonTip(6000, (T 'alert.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch { }
    } elseif ($level -eq 0 -and $prev -gt 0) {
        $script:Alerted[$Id] = 0
    }
}

function Apply-FetchResults {
    param($Results, [switch]$StillRunning)
    $ui = $script:Ui
    if (-not $ui -or $ui.Form.IsDisposed) { return }

    $requestEvents = @(Get-ModelRequestEvents -Path $script:RequestEventsPath -Limit 5000)
    $historyRecords = @()
    $wantTrend = $true
    $showForecast = $true
    $trendDays = 7
    try {
        if ($script:Config) {
            $wantTrend = [bool]$script:Config.showTrend
            $showForecast = [bool]$script:Config.showForecast
            $trendDays = [int]$script:Config.trendDays
        }
    } catch { }
    if ($wantTrend -or $showForecast) {
        $historyRecords = @(Read-UsageHistory -Path $script:HistoryPath -Limit 2000)
    }
    foreach ($r in @($Results)) {
        if (-not $r -or -not $r.Id) { continue }
        $row = @($ui.Rows | Where-Object { $_.Id -eq $r.Id })[0]
        if (-not $row) { continue }
        if ($r.Error) {
            Register-ProviderFailure $r.Id
            $safeError = Convert-SafeLogText ([string]$r.Error) 240
            Write-WidgetLog ("error {0}: {1}" -f $r.Id, $safeError)
            Set-RowError $row (Format-FetchError $safeError)
            Set-RowTip $row @((T 'tip.errorTitle' @($row.Name)), (Format-FetchError $safeError -Detail))
        } else {
            try {
                $pct = Assert-UsagePercent $r.Percent 'provider result percent'
            } catch {
                Register-ProviderFailure $r.Id
                $safeError = Convert-SafeLogText $_.Exception.Message
                Write-WidgetLog ("error {0}: {1}" -f $r.Id, $safeError)
                Set-RowError $row (Format-FetchError $safeError)
                Set-RowTip $row @((T 'tip.errorTitle' @($row.Name)), (Format-FetchError $safeError -Detail))
                continue
            }
            Register-ProviderSuccess $r.Id
            $recentRequest = Get-RecentRequestLabel $row $requestEvents
            $rowDetail = [string]$r.Detail
            if ($recentRequest) { $rowDetail = @($rowDetail, $recentRequest) -join ' · ' }
            Set-RowUsage $row $pct $rowDetail $r.Display
            $script:LastOkAt = Get-Date

            $forecastLine = $null
            if ($historyRecords.Count -gt 0) {
                $usagePct = Convert-DisplayPercentToUsagePercent $pct $row.Kind
                $series = @(Get-UsageHistoryDaySeries -Records $historyRecords -Id $r.Id -Days $trendDays -Kind $row.Kind)
                if ($wantTrend) { Set-RowTrend $row $series $usagePct }
                if ($showForecast) {
                    $forecastLine = Format-ForecastText (Get-UsageForecast -Series $series -CurrentPercent $usagePct -ResetAt $r.ResetAt)
                }
            }

            $delta = $null
            if ($script:LastPct.ContainsKey($r.Id)) { $delta = $pct - [double]$script:LastPct[$r.Id] }
            $script:LastPct[$r.Id] = $pct
            $usageNow = Convert-DisplayPercentToUsagePercent $pct $row.Kind
            if ($script:LastUsagePct.ContainsKey($r.Id) -and -not $r.Display) {
                if (Test-UsageResetTransition $script:LastUsagePct[$r.Id] $usageNow) {
                    Send-UsageResetAlert $row
                }
            }
            $script:LastUsagePct[$r.Id] = $usageNow

            $upd = T 'status.updated' @([datetime]::Now.ToString('HH:mm'))
            if ($null -ne $delta -and [Math]::Abs($delta) -ge 0.05) {
                $sign = if ($delta -gt 0) { '+' } else { '' }
                $upd += T 'status.delta' @($sign, $delta)
            }
            Set-RowTip $row @(
                (T 'tip.rowTitle' @($row.Name, (Format-RowValueText -Display $r.Display -Percent $pct))),
                [string]$r.Detail,
                $recentRequest,
                $forecastLine,
                $(if ($r.Reset) { T 'tip.resetAt' @([string]$r.Reset) }),
                $upd,
                (T 'tip.openUsage')
            )

            if ($null -eq $delta -or [Math]::Abs($delta) -ge 0.05) {
                Write-UsageHistory $r.Id $pct
            }
            Send-UsageAlert $row $r.Id $pct
        }
    }
    if ($StillRunning) {
        $ui.Stamp.Text = (T 'status.refreshing')
    } else {
        $ui.Stamp.Text = (T 'status.updated' @([datetime]::Now.ToString('HH:mm')))
    }
    $tipParts = @()
    foreach ($row in $ui.Rows) {
        if ($row.Pct -and $row.Pct.Text -and $row.Pct.Text -ne '--%') {
            $tipParts += ('{0} {1}' -f $row.Name, $row.Pct.Text)
        }
    }
    if ($tipParts.Count -gt 0) {
        $tip = $tipParts -join '  '
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $ui.Tray.Text = $tip
    } elseif (-not $StillRunning) {
        $ui.Tray.Text = (T 'error.readFailed')
    }
}

if ($Install) { Install-Widget; return }
if ($Uninstall) { Uninstall-Widget; return }
if ($AddAccount) { Add-CurrentAccount; return }
if ($AddGrokAccount) { Add-CurrentGrokAccount; return }
if ($MigrateSecrets) { Migrate-ProjectSnapshots; return }

try {
    Write-WidgetLog ('starting widget v{0}{1}' -f $script:AppVersion, $(if ($script:DemoMode) { ' (demo mode)' } else { '' }))
    Write-WidgetLog ('config interval={0}s language={1} trend={2} forecast={3}' -f $script:Config.intervalSeconds, $script:Config.language, $script:Config.showTrend, $script:Config.showForecast)
    Write-WidgetLog ('strings language={0} keys={1}' -f $script:Language, @($script:WidgetStrings.Keys).Count)
    Ensure-SingleInstance
    if (-not $script:DemoMode) {
        try { Remove-LegacyStartupShortcuts } catch { }
        if (-not (Test-Path -LiteralPath $script:VbsPath)) { try { Write-LauncherVbs } catch { } }
    }
    New-WidgetForm
} catch {
    Write-WidgetLog ("fatal $($_.Exception.Message)")
    throw
}
