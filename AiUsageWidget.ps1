# Combined weekly usage card for Grok / Kimi / ChatGPT / Gemini / Command Code with
# the OpenRouter and DeepSeek balances. One window, one row per provider; Grok and
# ChatGPT expand to one row per account.

# Switches:
#   -Version         print the widget version and exit
#   -Demo            render fixed demo rows without credentials or network access
#   -TrendWindow     open the trend chart window on startup (smoke checks, screenshots)
#   -Theme <name>    force the dark or light palette for this run
#   -Install         register the widget in the current user's startup folder
#   -Uninstall       remove the startup registration
#   -AddAccount       register the current ChatGPT / Codex account
#   -AddGrokAccount   register the current Grok account
#   -AddGeminiAccount register the current Antigravity Gemini account
#   -MigrateSecrets   migrate legacy project-local snapshots into DPAPI storage

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AddAccount,
    [switch]$AddGrokAccount,
    [switch]$AddGeminiAccount,
    [switch]$AddKimiAccount,
    [switch]$AddClaudeAccount,
    [switch]$AddCommandCodeAccount,
    [switch]$AddCursorAccount,
    [switch]$AddGlmAccount,
    [switch]$AddCopilotAccount,
    [switch]$MigrateSecrets,
    [switch]$Version,
    [switch]$Demo,
    [switch]$TrendWindow,
    [string]$Theme = '',
    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'

# Demo mode renders fixed rows so screenshots and UI checks need neither
# credentials nor network access; it never touches credentials, history or state.
$script:AppVersion = '0.16.0'
$script:DemoMode = $false
# 趋势图窗口按需创建：$script:TrendForm 保存当前窗口，关闭后置空再重建。
# 变量名不能叫 TrendWindow：脚本顶层的 $script:X 与 -X 开关参数是同一个变量，
# 那样写会把 -TrendWindow 开关本身覆盖成窗口对象。
$script:TrendWindowRequested = $false
$script:TrendDays = 7
$script:TrendForm = $null

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
    if ($AddGeminiAccount) { $argList += '-AddGeminiAccount' }
    if ($AddKimiAccount) { $argList += '-AddKimiAccount' }
    if ($AddClaudeAccount) { $argList += '-AddClaudeAccount' }
    if ($AddCommandCodeAccount) { $argList += '-AddCommandCodeAccount' }
    if ($AddCursorAccount) { $argList += '-AddCursorAccount' }
    if ($AddGlmAccount) { $argList += '-AddGlmAccount' }
    if ($AddCopilotAccount) { $argList += '-AddCopilotAccount' }
    if ($MigrateSecrets) { $argList += '-MigrateSecrets' }
    if ($Demo) { $argList += '-Demo' }
    if ($TrendWindow) { $argList += '-TrendWindow' }
    if ($Theme) { $argList += @('-Theme', $Theme) }
    if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $argList += @('-IntervalSeconds', "$IntervalSeconds") }
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

$script:DemoMode = [bool]$Demo
$script:TrendWindowRequested = [bool]$TrendWindow

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

$script:ClineProvidersPath = Join-Path $env:USERPROFILE '.cline\data\settings\providers.json'
$script:ClineUsageUrl = 'https://api.cline.bot/api/v1/users/me/plan/usage-limits'
$script:ClineRefreshUrl = 'https://api.cline.bot/api/v1/auth/refresh'
$script:ClineUsagePageUrl = 'https://app.cline.bot/dashboard/usage'
$script:ClineDisplayName = 'Cline'

$script:ClaudeHomeDir = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }
$script:ClaudeCredPath = Join-Path $script:ClaudeHomeDir '.credentials.json'
$script:ClaudeUsageUrl = 'https://api.anthropic.com/api/oauth/usage'
$script:ClaudeTokenUrl = 'https://platform.claude.com/v1/oauth/token'
$script:ClaudeTokenUrlLegacy = 'https://console.anthropic.com/v1/oauth/token'
$script:ClaudeOAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
$script:ClaudeUsagePageUrl = 'https://claude.ai/settings/usage'
$script:ClaudeDisplayName = 'Claude'

$script:CursorStateDbPath = if ($env:CURSOR_STATE_DB) { $env:CURSOR_STATE_DB } else { Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb' }
$script:CursorUsageUrl = 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage'
$script:CursorUsagePageUrl = 'https://cursor.com/dashboard/spending'
$script:CursorDisplayName = 'Cursor'

$script:ZaiHomeDir = if ($env:ZAI_HOME) { $env:ZAI_HOME } else { Join-Path $env:USERPROFILE '.zai' }
$script:ZhipuHomeDir = if ($env:ZHIPU_HOME) { $env:ZHIPU_HOME } else { Join-Path $env:USERPROFILE '.zhipu' }
$script:ZaiAuthPath = Join-Path $script:ZaiHomeDir 'auth.json'
$script:ZhipuAuthPath = Join-Path $script:ZhipuHomeDir 'auth.json'
$script:ZaiApiBaseUrl = 'https://api.z.ai'
$script:ZhipuApiBaseUrl = 'https://open.bigmodel.cn'
$script:ZaiUsagePageUrl = 'https://z.ai/manage-apikey/billing'
$script:ZaiDisplayName = 'GLM'
$script:BigModelAuthPath = if ($env:BIGMODEL_HOME) { Join-Path $env:BIGMODEL_HOME 'auth.json' } else { Join-Path $env:USERPROFILE '.bigmodel\auth.json' }
$script:ZcodeConfigPath = if ($env:ZCODE_CONFIG) { $env:ZCODE_CONFIG } else { Join-Path $env:USERPROFILE '.zcode\v2\config.json' }

$script:CopilotConfigDir = if ($env:COPILOT_CONFIG_DIR) { $env:COPILOT_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\github-copilot' }
$script:CopilotHostsPath = if ($env:GH_COPILOT_HOSTS) { $env:GH_COPILOT_HOSTS } else { Join-Path $script:CopilotConfigDir 'hosts.json' }
$script:CopilotAppsPath = Join-Path $script:CopilotConfigDir 'apps.json'
$script:CopilotOpencodeAuthPath = Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'
$script:CopilotUsageUrl = 'https://api.github.com/copilot_internal/user'
$script:CopilotUsagePageUrl = 'https://github.com/settings/copilot'
$script:CopilotDisplayName = 'Copilot'

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
. (Join-Path $script:WidgetDir 'WidgetProviders.ps1')
. (Join-Path $script:WidgetDir 'ApiKeyAuth.ps1')
. (Join-Path $script:WidgetDir 'GrokAccounts.ps1')
. (Join-Path $script:WidgetDir 'GeminiAntigravity.ps1')
. (Join-Path $script:WidgetDir 'KimiQuota.ps1')
. (Join-Path $script:WidgetDir 'CommandCodeQuota.ps1')
. (Join-Path $script:WidgetDir 'OpenRouterQuota.ps1')
. (Join-Path $script:WidgetDir 'DeepSeekQuota.ps1')
. (Join-Path $script:WidgetDir 'ClineQuota.ps1')
. (Join-Path $script:WidgetDir 'ClaudeQuota.ps1')
. (Join-Path $script:WidgetDir 'CursorQuota.ps1')
. (Join-Path $script:WidgetDir 'ZaiQuota.ps1')
. (Join-Path $script:WidgetDir 'CopilotQuota.ps1')
. (Join-Path $script:WidgetDir 'WidgetUpdates.ps1')
. (Join-Path $script:WidgetDir 'ModelRequestRecorder.ps1')
. (Join-Path $script:WidgetDir 'UsageHistory.ps1')
. (Join-Path $script:WidgetDir 'UsageReport.ps1')
. (Join-Path $script:WidgetDir 'WidgetTrend.ps1')
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
$script:WorkerPool = $null
$script:FetchGeneration = 0
$script:Fonts = $null
$script:Alerted = @{}
$script:LastPct = @{}
$script:LastUsagePct = @{}
$script:RowState = @{}
$script:AccountSpecs = @()
$script:CurrentSpecs = @()
$script:FailCount = @{}
$script:BackoffUntil = @{}
$script:IntervalItems = @{}
$script:IntervalExplicit = $PSBoundParameters.ContainsKey('IntervalSeconds')
$script:Drag = $false
$script:DragOffset = [System.Drawing.Point]::Empty
$script:UiScale = $null
$script:UiMetrics = $null
$script:State = @{ x = $null; y = $null; topMost = $false; interval = $null; lastSummaryDate = $null }
# 配置在 CLI 文案之前就已读取，这里按主题取一次调色板：界面颜色全部来自它。
$script:Palette = Get-WidgetPalette $script:Config.theme
$script:TrendSeries = @{}
$script:CursorTokenCache = $null

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

if (-not $script:DemoMode) {
    try {
        [void](Import-UsageHistoryLegacy -Path $script:HistoryPath)
        [void](Invoke-UsageHistoryRetention -Path $script:HistoryPath -RetentionDays $script:Config.historyRetentionDays -MaxBytes $script:Config.historyMaxBytes)
    } catch {
        Write-WidgetLog ('history initialize failed: ' + $_.Exception.Message)
    }
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
        if ($raw.lastSummaryDate) { $script:State.lastSummaryDate = [string]$raw.lastSummaryDate }
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
        if ($script:State.lastSummaryDate) { $json.lastSummaryDate = [string]$script:State.lastSummaryDate }
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

function Set-GrokAuthFields {
    param($Raw, [string]$KeyName, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $entry = if ($KeyName -and $Raw.PSObject.Properties[$KeyName]) {
        $Raw.PSObject.Properties[$KeyName].Value
    } else {
        $null
    }
    if (-not $entry) { throw 'Grok 登录文件缺少账号条目' }
    [void]($entry.key = $AccessToken)
    if ($RefreshToken) { [void]($entry.refresh_token = $RefreshToken) }
    $expires = $ExpiresAt.ToUniversalTime().ToString('o')
    if ($entry.PSObject.Properties['expires_at']) { $entry.expires_at = $expires }
    else { Add-Member -InputObject $entry -NotePropertyName expires_at -NotePropertyValue $expires -Force }
    return $Raw
}

function Save-GrokAuth {
    param($Auth, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $path = $Auth.Path
    if (-not $path) { $path = $script:GrokAuthPath }
    if ($path -like '*.snapshot') {
        $raw = Update-SecureSnapshot -Provider grok -AccountId $Auth.AccountId -Update {
            param($current)
            $currentAuth = Convert-GrokRawAuth -Raw $current -Path $path
            Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
            return (Set-GrokAuthFields -Raw $current -KeyName $Auth.KeyName -AccessToken $AccessToken -RefreshToken $RefreshToken -ExpiresAt $ExpiresAt)
        }
        $entry = if ($Auth.KeyName -and $raw.PSObject.Properties[$Auth.KeyName]) { $raw.PSObject.Properties[$Auth.KeyName].Value } else { $null }
        if (-not $entry) { throw 'Grok 受保护凭据缺少账号条目' }
    } else {
        try {
            $raw = Update-JsonFile -Path $path -Update {
                param($current)
                $currentAuth = Convert-GrokRawAuth -Raw $current -Path $path
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                return (Set-GrokAuthFields -Raw $current -KeyName $Auth.KeyName -AccessToken $AccessToken -RefreshToken $RefreshToken -ExpiresAt $ExpiresAt)
            }
        } catch {
            if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('grok active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return
            }
            $snapPath = Get-GrokSnapshotPath $Auth.AccountId
            if (Test-Path -LiteralPath $snapPath) {
                $raw = Update-SecureSnapshot -Provider grok -AccountId $Auth.AccountId -Update {
                    param($current)
                    $currentAuth = Convert-GrokRawAuth -Raw $current -Path $snapPath
                    Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                    return (Set-GrokAuthFields -Raw $current -KeyName $Auth.KeyName -AccessToken $AccessToken -RefreshToken $RefreshToken -ExpiresAt $ExpiresAt)
                }
            } else {
                $raw = Set-GrokAuthFields -Raw $Auth.Raw -KeyName $Auth.KeyName -AccessToken $AccessToken -RefreshToken $RefreshToken -ExpiresAt $ExpiresAt
                [void](Write-SecureSnapshot -Provider grok -AccountId $Auth.AccountId -Value $raw)
            }
            $Auth.Path = $snapPath
            Write-WidgetLog ('grok active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        }
    }
    $entry = if ($Auth.KeyName -and $raw.PSObject.Properties[$Auth.KeyName]) { $raw.PSObject.Properties[$Auth.KeyName].Value } else { $null }
    if (-not $entry) { throw 'Grok 登录文件缺少账号条目' }
    $Auth.Raw = $raw
    $Auth.Entry = $entry
    if ($Auth.Path -notlike '*.snapshot' -and $Auth.AccountId) {
        $snapPath = Get-GrokSnapshotPath $Auth.AccountId
        if (Test-Path -LiteralPath $snapPath) {
            [void](Update-SecureSnapshot -Provider grok -AccountId $Auth.AccountId -Update {
                param($current)
                $currentAuth = Convert-GrokRawAuth -Raw $current -Path $snapPath
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                return (Set-GrokAuthFields -Raw $current -KeyName $Auth.KeyName -AccessToken $AccessToken -RefreshToken $RefreshToken -ExpiresAt $ExpiresAt)
            })
        }
    }
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $AccessToken -RefreshToken $RefreshToken -AccountId $Auth.AccountId)
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
    if ([string]$fresh.AccountId -ne [string]$Auth.AccountId) { return $false }
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
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
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
        try { $auth = Update-GrokToken -Auth $auth } catch {
            Write-WidgetLog "grok preemptive refresh failed: $($_.Exception.Message)"
            throw
        }
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
            $productPercent = Convert-OptionalNumber $p.usagePercent 'Grok product usagePercent'
            if ($null -eq $productPercent) { continue }
            $products += [pscustomobject]@{
                Name    = Get-ProductLabel ([string]$p.product)
                Percent = Assert-UsagePercent $productPercent 'Grok product usagePercent'
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

function Find-MatchingSnapshotAccount {
    param($Active, $Snapshots)
    if (-not $Active) { return $null }
    foreach ($snap in @($Snapshots)) {
        if (-not $snap) { continue }
        if ($Active.AccountId -and $snap.AccountId -and [string]$snap.AccountId -eq [string]$Active.AccountId) {
            return [string]$snap.AccountId
        }
        $activeRefresh = if ($Active.RefreshToken) { [string]$Active.RefreshToken } elseif ($Active.Refresh) { [string]$Active.Refresh } else { $null }
        $snapRefresh = if ($snap.RefreshToken) { [string]$snap.RefreshToken } elseif ($snap.Refresh) { [string]$snap.Refresh } else { $null }
        if ($activeRefresh -and $snapRefresh -and $activeRefresh -eq $snapRefresh) { return [string]$snap.AccountId }
    }
    return [string]$Active.AccountId
}

function Get-ProviderRowId {
    param($Auth, [string]$Kind)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'acct'
    if ($fingerprint) { return ('{0}-{1}' -f $Kind, $fingerprint) }
    return ($Kind + '-unknown')
}

function Get-ProviderRowName {
    param($Auth, [string]$Prefix, [string]$Fallback)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix $Prefix
    if ($fingerprint) { return $fingerprint }
    return $Fallback
}

function Add-CurrentSnapshotAccount {
    param(
        [Parameter(Mandatory)][string]$Provider,
        $Auth,
        [string]$Name
    )
    if (-not $Auth -or -not $Auth.AccountId -or $null -eq $Auth.Raw) {
        Write-Host (T 'cli.accountMissing')
        return [pscustomobject]@{ Status = 'missing'; Name = $null; Path = $null }
    }
    if (-not $Name) { $Name = [string]$Auth.AccountId }
    $snapPath = Get-SecureSnapshotPath -Provider $Provider -AccountId ([string]$Auth.AccountId)
    $existed = Test-Path -LiteralPath $snapPath
    [void](Write-SecureSnapshot -Provider $Provider -AccountId ([string]$Auth.AccountId) -Value $Auth.Raw)
    $status = if ($existed) { 'same-account' } else { 'registered' }
    Write-Host (T 'cli.registered' @($Name, $snapPath))
    if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
        Write-WidgetLog ("snapshot {0} {1} status={2}" -f $Provider, $Name, $status)
    }
    return [pscustomobject]@{ Status = $status; Name = $Name; Path = $snapPath }
}

function Show-AccountRegistration {
    param($Result)
    try {
        if (-not $script:Ui -or -not $script:Ui.Tray) { return }
        if ($Result.Status -eq 'same-account') {
            $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), (T 'cli.accountSame' @($Result.Name)), [System.Windows.Forms.ToolTipIcon]::Warning)
        } elseif ($Result.Status -eq 'registered') {
            $script:Ui.Tray.ShowBalloonTip(6000, (T 'app.title'), (T 'cli.accountRegistered' @($Result.Name)), [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), (T 'cli.accountMissing'), [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } catch { }
}

function Get-KimiAccountId {
    param($Raw)
    if (-not $Raw) { return $null }
    foreach ($name in @('user_id', 'userId', 'account_id', 'accountId', 'email')) {
        $prop = $Raw.PSObject.Properties[$name]
        if ($prop -and [string]$prop.Value) { return ([string]$prop.Value).Trim().ToLowerInvariant() }
    }
    if ($Raw.refresh_token) { return ('refresh:' + (Get-AccountFingerprint -AccountId ([string]$Raw.refresh_token) -Prefix 'tok')) }
    return $null
}

function Convert-KimiRawAuth {
    param($Raw, [string]$Path, [string]$Source)
    if (-not $Raw -or -not $Raw.access_token -or -not $Raw.refresh_token) {
        throw 'kimi-code.json 中没有可用的登录凭证，请重新登录'
    }
    $exp = $null
    if ($Raw.expires_at) {
        try { $exp = [DateTimeOffset]::FromUnixTimeSeconds([long]$Raw.expires_at).UtcDateTime } catch { }
    }
    $accountId = Get-KimiAccountId $Raw
    if (-not $accountId) { throw 'missing-credential' }
    $authObject = [pscustomobject]@{
        Token     = [string]$Raw.access_token
        Refresh   = [string]$Raw.refresh_token
        ExpiresAt = $exp
        AccountId = $accountId
        Path      = $Path
        Source    = $Source
        Raw       = $Raw
    }
    return (Set-CredentialVersion -Auth $authObject -AccessToken $authObject.Token -RefreshToken $authObject.Refresh -AccountId $accountId)
}

function Set-KimiAuthFields {
    param($Raw, [string]$Token, [string]$Refresh, [datetime]$ExpiresAt)
    if (-not $Raw) { throw 'Kimi credential is missing' }
    $Raw.access_token = $Token
    $Raw.refresh_token = $Refresh
    if ($ExpiresAt) {
        $Raw.expires_at = [long][DateTimeOffset]::new($ExpiresAt.ToUniversalTime()).ToUnixTimeSeconds()
    }
    return $Raw
}

function Save-KimiSnapshot {
    param($Auth)
    if (-not $Auth -or -not $Auth.AccountId) { throw 'Kimi snapshot is missing an account id' }
    $path = Get-SecureSnapshotPath -Provider kimi -AccountId $Auth.AccountId
    if (Test-Path -LiteralPath $path) {
        try {
            return (Update-SecureSnapshot -Provider kimi -AccountId $Auth.AccountId -Update {
                param($current)
                $currentAuth = Convert-KimiRawAuth -Raw $current -Path $path -Source 'snapshot'
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.Refresh
                return (Set-KimiAuthFields -Raw $current -Token $Auth.Token -Refresh $Auth.Refresh -ExpiresAt $Auth.ExpiresAt)
            })
        } catch {
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('kimi snapshot is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return $Auth.Raw
            }
            throw
        }
    }
    $raw = Set-KimiAuthFields -Raw $Auth.Raw -Token $Auth.Token -Refresh $Auth.Refresh -ExpiresAt $Auth.ExpiresAt
    [void](Write-SecureSnapshot -Provider kimi -AccountId $Auth.AccountId -Value $raw)
    return $raw
}

function Read-KimiAuthFromFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw 'missing-credential' }
    if ($Path -like '*.snapshot') {
        $raw = Read-SecureSnapshot -Path $Path
        $source = 'snapshot'
    } else {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        $source = 'file'
    }
    return (Convert-KimiRawAuth -Raw $raw -Path $Path -Source $source)
}

function Read-KimiAuth {
    if (-not (Test-Path -LiteralPath $script:KimiCredPath)) {
        throw '未找到 ~/.kimi-code/credentials/kimi-code.json，请先运行 kimi 登录'
    }
    return (Read-KimiAuthFromFile -Path $script:KimiCredPath)
}

function Get-KimiSnapshotAuths {
    $list = @()
    foreach ($file in @(Get-SecureSnapshotFiles -Provider kimi)) {
        try { $list += Read-KimiAuthFromFile -Path $file.FullName } catch { }
    }
    return @($list)
}

function Get-KimiAccounts {
    $active = $null
    try { if (Test-Path -LiteralPath $script:KimiCredPath) { $active = Read-KimiAuth } } catch { $active = $null }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-KimiSnapshotAuths)
        if ($matched) { $active.AccountId = $matched }
    }
    return @(Get-MergedProviderAccounts -Provider kimi -Active $active -ReadPath {
        param($Path)
        Read-KimiAuthFromFile -Path $Path
    })
}

function Sync-ActiveKimiSnapshot {
    if (-not $script:KimiCredPath -or -not (Test-Path -LiteralPath $script:KimiCredPath)) { return }
    $active = $null
    try { $active = Read-KimiAuth } catch { return }
    if (-not $active -or -not $active.Raw) { return }
    $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-KimiSnapshotAuths)
    if ($matched) { $active.AccountId = $matched }
    if (-not $active.AccountId) { return }
    [void](Write-SecureSnapshot -Provider kimi -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentKimiAccount {
    $active = $null
    try { if (Test-Path -LiteralPath $script:KimiCredPath) { $active = Read-KimiAuth } } catch { }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-KimiSnapshotAuths)
        if ($matched) { $active.AccountId = $matched }
    }
    return (Add-CurrentSnapshotAccount -Provider kimi -Auth $active -Name $(if ($active) { Get-ProviderRowName $active 'Kimi' 'Kimi' } else { $null }))
}

function Save-KimiAuth {
    param($Auth)
    if (-not $Auth) { return }
    $source = [string]$Auth.Source
    if (-not $source -and [string]$Auth.Path -like '*.snapshot') { $source = 'snapshot' }
    if ($source -eq 'snapshot') {
        $Auth.Raw = Save-KimiSnapshot $Auth
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.Refresh -AccountId $Auth.AccountId)
        return
    }
    try {
        $raw = Update-JsonFile -Path $script:KimiCredPath -Update {
            param($current)
            $currentAuth = Convert-KimiRawAuth -Raw $current -Path $script:KimiCredPath -Source 'file'
            Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.Refresh
            return (Set-KimiAuthFields -Raw $current -Token $Auth.Token -Refresh $Auth.Refresh -ExpiresAt $Auth.ExpiresAt)
        }
    } catch {
        if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
        if (Test-CredentialStale $_) {
            Write-WidgetLog ('kimi active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
            return
        }
        $Auth.Raw = Set-KimiAuthFields -Raw $Auth.Raw -Token $Auth.Token -Refresh $Auth.Refresh -ExpiresAt $Auth.ExpiresAt
        $Auth.Path = Get-SecureSnapshotPath -Provider kimi -AccountId $Auth.AccountId
        $Auth.Source = 'snapshot'
        $Auth.Raw = Save-KimiSnapshot $Auth
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.Refresh -AccountId $Auth.AccountId)
        Write-WidgetLog ('kimi active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        return
    }
    $Auth.Raw = $raw
    $Auth.Raw = Save-KimiSnapshot $Auth
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.Refresh -AccountId $Auth.AccountId)
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
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    $Auth.ExpiresAt = $expires
    Save-KimiAuth $Auth
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
        if ([string]$Auth.Source -ne 'snapshot') {
            try {
                $fresh = Read-KimiAuth
                if ([string]$fresh.AccountId -eq [string]$Auth.AccountId -and $fresh.Token -and $fresh.Token -ne $Auth.Token) {
                    $Auth.Token = $fresh.Token
                    $Auth.Refresh = $fresh.Refresh
                    $Auth.ExpiresAt = $fresh.ExpiresAt
                    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.Refresh -AccountId $Auth.AccountId)
                    $headers.Authorization = "Bearer $($Auth.Token)"
                    return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
                }
            } catch { }
        }
        $Auth = Update-KimiToken -Auth $Auth
        $headers.Authorization = "Bearer $($Auth.Token)"
        return Invoke-WidgetRest -Method Get -Uri $Url -Headers $headers
    }
}

function Get-KimiUsageSnapshot {
    param($Auth)
    $auth = if ($Auth) { $Auth } else { Read-KimiAuth }
    if ($auth.ExpiresAt -and $auth.ExpiresAt -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-KimiToken -Auth $auth } catch {
            Write-WidgetLog "kimi preemptive refresh failed: $($_.Exception.Message)"
            throw
        }
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
    $authObject = [pscustomobject]@{
        Path      = $Path
        Source    = $(if ($Path -like '*.snapshot') { 'snapshot' } else { 'file' })
        Token     = [string]$raw.tokens.access_token
        Refresh   = [string]$raw.tokens.refresh_token
        AccountId = $accountId
        Email     = $email
        Raw       = $raw
    }
    return (Set-CredentialVersion -Auth $authObject -AccessToken $authObject.Token -RefreshToken $authObject.Refresh -AccountId $accountId)
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

function Set-CodexAuthFields {
    param($Raw, [string]$AccessToken, [string]$RefreshToken, [string]$IdToken)
    if (-not $Raw -or -not $Raw.tokens) { throw 'Codex 凭据缺少 tokens' }
    [void]($Raw.tokens.access_token = $AccessToken)
    [void]($Raw.tokens.refresh_token = $RefreshToken)
    if ($IdToken) { [void]($Raw.tokens.id_token = $IdToken) }
    $lastRefresh = (Get-Date).ToUniversalTime().ToString('o')
    if ($Raw.PSObject.Properties['last_refresh']) { $Raw.last_refresh = $lastRefresh }
    else { Add-Member -InputObject $Raw -NotePropertyName last_refresh -NotePropertyValue $lastRefresh -Force }
    return $Raw
}

function Save-CodexAuth {
    param($Auth, [string]$Path, [string]$AccessToken, [string]$RefreshToken, [string]$IdToken)
    if (-not $Path -and $Auth) { $Path = [string]$Auth.Path }
    if (-not $Path) { throw 'Codex credential path is missing' }
    if (-not $Auth -or -not $Auth.AccountId) { throw 'Codex credential is missing an account id' }
    if ($Path -like '*.snapshot') {
        $raw = Update-SecureSnapshot -Provider codex -AccountId $Auth.AccountId -Update {
            param($current)
            $currentAuth = Convert-CodexRawAuth -Raw $current -Path $Path
            if (-not $currentAuth) { throw 'Codex 受保护凭据缺少 account_id' }
            Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.Refresh
            return (Set-CodexAuthFields -Raw $current -AccessToken $AccessToken -RefreshToken $RefreshToken -IdToken $IdToken)
        }
    } else {
        try {
            $raw = Update-JsonFile -Path $Path -Update {
                param($current)
                $currentAuth = Convert-CodexRawAuth -Raw $current -Path $Path
                if (-not $currentAuth) { throw 'Codex 登录文件缺少 account_id' }
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.Refresh
                return (Set-CodexAuthFields -Raw $current -AccessToken $AccessToken -RefreshToken $RefreshToken -IdToken $IdToken)
            }
        } catch {
            if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('codex active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return
            }
            $snapPath = Get-SnapshotPath $Auth.AccountId
            if (Test-Path -LiteralPath $snapPath) {
                $raw = Update-SecureSnapshot -Provider codex -AccountId $Auth.AccountId -Update {
                    param($current)
                    $currentAuth = Convert-CodexRawAuth -Raw $current -Path $snapPath
                    if (-not $currentAuth) { throw 'Codex 受保护凭据缺少 account_id' }
                    Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.Refresh
                    return (Set-CodexAuthFields -Raw $current -AccessToken $AccessToken -RefreshToken $RefreshToken -IdToken $IdToken)
                }
            } else {
                $raw = Set-CodexAuthFields -Raw $Auth.Raw -AccessToken $AccessToken -RefreshToken $RefreshToken -IdToken $IdToken
                [void](Write-SecureSnapshot -Provider codex -AccountId $Auth.AccountId -Value $raw)
            }
            $Auth.Path = $snapPath
            $Auth.Source = 'snapshot'
            Write-WidgetLog ('codex active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        }
    }
    $Auth.Raw = $raw
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $AccessToken -RefreshToken $RefreshToken -AccountId $Auth.AccountId)
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
    Save-CodexAuth -Auth $Auth -AccessToken $resp.access_token -RefreshToken $newRefresh -IdToken $newId
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    Write-WidgetLog ("codex token refreshed for {0}" -f (Get-AccountLabel $Auth))
    return $Auth
}

function Sync-CodexAuthFromDisk {
    param($Auth)
    $fresh = Read-CodexAuth -Path $Auth.Path
    if (-not $fresh) { return $false }
    if ([string]$fresh.AccountId -ne [string]$Auth.AccountId) { return $false }
    $changed = ($fresh.Token -ne $Auth.Token)
    $Auth.Token = $fresh.Token
    $Auth.Refresh = $fresh.Refresh
    if ($fresh.AccountId) { $Auth.AccountId = $fresh.AccountId }
    if ($fresh.Email) { $Auth.Email = $fresh.Email }
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.Token -RefreshToken $Auth.Refresh -AccountId $Auth.AccountId)
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
    param([string]$Path = $script:CommandCodeAuthPath)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        throw '未找到 ~/.commandcode/auth.json，请先安装 Command Code 并登录'
    }
    if ($Path -like '*.snapshot') {
        $raw = Read-SecureSnapshot -Path $Path
        $source = 'snapshot'
    } else {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        $source = 'file'
    }
    if (-not $raw.apiKey) { throw 'auth.json 缺少 apiKey，请重新登录' }
    $accountId = ([string]$raw.userId).Trim().ToLowerInvariant()
    if (-not $accountId) { $accountId = 'key:' + (Get-AccountFingerprint -AccountId ([string]$raw.apiKey) -Prefix 'tok') }
    return [pscustomobject]@{
        ApiKey    = [string]$raw.apiKey
        UserId    = [string]$raw.userId
        UserName  = [string]$raw.userName
        KeyName   = [string]$raw.keyName
        AccountId = $accountId
        Path      = $Path
        Source    = $source
        Raw       = $raw
    }
}

function Get-CommandCodeAccounts {
    $active = $null
    try { if (Test-CommandCodeCredExists) { $active = Read-CommandCodeAuth } } catch { $active = $null }
    return @(Get-MergedProviderAccounts -Provider commandcode -Active $active -ReadPath {
        param($Path)
        Read-CommandCodeAuth -Path $Path
    })
}

function Sync-ActiveCommandCodeSnapshot {
    if (-not (Test-CommandCodeCredExists)) { return }
    $active = $null
    try { $active = Read-CommandCodeAuth } catch { return }
    if (-not $active -or -not $active.AccountId -or -not $active.Raw) { return }
    [void](Write-SecureSnapshot -Provider commandcode -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentCommandCodeAccount {
    $active = $null
    try { if (Test-CommandCodeCredExists) { $active = Read-CommandCodeAuth } } catch { }
    return (Add-CurrentSnapshotAccount -Provider commandcode -Auth $active -Name $(if ($active) { Get-ProviderRowName $active 'CommandCode' 'Command Code' } else { $null }))
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
    param($Auth)
    $auth = if ($Auth) { $Auth } else { Read-CommandCodeAuth }
    $orgId = Get-CommandCodeOrgId $auth
    $path = '/alpha/billing/credits'
    if ($orgId) { $path += '?orgId=' + [uri]::EscapeDataString($orgId) }
    $data = Invoke-CommandCodeGet -Auth $auth -Path $path
    return Convert-CommandCodeCredits $data
}

function Get-CommandCodeRowData {
    param($Auth, [string]$Name)
    $u = Get-CommandCodeUsageSnapshot -Auth $Auth
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
        Percent    = $percent
        Detail     = ($details -join ' · ')
        Tip        = (T 'row.codexTip' @($display, (Format-PercentText $percent)))
        Reset      = $null
        ResetAt    = $null
        MetricType = $(if ($usage.IsUnlimited) { 'unlimited' } else { 'percent' })
        Value      = $usage.Spent
        Unit       = 'USD'
        Window     = [string]$usage.Period
        Used       = $usage.Spent
        Limit      = $usage.Limit
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
        Percent    = 0.0
        Display    = $usage.Display
        Detail     = ($details -join ' · ')
        Tip        = (T 'row.balanceTip' @($display, $usage.Display))
        Reset      = $null
        ResetAt    = $null
        MetricType = 'balance'
        Value      = $usage.Total
        Unit       = $usage.Currency
        Window     = 'balance'
        FetchedAt  = $usage.FetchedAt
    }
}

# --- Cline ---

function Test-ClineCredExists {
    try {
        return (@(Get-ClineAccounts).Count -gt 0)
    } catch {
        return $false
    }
}

function Read-ClineAuth {
    param([string]$Path = $script:ClineProvidersPath)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw 'missing-credential' }
    if ($Path -like '*.snapshot') {
        $raw = Read-SecureSnapshot -Path $Path
    } else {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    return (Convert-ClineRawAuth -Raw $raw -Path $Path)
}

function Set-ClineAuthFields {
    param($RawAuth, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    if (-not $RawAuth) { throw 'Cline 凭据缺少 auth' }
    $RawAuth.accessToken = ConvertTo-ClineStoredAccessToken $AccessToken
    if ($RefreshToken) { $RawAuth.refreshToken = $RefreshToken }
    if ($ExpiresAt) {
        $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')
        $RawAuth.expiresAt = [int64](($ExpiresAt.ToUniversalTime() - $epoch).TotalMilliseconds)
    }
    return $RawAuth
}

function Save-ClineSnapshot {
    param($Auth)
    if (-not $Auth -or -not $Auth.AccountId) { throw 'Cline 受保护凭据缺少 accountId' }
    $path = Get-ClineSnapshotPath $Auth.AccountId
    if (Test-Path -LiteralPath $path) {
        try {
            $updated = Update-SecureSnapshot -Provider cline -AccountId $Auth.AccountId -Update {
                param($current)
                $currentAuth = Convert-ClineRawAuth -Raw $current -Path $path
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                $entry = Get-ClineAuthEntry $current
                if (-not $entry -or -not $entry.Auth) { throw 'Cline 受保护凭据缺少 auth' }
                [void](Set-ClineAuthFields -RawAuth $entry.Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
                return $current
            }
        } catch {
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('cline snapshot is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return $Auth.Raw
            }
            throw
        }
    } else {
        $entry = Get-ClineAuthEntry $Auth.Raw
        if (-not $entry -or -not $entry.Auth) { throw 'Cline 凭据缺少 auth' }
        [void](Set-ClineAuthFields -RawAuth $entry.Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
        $updated = $Auth.Raw
        [void](Write-SecureSnapshot -Provider cline -AccountId $Auth.AccountId -Value $updated)
    }
    $Auth.Raw = $updated
    $entry = Get-ClineAuthEntry $updated
    $Auth.RawProvider = $entry.Provider
    $Auth.RawSettings = $entry.Settings
    $Auth.RawAuth = $entry.Auth
    return $updated
}

function Save-ClineAuth {
    param($Auth)
    if (-not $Auth -or -not $Auth.Raw -or -not $Auth.RawAuth) { return }
    if ($Auth.Path -like '*.snapshot') {
        [void](Save-ClineSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        return
    }
    $path = [string]$Auth.Path
    if (-not $path) { $path = $script:ClineProvidersPath }
    try {
        $updated = Update-JsonFile -Path $path -Update {
                param($current)
                $currentAuth = Convert-ClineRawAuth -Raw $current -Path $path
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
            $entry = Get-ClineAuthEntry $current
            if (-not $entry -or -not $entry.Auth) { throw 'Cline 登录文件缺少 auth' }
            [void](Set-ClineAuthFields -RawAuth $entry.Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
            return $current
        }
    } catch {
        if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
        if (Test-CredentialStale $_) {
            Write-WidgetLog ('cline active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
            return
        }
        [void](Set-ClineAuthFields -RawAuth $Auth.RawAuth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
        $Auth.Path = Get-ClineSnapshotPath $Auth.AccountId
        $Auth.Source = 'snapshot'
        [void](Save-ClineSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        Write-WidgetLog ('cline active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        return
    }
    $Auth.Raw = $updated
    $entry = Get-ClineAuthEntry $updated
    $Auth.RawProvider = $entry.Provider
    $Auth.RawSettings = $entry.Settings
    $Auth.RawAuth = $entry.Auth
    [void](Save-ClineSnapshot $Auth)
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
}

function Get-ClineRowId {
    param($Auth)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'acct'
    if ($fingerprint) { return ('cline-{0}' -f $fingerprint) }
    return 'cline-unknown'
}

function Get-ClineRowName {
    param($Auth)
    $fingerprint = Get-AccountFingerprint -AccountId ([string]$Auth.AccountId) -Prefix 'Cline'
    if ($fingerprint) { return $fingerprint }
    return $script:ClineDisplayName
}

function Get-ClineSnapshotPath {
    param([string]$AccountId)
    return (Get-SecureSnapshotPath -Provider cline -AccountId $AccountId)
}

function Get-ClineAccounts {
    $byId = [ordered]@{}
    $active = $null
    try { $active = Read-ClineAuth -Path $script:ClineProvidersPath } catch { }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots @(
            foreach ($f in @(Get-SecureSnapshotFiles -Provider cline)) {
                try { Read-ClineAuth -Path $f.FullName } catch { }
            }
        )
        if ($matched) { $active.AccountId = $matched }
        $key = if ($active.AccountId) { [string]$active.AccountId } else { 'unknown' }
        $byId[$key] = $active
    }
    foreach ($f in @(Get-SecureSnapshotFiles -Provider cline)) {
        $snap = $null
        try { $snap = Read-ClineAuth -Path $f.FullName } catch { }
        if (-not $snap) { continue }
        $key = if ($snap.AccountId) { [string]$snap.AccountId } else { 'unknown' }
        if (-not $byId.Contains($key)) { $byId[$key] = $snap }
    }
    return @($byId.Values)
}

function Add-CurrentClineAccount {
    $active = $null
    try { $active = Read-ClineAuth -Path $script:ClineProvidersPath } catch { }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots @(
            foreach ($f in @(Get-SecureSnapshotFiles -Provider cline)) {
                try { Read-ClineAuth -Path $f.FullName } catch { }
            }
        )
        if ($matched) { $active.AccountId = $matched }
    }
    if (-not $active -or -not $active.AccountId) {
        Write-Host (T 'cli.clineAuthMissing')
        return [pscustomobject]@{ Status = 'missing'; Name = $null; Path = $null }
    }
    $name = Get-ClineRowName $active
    $snapPath = Get-ClineSnapshotPath $active.AccountId
    $existed = Test-Path -LiteralPath $snapPath
    [void](Write-SecureSnapshot -Provider cline -AccountId $active.AccountId -Value $active.Raw)
    $status = if ($existed) { 'same-account' } else { 'registered' }
    Write-Host (T 'cli.registered' @($name, $snapPath))
    Write-WidgetLog ("snapshot cline {0} status={1}" -f $name, $status)
    return [pscustomobject]@{ Status = $status; Name = $name; Path = $snapPath }
}

function Sync-ActiveClineSnapshot {
    param($Accounts)
    foreach ($acct in @($Accounts)) {
        if ($acct.Path -eq $script:ClineProvidersPath) {
            $snap = Get-ClineSnapshotPath $acct.AccountId
            if (Test-Path -LiteralPath $snap) {
                try { [void](Save-ClineSnapshot $acct) } catch { }
            }
        }
    }
}

function Update-ClineToken {
    param($Auth)
    if (-not $Auth) { throw 'missing-credential' }
    $needsRefresh = (-not $Auth.ExpiresAt) -or ($Auth.ExpiresAt.ToUniversalTime() -le [datetime]::UtcNow.AddMinutes(5))
    if (-not $needsRefresh) { return $Auth }
    if (-not $Auth.RefreshToken) { throw 'token-refresh' }
    $body = @{ refreshToken = $Auth.RefreshToken; grantType = 'refresh_token' } | ConvertTo-Json -Compress
    $resp = Invoke-WidgetRest -Method Post -Uri $script:ClineRefreshUrl -Body $body -ContentType 'application/json'
    $data = $null
    try { $data = $resp.data } catch { }
    if (-not $resp -or -not $resp.success -or -not $data -or -not $data.accessToken) { throw 'token-refresh' }
    $Auth.AccessToken = ConvertTo-ClineStoredAccessToken ([string]$data.accessToken)
    if ($data.refreshToken) { $Auth.RefreshToken = [string]$data.refreshToken }
    $expiresAt = Convert-ClineAuthExpiry $data.expiresAt
    if ($expiresAt) { $Auth.ExpiresAt = $expiresAt }
    try { Save-ClineAuth $Auth } catch {
        Write-WidgetLog ('cline save token ' + (Convert-SafeLogText $_.Exception.Message 120))
        throw
    }
    return $Auth
}

function Get-ClineAuthHeaders {
    param($Auth)
    $token = ConvertTo-ClineStoredAccessToken $Auth.AccessToken
    return @{
        Authorization = "Bearer $token"
        Accept        = 'application/json'
        'User-Agent'  = 'cline/3.0.62'
    }
}

function Get-ClineUsageSnapshot {
    param($Auth)
    $auth = Update-ClineToken $Auth
    $data = Invoke-WidgetRest -Method Get -Uri $script:ClineUsageUrl -Headers (Get-ClineAuthHeaders $auth)
    return (Convert-ClineUsageLimits $data)
}

function Get-ClineRowData {
    param($Auth, [string]$Name)
    $auth = if ($Auth) { $Auth } else { Read-ClineAuth }
    $usage = Get-ClineUsageSnapshot -Auth $auth
    $details = @()
    if ($usage.FiveHour) { $details += (T 'row.window5hPercent' @($usage.FiveHour.Percent)) }
    if ($usage.Weekly)   { $details += (T 'row.windowWeekPercent' @($usage.Weekly.Percent)) }
    if ($usage.Monthly)  { $details += (T 'row.windowMonthPercent' @($usage.Monthly.Percent)) }
    $reset = Format-ResetText $usage.ResetAt
    if ($reset) { $details += $reset }
    Write-WidgetLog ("usage cline {0} ok" -f $usage.Percent)
    [pscustomobject]@{
        Percent   = $usage.Percent
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.codexTip' @($script:ClineDisplayName, (Format-PercentText $usage.Percent)))
        Reset     = $(if ($usage.ResetAt) { Format-ResetTime $usage.ResetAt } else { $null })
        ResetAt   = $(if ($usage.ResetAt) { ConvertTo-ResetStamp $usage.ResetAt } else { $null })
        FetchedAt = $usage.FetchedAt
    }
}

# --- Claude Code ---

function Test-ClaudeCredExists {
    Test-Path -LiteralPath $script:ClaudeCredPath
}

function Read-ClaudeAuthFromFile {
    param([string]$Path = $script:ClaudeCredPath)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw 'missing-credential' }
    if ($Path -like '*.snapshot') {
        $raw = Read-SecureSnapshot -Path $Path
        $source = 'snapshot'
    } else {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        $source = 'file'
    }
    $auth = Convert-ClaudeRawAuth $raw
    $auth | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
    $auth | Add-Member -NotePropertyName Source -NotePropertyValue $source -Force
    return $auth
}

function Get-ClaudeSnapshotAuths {
    $list = @()
    foreach ($file in @(Get-SecureSnapshotFiles -Provider claude)) {
        try { $list += Read-ClaudeAuthFromFile -Path $file.FullName } catch { }
    }
    return @($list)
}

function Get-ClaudeAccounts {
    $active = $null
    try { if (Test-ClaudeCredExists) { $active = Read-ClaudeAuthFromFile } } catch { $active = $null }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-ClaudeSnapshotAuths)
        if ($matched) { $active.AccountId = $matched }
    }
    return @(Get-MergedProviderAccounts -Provider claude -Active $active -ReadPath {
        param($Path)
        Read-ClaudeAuthFromFile -Path $Path
    })
}

function Sync-ActiveClaudeSnapshot {
    if (-not (Test-ClaudeCredExists)) { return }
    $active = $null
    try { $active = Read-ClaudeAuthFromFile } catch { return }
    if (-not $active -or -not $active.Raw) { return }
    $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-ClaudeSnapshotAuths)
    if ($matched) { $active.AccountId = $matched }
    if (-not $active.AccountId) { return }
    [void](Write-SecureSnapshot -Provider claude -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentClaudeAccount {
    $active = $null
    try { if (Test-ClaudeCredExists) { $active = Read-ClaudeAuthFromFile } } catch { }
    if ($active) {
        $matched = Find-MatchingSnapshotAccount -Active $active -Snapshots (Get-ClaudeSnapshotAuths)
        if ($matched) { $active.AccountId = $matched }
    }
    return (Add-CurrentSnapshotAccount -Provider claude -Auth $active -Name $(if ($active) { Get-ProviderRowName $active 'Claude' 'Claude' } else { $null }))
}

function Set-ClaudeAuthFields {
    param($Raw, [string]$AccessToken, [string]$RefreshToken, [datetime]$ExpiresAt)
    $oauth = $null
    if ($Raw.PSObject.Properties['claudeAiOauth']) { $oauth = $Raw.claudeAiOauth }
    if (-not $oauth -and $Raw.PSObject.Properties['oauth']) { $oauth = $Raw.oauth }
    if (-not $oauth) { throw 'missing-credential' }
    if ($oauth.PSObject.Properties['accessToken']) { $oauth.accessToken = $AccessToken }
    elseif ($oauth.PSObject.Properties['access_token']) { $oauth.access_token = $AccessToken }
    else { Add-Member -InputObject $oauth -NotePropertyName accessToken -NotePropertyValue $AccessToken -Force }
    if ($RefreshToken) {
        if ($oauth.PSObject.Properties['refreshToken']) { $oauth.refreshToken = $RefreshToken }
        elseif ($oauth.PSObject.Properties['refresh_token']) { $oauth.refresh_token = $RefreshToken }
        else { Add-Member -InputObject $oauth -NotePropertyName refreshToken -NotePropertyValue $RefreshToken -Force }
    }
    if ($ExpiresAt) {
        $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')
        $ms = [int64]($ExpiresAt.ToUniversalTime() - $epoch).TotalMilliseconds
        if ($oauth.PSObject.Properties['expiresAt']) { $oauth.expiresAt = $ms }
        elseif ($oauth.PSObject.Properties['expires_at']) { $oauth.expires_at = $ms }
        else { Add-Member -InputObject $oauth -NotePropertyName expiresAt -NotePropertyValue $ms -Force }
    }
    return $Raw
}

function Save-ClaudeSnapshot {
    param($Auth)
    if (-not $Auth -or -not $Auth.AccountId) { throw 'Claude snapshot is missing an account id' }
    $path = Get-SecureSnapshotPath -Provider claude -AccountId $Auth.AccountId
    if (Test-Path -LiteralPath $path) {
        try {
            $updated = Update-SecureSnapshot -Provider claude -AccountId $Auth.AccountId -Update {
                param($current)
                $currentAuth = Convert-ClaudeRawAuth -Raw $current
                Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
                return (Set-ClaudeAuthFields -Raw $current -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
            }
        } catch {
            if (Test-CredentialStale $_) {
                Write-WidgetLog ('claude snapshot is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
                return $Auth.Raw
            }
            throw
        }
    } else {
        $updated = Set-ClaudeAuthFields -Raw $Auth.Raw -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt
        [void](Write-SecureSnapshot -Provider claude -AccountId $Auth.AccountId -Value $updated)
    }
    $Auth.Raw = $updated
    return $updated
}

function Save-ClaudeAuth {
    param($Auth, [string]$Path)
    if (-not $Path -and $Auth) { $Path = [string]$Auth.Path }
    if (-not $Path) { $Path = $script:ClaudeCredPath }
    if (-not $Auth -or -not $Path) { return }
    if ($Path -like '*.snapshot') {
        [void](Save-ClaudeSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        return
    }
    if (-not $Auth.Raw) { return }
    try {
        $updated = Update-JsonFile -Path $Path -Update {
            param($current)
            $currentAuth = Convert-ClaudeRawAuth -Raw $current
                    Assert-CredentialIdentity -ExpectedAccountId $Auth.AccountId -ActualAccountId $currentAuth.AccountId -ExpectedRefreshToken $Auth.OriginalRefreshToken -ActualRefreshToken $currentAuth.RefreshToken
            return (Set-ClaudeAuthFields -Raw $current -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
        }
    } catch {
        if (-not (Test-CredentialAccountChanged $_) -and -not (Test-CredentialStale $_)) { throw }
        if (Test-CredentialStale $_) {
            Write-WidgetLog ('claude active credential is newer; stale refresh discarded for {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
            return
        }
        [void](Set-ClaudeAuthFields -Raw $Auth.Raw -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -ExpiresAt $Auth.ExpiresAt)
        $Auth.Path = Get-SecureSnapshotPath -Provider claude -AccountId $Auth.AccountId
        $Auth.Source = 'snapshot'
        [void](Save-ClaudeSnapshot $Auth)
        [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
        Write-WidgetLog ('claude active credential changed; refreshed result stored in account snapshot {0}' -f (Get-AccountFingerprint -AccountId $Auth.AccountId -Prefix 'acct'))
        return
    }
    $Auth.Raw = $updated
    [void](Save-ClaudeSnapshot $Auth)
    [void](Set-CredentialVersion -Auth $Auth -AccessToken $Auth.AccessToken -RefreshToken $Auth.RefreshToken -AccountId $Auth.AccountId)
}

function Update-ClaudeToken {
    param($Auth)
    if (-not $Auth -or -not $Auth.RefreshToken) { return $Auth }
    if ($Auth.ExpiresAt -and $Auth.ExpiresAt.ToUniversalTime() -gt [datetime]::UtcNow.AddMinutes(2)) { return $Auth }
    $body = 'grant_type=refresh_token&refresh_token={0}&client_id={1}' -f [Uri]::EscapeDataString($Auth.RefreshToken), [Uri]::EscapeDataString($script:ClaudeOAuthClientId)
    $resp = $null
    try {
        $resp = Invoke-WidgetRest -Method Post -Uri $script:ClaudeTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    } catch {
        $resp = Invoke-WidgetRest -Method Post -Uri $script:ClaudeTokenUrlLegacy -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    $access = [string]$resp.access_token
    if (-not $access) { $access = [string]$resp.accessToken }
    if (-not $access) { throw 'token-refresh' }
    $Auth.AccessToken = $access
    $newRefresh = [string]$resp.refresh_token
    if (-not $newRefresh) { $newRefresh = [string]$resp.refreshToken }
    if ($newRefresh) { $Auth.RefreshToken = $newRefresh }
    $expiresIn = $resp.expires_in
    if (Test-FiniteNumber $expiresIn) { $Auth.ExpiresAt = [datetime]::UtcNow.AddSeconds([double]$expiresIn) }
    try { Save-ClaudeAuth $Auth } catch {
        Write-WidgetLog ('claude save token ' + (Convert-SafeLogText $_.Exception.Message 120))
        throw
    }
    return $Auth
}

function Get-ClaudeAuthHeaders {
    param($Auth)
    return @{
        Authorization        = "Bearer $($Auth.AccessToken)"
        Accept               = 'application/json'
        'anthropic-version'  = '2023-06-01'
        'anthropic-beta'     = 'oauth-2025-04-20'
        'x-app'              = 'cli'
        'User-Agent'         = 'claude-cli/2.1.201 (external, cli)'
    }
}

function Get-ClaudeUsageSnapshot {
    param($Auth)
    $auth = Update-ClaudeToken $Auth
    $data = Invoke-WidgetRest -Method Get -Uri $script:ClaudeUsageUrl -Headers (Get-ClaudeAuthHeaders $auth)
    return (Convert-ClaudeUsage $data)
}

function Get-ClaudeRowData {
    param($Auth, [string]$Name)
    $auth = if ($Auth) { $Auth } else { Read-ClaudeAuthFromFile }
    $usage = Get-ClaudeUsageSnapshot -Auth $auth
    $display = if ($Name) { $Name } else { $script:ClaudeDisplayName }
    $details = @()
    if ($usage.FiveHour) { $details += (T 'row.window5hPercent' @($usage.FiveHour.Percent)) }
    if ($usage.Weekly) { $details += (T 'row.windowWeekPercent' @($usage.Weekly.Percent)) }
    $reset = Format-ResetText $usage.ResetAt
    if ($reset) { $details += $reset }
    Write-WidgetLog ("usage claude {0} ok" -f $usage.Percent)
    [pscustomobject]@{
        Percent   = $usage.Percent
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.claudeTip' @((Format-PercentText $usage.Percent)))
        Reset     = $(if ($usage.ResetAt) { Format-ResetTime $usage.ResetAt } else { $null })
        ResetAt   = $(if ($usage.ResetAt) { ConvertTo-ResetStamp $usage.ResetAt } else { $null })
        FetchedAt = $usage.FetchedAt
    }
}

# --- Cursor ---

function Get-CursorStateDbPath {
    if ($script:CursorStateDbPath) { return $script:CursorStateDbPath }
    return (Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb')
}

function Read-CursorAuth {
    $path = Get-CursorStateDbPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw 'missing-credential' }
    $stamp = $null
    try { $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks } catch { }
    if ($script:CursorTokenCache -and $script:CursorTokenCache.Stamp -eq $stamp -and $script:CursorTokenCache.Token) {
        return [pscustomobject]@{ AccessToken = $script:CursorTokenCache.Token }
    }
    $tmp = Join-Path $env:TEMP ('cursor-state-' + [guid]::NewGuid().ToString('N') + '.vscdb')
    $stream = $null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $out = [IO.File]::Create($tmp)
        try { $stream.CopyTo($out) } finally { $out.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($tmp)
        $token = Get-CursorSqliteTextValue -Bytes $bytes -Key 'cursorAuth/accessToken'
        if (-not $token) { throw 'missing-credential' }
        $script:CursorTokenCache = @{ Stamp = $stamp; Token = $token }
        $accountId = Get-TokenEmail $token
        if ($accountId) { $accountId = $accountId.Trim().ToLowerInvariant() }
        if (-not $accountId) { $accountId = 'token:' + (Get-AccountFingerprint -AccountId $token -Prefix 'tok') }
        return [pscustomobject]@{
            AccessToken = $token
            AccountId   = $accountId
            Source      = 'live'
            Path        = $path
            Raw         = [pscustomobject]@{ accessToken = $token; accountId = $accountId }
        }
    } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Read-CursorSnapshot {
    param([string]$Path)
    $raw = Read-SecureSnapshot -Path $Path
    $token = [string]$raw.accessToken
    if (-not $token) { throw 'missing-credential' }
    $accountId = [string]$raw.accountId
    if (-not $accountId) {
        $accountId = Get-TokenEmail $token
        if ($accountId) { $accountId = $accountId.Trim().ToLowerInvariant() }
    }
    if (-not $accountId) { $accountId = 'token:' + (Get-AccountFingerprint -AccountId $token -Prefix 'tok') }
    return [pscustomobject]@{
        AccessToken = $token
        AccountId   = $accountId
        Source      = 'snapshot'
        Path        = $Path
        Raw         = $raw
    }
}

function Get-CursorAccounts {
    $active = $null
    try { $active = Read-CursorAuth } catch { $active = $null }
    if ($active -and $active.AccountId -and $active.Raw) {
        try { [void](Write-SecureSnapshot -Provider cursor -AccountId $active.AccountId -Value $active.Raw) } catch { }
    }
    return @(Get-MergedProviderAccounts -Provider cursor -Active $active -ReadPath {
        param($Path)
        Read-CursorSnapshot -Path $Path
    })
}

function Sync-ActiveCursorSnapshot {
    $active = $null
    try { if (Test-CursorCredExists) { $active = Read-CursorAuth } } catch { return }
    if (-not $active -or -not $active.AccountId -or -not $active.Raw) { return }
    [void](Write-SecureSnapshot -Provider cursor -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentCursorAccount {
    $active = $null
    try { if (Test-CursorCredExists) { $active = Read-CursorAuth } } catch { }
    return (Add-CurrentSnapshotAccount -Provider cursor -Auth $active -Name $(if ($active) { Get-ProviderRowName $active 'Cursor' 'Cursor' } else { $null }))
}

function Test-CursorCredExists {
    $path = Get-CursorStateDbPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $auth = Read-CursorAuth
        return [bool]$auth.AccessToken
    } catch { return $false }
}

function Get-CursorUsageSnapshot {
    param($Auth)
    $auth = if ($Auth) { $Auth } else { Read-CursorAuth }
    $headers = @{
        Authorization                 = "Bearer $($auth.AccessToken)"
        Accept                        = 'application/json'
        'Content-Type'                = 'application/json'
        'Connect-Protocol-Version'    = '1'
        'User-Agent'                  = 'ai-usage-widget'
    }
    $data = Invoke-WidgetRest -Method Post -Uri $script:CursorUsageUrl -Headers $headers -Body '{}' -ContentType 'application/json'
    return (Convert-CursorPeriodUsage $data)
}

function Get-CursorRowData {
    param($Auth, [string]$Name)
    $usage = Get-CursorUsageSnapshot -Auth $Auth
    $display = if ($Name) { $Name } else { $script:CursorDisplayName }
    $details = @()
    if ($usage.Membership) { $details += $usage.Membership }
    if ($null -ne $usage.Used -and $null -ne $usage.Limit) {
        $details += (T 'row.limitUsage' @($usage.Used, $usage.Limit, $usage.Percent))
    } elseif ($null -ne $usage.Remaining) {
        $details += ('${0:0.00}' -f $usage.Remaining)
    }
    $reset = Format-ResetText $usage.ResetAt
    if ($reset) { $details += $reset }
    Write-WidgetLog ("usage cursor {0} ok" -f $usage.Percent)
    [pscustomobject]@{
        Percent   = $usage.Percent
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.cursorTip' @((Format-PercentText $usage.Percent)))
        Reset     = $(if ($usage.ResetAt) { Format-ResetTime $usage.ResetAt } else { $null })
        ResetAt   = $(if ($usage.ResetAt) { ConvertTo-ResetStamp $usage.ResetAt } else { $null })
        FetchedAt = $usage.FetchedAt
    }
}

# --- GLM / Z.AI ---

# ZCode 把智谱 BigModel 的密钥放在 <home>/.zcode/v2/config.json，只读文件，不打印任何内容。
function Get-ZaiZcodeKey {
    param([string]$Path)
    if (-not $Path) { $Path = $script:ZcodeConfigPath }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    return (Get-ZaiBigModelKey $raw)
}

# 统一的凭证解析：环境变量 > 本机凭证文件 > ZCode 配置。
# 返回的 BaseUrl 决定走国际站还是中国站（两边接口路径一致）。
function Resolve-ZaiCredential {
    if ($env:ZAI_API_KEY) { return @{ Key = $env:ZAI_API_KEY; BaseUrl = $script:ZaiApiBaseUrl; Source = 'ZAI_API_KEY' } }
    if ($env:ZHIPU_API_KEY) { return @{ Key = $env:ZHIPU_API_KEY; BaseUrl = $script:ZhipuApiBaseUrl; Source = 'ZHIPU_API_KEY' } }
    if ($env:BIGMODEL_API_KEY) { return @{ Key = $env:BIGMODEL_API_KEY; BaseUrl = $script:ZhipuApiBaseUrl; Source = 'BIGMODEL_API_KEY' } }
    foreach ($file in @(
            @{ Path = $script:ZaiAuthPath; BaseUrl = $script:ZaiApiBaseUrl },
            @{ Path = $script:ZhipuAuthPath; BaseUrl = $script:ZhipuApiBaseUrl },
            @{ Path = $script:BigModelAuthPath; BaseUrl = $script:ZhipuApiBaseUrl })) {
        if (-not $file.Path -or -not (Test-Path -LiteralPath $file.Path)) { continue }
        $keys = @(Get-ApiKeyFileSources -Path $file.Path)
        if ($keys.Count -gt 0) { return @{ Key = $keys[0]; BaseUrl = $file.BaseUrl; Source = $file.Path } }
    }
    $zcodeKey = Get-ZaiZcodeKey
    if ($zcodeKey) { return @{ Key = $zcodeKey; BaseUrl = $script:ZhipuApiBaseUrl; Source = 'zcode' } }
    return $null
}

function Test-ZaiCredExists {
    return [bool](Resolve-ZaiCredential)
}

function Read-ZaiSnapshot {
    param([string]$Path)
    $raw = Read-SecureSnapshot -Path $Path
    $key = [string]$raw.apiKey
    if (-not $key) { throw 'missing-credential' }
    $accountId = [string]$raw.accountId
    if (-not $accountId) { $accountId = 'key:' + (Get-AccountFingerprint -AccountId $key -Prefix 'tok') }
    $baseUrl = [string]$raw.baseUrl
    if (-not $baseUrl) { $baseUrl = $script:ZaiApiBaseUrl }
    return [pscustomobject]@{
        ApiKey    = $key
        BaseUrl   = $baseUrl
        AccountId = $accountId
        Source    = 'snapshot'
        Path      = $Path
        Raw       = $raw
    }
}

function Get-ZaiActiveAuth {
    $credential = Resolve-ZaiCredential
    if (-not $credential -or -not $credential.Key) { return $null }
    $key = [string]$credential.Key
    $accountId = 'key:' + (Get-AccountFingerprint -AccountId $key -Prefix 'tok')
    return [pscustomobject]@{
        ApiKey    = $key
        BaseUrl   = [string]$credential.BaseUrl
        AccountId = $accountId
        Source    = 'live'
        Raw       = [pscustomobject]@{ apiKey = $key; baseUrl = [string]$credential.BaseUrl; accountId = $accountId }
    }
}

function Get-ZaiAccounts {
    return @(Get-MergedProviderAccounts -Provider glm -Active (Get-ZaiActiveAuth) -ReadPath {
        param($Path)
        Read-ZaiSnapshot -Path $Path
    })
}

function Sync-ActiveZaiSnapshot {
    $active = Get-ZaiActiveAuth
    if (-not $active -or -not $active.AccountId -or -not $active.Raw) { return }
    [void](Write-SecureSnapshot -Provider glm -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentZaiAccount {
    return (Add-CurrentSnapshotAccount -Provider glm -Auth (Get-ZaiActiveAuth) -Name $(
        $active = Get-ZaiActiveAuth
        if ($active) { Get-ProviderRowName $active 'GLM' 'GLM' } else { $null }
    ))
}

function Get-ZaiAuthHeaders {
    param($Auth)
    return @{
        Authorization     = [string]$Auth.ApiKey
        Accept            = 'application/json'
        'Accept-Language' = 'en-US,en'
        'User-Agent'      = 'ai-usage-widget'
    }
}

function Get-ZaiUsageSnapshot {
    param($Auth)
    $credential = $null
    if ($Auth -and [string]$Auth.ApiKey) {
        $baseUrl = [string]$Auth.BaseUrl
        if (-not $baseUrl) { $baseUrl = $script:ZaiApiBaseUrl }
        $credential = @{ Key = [string]$Auth.ApiKey; BaseUrl = $baseUrl }
    } else { $credential = Resolve-ZaiCredential }
    if (-not $credential) { throw 'missing-credential' }
    $baseUrl = $credential.BaseUrl
    if ($env:ZAI_API_BASE) { $baseUrl = $env:ZAI_API_BASE.Trim().TrimEnd('/') }
    $url = $baseUrl + '/api/monitor/usage/quota/limit'
    $data = Invoke-WidgetRest -Method Get -Uri $url -Headers (Get-ZaiAuthHeaders @{ ApiKey = $credential.Key })
    return (Convert-ZaiQuota $data)
}

function Get-ZaiRowData {
    param($Auth, [string]$Name)
    $usage = Get-ZaiUsageSnapshot -Auth $Auth
    $display = if ($Name) { $Name } else { $script:ZaiDisplayName }
    $details = @()
    if ($usage.Level) { $details += $usage.Level }
    if ($usage.FiveHour) { $details += (T 'row.window5hPercent' @($usage.FiveHour.Percent)) }
    if ($usage.Weekly) { $details += (T 'row.windowWeekPercent' @($usage.Weekly.Percent)) }
    $reset = Format-ResetText $usage.ResetAt
    if ($reset) { $details += $reset }
    Write-WidgetLog ("usage glm {0} ok" -f $usage.Percent)
    [pscustomobject]@{
        Percent   = $usage.Percent
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.glmTip' @((Format-PercentText $usage.Percent)))
        Reset     = $(if ($usage.ResetAt) { Format-ResetTime $usage.ResetAt } else { $null })
        ResetAt   = $(if ($usage.ResetAt) { ConvertTo-ResetStamp $usage.ResetAt } else { $null })
        FetchedAt = $usage.FetchedAt
    }
}

# --- GitHub Copilot ---

# hosts.json / apps.json / OpenCode auth.json 的结构随版本变化，
# 所以只按“深度优先找第一个 token 键”读取，不绑定固定层级。
function Read-CopilotTokenFromFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw 'missing-credential' }
    try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { throw 'missing-credential' }
    $token = Find-CopilotToken $raw
    if (-not $token) { throw 'missing-credential' }
    return $token
}

function Get-CopilotAuthToken {
    param($Auth)
    if ($null -eq $Auth) { return (Get-CopilotToken) }
    if ($Auth -is [string]) { return [string]$Auth }
    if ($Auth.Token) { return [string]$Auth.Token }
    if ($Auth.AccessToken) { return [string]$Auth.AccessToken }
    return $null
}

function Convert-CopilotAuth {
    param([string]$Token, [string]$Path, [string]$Source)
    if (-not $Token) { throw 'missing-credential' }
    $accountId = 'token:' + (Get-AccountFingerprint -AccountId $Token -Prefix 'tok')
    return [pscustomobject]@{
        Token       = $Token
        AccessToken = $Token
        AccountId   = $accountId
        Path        = $Path
        Source      = $Source
        Raw         = [pscustomobject]@{ token = $Token; accountId = $accountId }
    }
}

function Read-CopilotSnapshot {
    param([string]$Path)
    $raw = Read-SecureSnapshot -Path $Path
    $token = [string]$raw.token
    if (-not $token) { throw 'missing-credential' }
    $auth = Convert-CopilotAuth -Token $token -Path $Path -Source 'snapshot'
    if ($raw.accountId) { $auth.AccountId = [string]$raw.accountId }
    return $auth
}

function Get-CopilotAccounts {
    $active = $null
    $token = Get-CopilotToken
    if ($token) { $active = Convert-CopilotAuth -Token $token -Path 'live' -Source 'live' }
    return @(Get-MergedProviderAccounts -Provider copilot -Active $active -ReadPath {
        param($Path)
        Read-CopilotSnapshot -Path $Path
    })
}

function Sync-ActiveCopilotSnapshot {
    $token = Get-CopilotToken
    if (-not $token) { return }
    $active = Convert-CopilotAuth -Token $token -Path 'live' -Source 'live'
    [void](Write-SecureSnapshot -Provider copilot -AccountId $active.AccountId -Value $active.Raw)
}

function Add-CurrentCopilotAccount {
    $active = $null
    $token = Get-CopilotToken
    if ($token) { $active = Convert-CopilotAuth -Token $token -Path 'live' -Source 'live' }
    return (Add-CurrentSnapshotAccount -Provider copilot -Auth $active -Name $(if ($active) { Get-ProviderRowName $active 'Copilot' 'Copilot' } else { $null }))
}

function Get-CopilotToken {
    foreach ($path in @($script:CopilotHostsPath, $script:CopilotAppsPath, $script:CopilotOpencodeAuthPath)) {
        try {
            $token = Read-CopilotTokenFromFile -Path $path
            if ($token) { return $token }
        } catch { }
    }
    return $null
}

function Test-CopilotCredExists {
    return [bool](Get-CopilotToken)
}

function Get-CopilotAuthHeaders {
    param([string]$Token)
    return @{
        Authorization          = 'token ' + $Token
        Accept                 = 'application/json'
        'Editor-Version'       = 'vscode/1.96.2'
        'X-Github-Api-Version' = '2025-04-01'
        'User-Agent'           = 'ai-usage-widget'
    }
}

function Get-CopilotUsageSnapshot {
    param($Auth)
    $token = Get-CopilotAuthToken $Auth
    if (-not $token) { throw 'missing-credential' }
    $data = Invoke-WidgetRest -Method Get -Uri $script:CopilotUsageUrl -Headers (Get-CopilotAuthHeaders $token)
    $usage = Convert-CopilotQuota $data
    if (-not $usage -or -not $usage.Premium) { throw 'unexpected payload' }
    $usage.FetchedAt = (Get-Date)
    return $usage
}

function Get-CopilotRowData {
    param($Auth, [string]$Name)
    $usage = Get-CopilotUsageSnapshot -Auth $Auth
    $premium = $usage.Premium
    $details = @()
    if ($usage.Plan) { $details += $usage.Plan }
    if ($premium.Unlimited) {
        $details += (T 'row.copilotUnlimited')
    } else {
        $details += (T 'row.copilotPremium' @([Math]::Round($premium.Remaining), [Math]::Round($premium.Entitlement)))
    }
    $reset = Format-ResetText $usage.ResetAt
    if ($reset) { $details += $reset }
    Write-WidgetLog ('usage copilot {0} ok' -f $premium.UsedPercent)
    [pscustomobject]@{
        Percent   = $premium.UsedPercent
        Detail    = ($details -join ' · ')
        Tip       = (T 'row.copilotTip' @((Format-PercentText $premium.UsedPercent)))
        Reset     = $(if ($usage.ResetAt) { Format-ResetTime $usage.ResetAt } else { $null })
        ResetAt   = $(if ($usage.ResetAt) { ConvertTo-ResetStamp $usage.ResetAt } else { $null })
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
        [pscustomobject]@{ Id = 'demo-cline'; Kind = 'cline'; Name = $script:ClineDisplayName; OpenUrl = $script:ClineUsagePageUrl; Percent = 64.0; Detail = ((T 'row.window5hPercent' @(8)) + ' · ' + (T 'row.windowWeekPercent' @(31)) + ' · ' + (T 'row.windowMonthPercent' @(64)) + ' · ' + (T 'reset.daysHours' @(6, 12))); TrendPct = @(4, 10, 18, 27, 39, 52, 64) }
        [pscustomobject]@{ Id = 'demo-claude'; Kind = 'claude'; Name = $script:ClaudeDisplayName; OpenUrl = $script:ClaudeUsagePageUrl; Percent = 37.0; Detail = ((T 'row.window5hPercent' @(11)) + ' · ' + (T 'row.windowWeekPercent' @(37)) + ' · ' + (T 'reset.daysHours' @(4, 8))); TrendPct = @(12, 18, 22, 27, 31, 34, 37) }
        [pscustomobject]@{ Id = 'demo-cursor'; Kind = 'cursor'; Name = $script:CursorDisplayName; OpenUrl = $script:CursorUsagePageUrl; Percent = 58.0; Detail = (T 'row.limitUsage' @(11.6, 20, 58)); TrendPct = @(20, 28, 35, 42, 48, 53, 58) }
        [pscustomobject]@{ Id = 'demo-glm'; Kind = 'glm'; Name = $script:ZaiDisplayName; OpenUrl = $script:ZaiUsagePageUrl; Percent = 22.0; Detail = ((T 'row.window5hPercent' @(8)) + ' · ' + (T 'row.windowWeekPercent' @(22)) + ' · ' + (T 'reset.hoursMinutes' @(3, 10))); TrendPct = @(4, 7, 10, 13, 16, 19, 22) }
        [pscustomobject]@{ Id = 'demo-copilot'; Kind = 'copilot'; Name = $script:CopilotDisplayName; OpenUrl = $script:CopilotUsagePageUrl; Percent = 43.0; Detail = ((T 'row.copilotPremium' @(171, 300)) + ' · ' + (T 'reset.daysHours' @(14, 2))); TrendPct = @(6, 11, 17, 24, 31, 38, 43) }
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
    try { Sync-ActiveGeminiSnapshot } catch { Write-WidgetLog ("gemini snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-GeminiAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-GeminiRowId $acct
            Kind    = 'gemini'
            Name    = Get-GeminiRowName $acct
            OpenUrl = $script:GeminiUsagePageUrl
            Auth    = $acct
        }
    }
    try { Sync-ActiveKimiSnapshot } catch { Write-WidgetLog ("kimi snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-KimiAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'kimi'
            Kind    = 'kimi'
            Name    = Get-ProviderRowName $acct 'Kimi' 'Kimi'
            OpenUrl = $script:KimiUsagePageUrl
            Auth    = $acct
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
    try { Sync-ActiveCommandCodeSnapshot } catch { Write-WidgetLog ("commandcode snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-CommandCodeAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'commandcode'
            Kind    = 'commandcode'
            Name    = Get-ProviderRowName $acct 'CommandCode' $script:CommandCodeDisplayName
            OpenUrl = $script:CommandCodeUsagePageUrl
            Auth    = $acct
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
    if (Test-ClineCredExists) {
        $clineAccounts = @(Get-ClineAccounts)
        Sync-ActiveClineSnapshot $clineAccounts
        foreach ($acct in $clineAccounts) {
            $rows += [pscustomobject]@{
                Id      = Get-ClineRowId $acct
                Kind    = 'cline'
                Name    = Get-ClineRowName $acct
                OpenUrl = $script:ClineUsagePageUrl
                Auth    = $acct
            }
        }
    }
    try { Sync-ActiveClaudeSnapshot } catch { Write-WidgetLog ("claude snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-ClaudeAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'claude'
            Kind    = 'claude'
            Name    = Get-ProviderRowName $acct 'Claude' $script:ClaudeDisplayName
            OpenUrl = $script:ClaudeUsagePageUrl
            Auth    = $acct
        }
    }
    foreach ($acct in @(Get-CursorAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'cursor'
            Kind    = 'cursor'
            Name    = Get-ProviderRowName $acct 'Cursor' $script:CursorDisplayName
            OpenUrl = $script:CursorUsagePageUrl
            Auth    = $acct
        }
    }
    try { Sync-ActiveZaiSnapshot } catch { Write-WidgetLog ("glm snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-ZaiAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'glm'
            Kind    = 'glm'
            Name    = Get-ProviderRowName $acct 'GLM' $script:ZaiDisplayName
            OpenUrl = $script:ZaiUsagePageUrl
            Auth    = $acct
        }
    }
    try { Sync-ActiveCopilotSnapshot } catch { Write-WidgetLog ("copilot snapshot $($_.Exception.Message)") }
    foreach ($acct in @(Get-CopilotAccounts)) {
        $rows += [pscustomobject]@{
            Id      = Get-ProviderRowId $acct 'copilot'
            Kind    = 'copilot'
            Name    = Get-ProviderRowName $acct 'Copilot' $script:CopilotDisplayName
            OpenUrl = $script:CopilotUsagePageUrl
            Auth    = $acct
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
    $columns = 1
    try { if ($script:Config) { $columns = [int]$script:Config.columns } } catch { }
    $script:UiMetrics = Get-WidgetLayoutMetrics -Scale (Get-UiScale) -Layout $layout -ShowTrend $showTrend -Columns $columns
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
    $index = 0
    foreach ($spec in $Specs) {
        $anchor = Get-WidgetLayoutRowAnchor -Metrics $m -Index $index
        $x = $anchor.X
        $y = $anchor.Y
        $lblName = New-Label $Form "name-$index" $x ($y + $m.NameTop) $m.NameW $m.NameH $nameFont $fg 'MiddleLeft'
        $lblName.Text = $spec.Name
        $lblName.Tag = $spec.OpenUrl
        $lblName.AutoEllipsis = $true
        $lblPct = New-Label $Form "pct-$index" ($x + $m.NameW) $y $m.PctW $m.PctH $pctFont (Get-UsageColor 0) 'MiddleRight'
        $lblPct.Text = '--%'
        $lblPct.Tag = $spec.OpenUrl
        $lblPct.AutoEllipsis = $true

        $barBack = New-Object System.Windows.Forms.Panel
        $barBack.Location = New-Object System.Drawing.Point $x, ($y + $m.BarTop)
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
            $lblDetail = New-Label $Form "detail-$index" $x ($y + $m.DetailTop) $m.ContentW $m.DetailH $detailFont $muted 'MiddleLeft'
            $lblDetail.Text = ''
            $lblDetail.Tag = $spec.OpenUrl
            $lblDetail.AutoEllipsis = $true
        }

        # The sparkline shares the progress-bar row; when it is hidden the bar
        # keeps the full width (BarTrackW == ContentW).
        $trend = $null
        if ($m.BarTrackW -lt $m.ContentW) {
            $trend = New-Object System.Windows.Forms.Panel
            $trend.Location = New-Object System.Drawing.Point ($x + $m.BarTrackW + $m.TrendGap), ($y + $m.BarTop - $m.TrendPad)
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
        $index++
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

    $contentH = Get-FormHeight $Specs.Count
    $screen = if ($Form.Visible) { [System.Windows.Forms.Screen]::FromPoint($Form.Location) } else { [System.Windows.Forms.Screen]::PrimaryScreen }
    $maxH = [Math]::Max((Scale-Px 240), $screen.WorkingArea.Height - (Scale-Px 24))
    $Form.AutoScroll = ($contentH -gt $maxH)
    $Form.AutoScrollMinSize = New-Object System.Drawing.Size (0, $contentH)
    $h = [Math]::Min($contentH, $maxH)
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
    $script:Ui.Stamp.Top = $contentH - $m.StampInset
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
    param($Auth, [string]$Name)
    $u = Get-GeminiUsageSnapshot -Auth $Auth
    $details = @()
    if ($null -ne $u.Remain5h) { $details += (T 'row.remain5h' @($u.Remain5h)) }
    if ($null -ne $u.RemainWeekly) { $details += (T 'row.remainWeek' @($u.RemainWeekly)) }
    $details += Format-ResetText $u.PeriodEnd
    $display = if ($Name) { $Name } else { 'Gemini' }
    Write-WidgetLog ("usage gemini {0} remain={1} ok" -f $display, $u.Remaining)
    [pscustomobject]@{
        Percent = $u.Remaining
        Detail  = ($details -join ' · ')
        Tip     = (T 'row.geminiTip' @((Format-PercentText $u.Remaining)))
        Reset   = (Format-ResetTime $u.PeriodEnd)
        ResetAt = (ConvertTo-ResetStamp $u.PeriodEnd)
    }
}

function Get-KimiRowData {
    param($Auth, [string]$Name)
    $u = Get-KimiUsageSnapshot -Auth $Auth
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

function New-SettingMultilineText {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Value)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point $X, $Y
    $box.Size = New-Object System.Drawing.Size $W, $H
    $box.Text = $Value
    $box.Multiline = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-UiThemeColor $box 'BackColor' 'Field'
    Set-UiThemeColor $box 'ForeColor' 'Text'
    $box.Parent = $Parent
    return $box
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
    $dialog.ClientSize = New-Object System.Drawing.Size ((Scale-Px 360), (Scale-Px 586))
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
    $chkKimi = New-SettingCheckBox $dialog 'Kimi' (Scale-Px 292) (Scale-Px 200) ([bool]$current.providers.kimi)
    $chkCodex = New-SettingCheckBox $dialog 'ChatGPT' $colValue (Scale-Px 226) ([bool]$current.providers.codex)
    $chkClaude = New-SettingCheckBox $dialog 'Claude' (Scale-Px 208) (Scale-Px 226) ([bool]$current.providers.claude)
    $chkCursor = New-SettingCheckBox $dialog 'Cursor' (Scale-Px 292) (Scale-Px 226) ([bool]$current.providers.cursor)
    $chkCommandCode = New-SettingCheckBox $dialog 'Command Code' $colValue (Scale-Px 252) ([bool]$current.providers.commandcode)
    $chkDeepSeek = New-SettingCheckBox $dialog 'DeepSeek' (Scale-Px 208) (Scale-Px 252) ([bool]$current.providers.deepseek)
    $chkGlm = New-SettingCheckBox $dialog 'GLM' (Scale-Px 292) (Scale-Px 252) ([bool]$current.providers.glm)
    $chkOpenRouter = New-SettingCheckBox $dialog 'OpenRouter' $colValue (Scale-Px 278) ([bool]$current.providers.openrouter)
    $chkCopilot = New-SettingCheckBox $dialog 'Copilot' (Scale-Px 208) (Scale-Px 278) ([bool]$current.providers.copilot)
    $chkCline = New-SettingCheckBox $dialog 'Cline' (Scale-Px 292) (Scale-Px 278) ([bool]$current.providers.cline)

    [void](New-SettingLabel $dialog (T 'settings.columns') $colLabel (Scale-Px 304) $muted)
    $numColumns = New-SettingNumber $dialog $colValue (Scale-Px 304) (Scale-Px 70) $current.columns 1 3 1
    [void](New-SettingLabel $dialog (T 'settings.columnsHint') (Scale-Px 204) (Scale-Px 304) $muted)

    $chkDailySummary = New-SettingCheckBox $dialog (T 'settings.dailySummary') $colLabel (Scale-Px 330) ([bool]$current.dailySummary.enabled)
    $txtSummaryTime = New-SettingText $dialog (Scale-Px 124) (Scale-Px 330) (Scale-Px 62) ([string]$current.dailySummary.time)
    [void](New-SettingLabel $dialog (T 'settings.dailySummaryHint') (Scale-Px 190) (Scale-Px 330) $muted)

    [void](New-SettingLabel $dialog (T 'settings.providerThresholds') $colLabel (Scale-Px 356) $muted)
    $txtProviderThresholds = New-SettingMultilineText $dialog $colLabel (Scale-Px 378) (Scale-Px 324) (Scale-Px 48) (Format-ProviderAlertThresholds $current.providerAlertThresholds)

    [void](New-SettingLabel $dialog (T 'settings.language') $colLabel (Scale-Px 434) $muted)
    $comboItems = @((T 'settings.languageAuto'), (T 'settings.languageZh'), (T 'settings.languageEn'))
    $cmbLanguage = New-SettingCombo $dialog $colValue (Scale-Px 434) (Scale-Px 150) $comboItems $languageIndex

    [void](New-SettingLabel $dialog (T 'settings.theme') $colLabel (Scale-Px 460) $muted)
    $themes = @('dark', 'light')
    $themeIndex = [Math]::Max(0, [Array]::IndexOf($themes, [string]$current.theme))
    $themeItems = @((T 'settings.themeDark'), (T 'settings.themeLight'))
    $cmbTheme = New-SettingCombo $dialog $colValue (Scale-Px 460) (Scale-Px 150) $themeItems $themeIndex

    $chkCompact = New-SettingCheckBox $dialog (T 'settings.compact') $colLabel (Scale-Px 486) ([string]$current.layout -eq 'compact')
    $chkLock = New-SettingCheckBox $dialog (T 'settings.lockPosition') (Scale-Px 208) (Scale-Px 486) ([bool]$current.lockPosition)

    $lblStatus = New-SettingLabel $dialog (T 'settings.restartHint') $colLabel (Scale-Px 514) $muted

    $btnSave = New-SettingButton $dialog (T 'settings.save') (Scale-Px 176) (Scale-Px 544)
    $btnCancel = New-SettingButton $dialog (T 'settings.cancel') (Scale-Px 268) (Scale-Px 544)

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
                    cline       = [bool]$chkCline.Checked
                    claude      = [bool]$chkClaude.Checked
                    cursor      = [bool]$chkCursor.Checked
                    glm         = [bool]$chkGlm.Checked
                    copilot     = [bool]$chkCopilot.Checked
                }
                theme           = $themes[$cmbTheme.SelectedIndex]
                layout          = $(if ($chkCompact.Checked) { 'compact' } else { 'full' })
                columns         = [int]$numColumns.Value
                dailySummary    = @{
                    enabled = [bool]$chkDailySummary.Checked
                    time    = $txtSummaryTime.Text
                }
                lockPosition    = [bool]$chkLock.Checked
                providerAlertThresholds = ConvertFrom-ProviderAlertThresholdsText $txtProviderThresholds.Text
            }
            $script:Config = Convert-WidgetConfig $picked
            $script:State.interval = [int]$script:Config.intervalSeconds
            if (-not $script:DemoMode) {
                [void](Write-WidgetConfig -Config $script:Config)
                Save-State $script:Ui.Form
            }
            Write-WidgetLog ('settings saved: interval={0}s opacity={1} trend={2} forecast={3} days={4} language={5} openrouter={6} deepseek={7} theme={8} layout={9} lock={10} columns={11}' -f $script:Config.intervalSeconds, $script:Config.opacity, $script:Config.showTrend, $script:Config.showForecast, $script:Config.trendDays, $script:Config.language, $script:Config.providers.openrouter, $script:Config.providers.deepseek, $script:Config.theme, $script:Config.layout, $script:Config.lockPosition, $script:Config.columns)
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

function Show-AccountManager {
    $rows = @($script:AccountSpecs)
    if ($rows.Count -eq 0) { return }
    $muted = (Get-WidgetColor 'Muted')
    $form = New-Object System.Windows.Forms.Form
    $form.Text = (T 'accounts.title')
    $form.Size = New-Object System.Drawing.Size (Scale-Px 600), (Scale-Px 440)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point (Scale-Px 12), (Scale-Px 12)
    $list.Size = New-Object System.Drawing.Size (Scale-Px 560), (Scale-Px 310)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.CheckBoxes = $true
    $list.HideSelection = $false
    [void]$list.Columns.Add((T 'accounts.name'), (Scale-Px 180))
    [void]$list.Columns.Add((T 'accounts.provider'), (Scale-Px 120))
    [void]$list.Columns.Add((T 'accounts.source'), (Scale-Px 120))
    [void]$list.Columns.Add((T 'accounts.identity'), (Scale-Px 120))
    $hidden = @($script:Config.hiddenAccounts)
    $aliases = $script:Config.accountAliases
    foreach ($row in $rows) {
        $source = ''
        try { $source = if ([string]$row.Auth.Path -like '*.snapshot') { 'snapshot' } else { [string]$row.Auth.Source } } catch { }
        $accountId = ''
        try { $accountId = [string]$row.Auth.AccountId } catch { }
        $alias = if ($aliases.ContainsKey([string]$row.Id)) { [string]$aliases[[string]$row.Id] } else { '' }
        $item = New-Object System.Windows.Forms.ListViewItem ([string]$row.Name)
        [void]$item.SubItems.Add([string]$row.Kind)
        [void]$item.SubItems.Add($source)
        [void]$item.SubItems.Add((Get-AccountFingerprint -AccountId $accountId -Prefix 'acct'))
        $item.Checked = ($hidden -notcontains [string]$row.Id)
        $item.Tag = @{ Row = $row; Alias = $alias }
        [void]$list.Items.Add($item)
    }

    $aliasLabel = New-SettingLabel $form (T 'accounts.alias') (Scale-Px 12) (Scale-Px 334) $muted
    $aliasText = New-SettingText $form '' (Scale-Px 105) (Scale-Px 330) (Scale-Px 180)
    $status = New-SettingLabel $form '' (Scale-Px 12) (Scale-Px 372) $muted
    $btnUp = New-SettingButton $form (T 'accounts.moveUp') (Scale-Px 300) (Scale-Px 328)
    $btnDown = New-SettingButton $form (T 'accounts.moveDown') (Scale-Px 390) (Scale-Px 328)
    $btnRemove = New-SettingButton $form (T 'accounts.removeSnapshot') (Scale-Px 300) (Scale-Px 366)
    $btnClose = New-SettingButton $form (T 'accounts.close') (Scale-Px 480) (Scale-Px 366)

    $syncAlias = {
        $item = if ($list.SelectedItems.Count -gt 0) { $list.SelectedItems[0] } else { $null }
        if (-not $item) { $aliasText.Text = ''; return }
        $aliasText.Text = [string]$item.Tag.Alias
    }
    $list.Add_SelectedIndexChanged($syncAlias)
    $aliasText.Add_Leave({
        if ($list.SelectedItems.Count -eq 0) { return }
        $item = $list.SelectedItems[0]
        $item.Tag.Alias = $aliasText.Text.Trim()
        $item.Text = if ($item.Tag.Alias) { [string]$item.Tag.Alias } else { [string]$item.Tag.Row.Name }
    })
    $move = {
        param([int]$Delta)
        if ($list.SelectedItems.Count -eq 0) { return }
        $item = $list.SelectedItems[0]
        $index = $item.Index
        $target = $index + $Delta
        if ($target -lt 0 -or $target -ge $list.Items.Count) { return }
        $list.Items.RemoveAt($index)
        $list.Items.Insert($target, $item)
        $item.Selected = $true
        $item.EnsureVisible()
    }
    $btnUp.Add_Click({ & $move -1 })
    $btnDown.Add_Click({ & $move 1 })
    $btnRemove.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $item = $list.SelectedItems[0]
        $row = $item.Tag.Row
        $path = [string]$row.Auth.Path
        if ($path -notlike '*.snapshot') {
            $status.Text = T 'accounts.activeNotRemoved'
            return
        }
        try {
            Remove-SecureSnapshot -Path $path
            $list.Items.Remove($item)
            $status.Text = T 'accounts.removed'
        } catch {
            $status.Text = Convert-SafeLogText $_.Exception.Message 80
        }
    })
    $btnClose.Add_Click({
        $order = @($list.Items | ForEach-Object { [string]$_.Tag.Row.Id })
        $hiddenIds = @($list.Items | Where-Object { -not $_.Checked } | ForEach-Object { [string]$_.Tag.Row.Id })
        $aliasMap = @{}
        foreach ($item in @($list.Items)) {
            if ($item.Tag.Alias) { $aliasMap[[string]$item.Tag.Row.Id] = [string]$item.Tag.Alias }
        }
        $script:Config.accountOrder = $order
        $script:Config.hiddenAccounts = $hiddenIds
        $script:Config.accountAliases = $aliasMap
        try { [void](Write-WidgetConfig -Config $script:Config) } catch { }
        $form.Close()
        Update-Widget -Force
    })
    $form.AcceptButton = $btnClose
    $form.CancelButton = $btnClose
    [void]$form.ShowDialog($script:Ui.Form)
    $form.Dispose()
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
    $lblStamp = New-Label $form 'stamp' $m.MarginX ($form.Height - $m.StampInset) ($m.FormWidth - $m.MarginX * 2) $m.StampH $footFont $dim 'MiddleCenter'
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
    $miAddGemini = $menu.Items.Add((T 'menu.registerGemini'))
    $miAddKimi = $menu.Items.Add((T 'menu.registerKimi'))
    $miAddClaude = $menu.Items.Add((T 'menu.registerClaude'))
    $miAddCommandCode = $menu.Items.Add((T 'menu.registerCommandCode'))
    $miAddCursor = $menu.Items.Add((T 'menu.registerCursor'))
    $miAddGlm = $menu.Items.Add((T 'menu.registerGlm'))
    $miAddCopilot = $menu.Items.Add((T 'menu.registerCopilot'))
    $miAddCline = $menu.Items.Add((T 'menu.registerCline'))
    $miAdd = $menu.Items.Add((T 'menu.registerChatgpt'))
    $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.openUsage')
    $miOpenGrok = $miOpen.DropDownItems.Add('Grok')
    $miOpenGemini = $miOpen.DropDownItems.Add('Gemini')
    $miOpenKimi = $miOpen.DropDownItems.Add('Kimi')
    $miOpenCodex = $miOpen.DropDownItems.Add('ChatGPT')
    $miOpenCommandCode = $miOpen.DropDownItems.Add('Command Code')
    $miOpenOpenRouter = $miOpen.DropDownItems.Add('OpenRouter')
    $miOpenDeepSeek = $miOpen.DropDownItems.Add('DeepSeek')
    $miOpenCline = $miOpen.DropDownItems.Add('Cline')
    $miOpenClaude = $miOpen.DropDownItems.Add('Claude')
    $miOpenCursor = $miOpen.DropDownItems.Add('Cursor')
    $miOpenGlm = $miOpen.DropDownItems.Add('GLM')
    $miOpenCopilot = $miOpen.DropDownItems.Add('Copilot')
    [void]$menu.Items.Add($miOpen)
    $miExport = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.export')
    $miExportRaw = $miExport.DropDownItems.Add((T 'menu.exportRawCsv'))
    $miExportDaily = $miExport.DropDownItems.Add((T 'menu.exportDailyCsv'))
    $miExportReportMd = $miExport.DropDownItems.Add((T 'menu.exportReportMd'))
    $miExportReportHtml = $miExport.DropDownItems.Add((T 'menu.exportReportHtml'))
    $miExportCompareMd = $miExport.DropDownItems.Add((T 'menu.exportCompareMd'))
    $miExportCompareHtml = $miExport.DropDownItems.Add((T 'menu.exportCompareHtml'))
    [void]$menu.Items.Add($miExport)
    $miTrend = $menu.Items.Add((T 'menu.trend'))
    $miAccounts = $menu.Items.Add((T 'menu.accounts'))
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

    $form.Add_DpiChanged({
        $script:UiScale = ([double]$_.NewDpi / 96.0)
        $script:UiMetrics = $null
        if ($script:Fonts) {
            foreach ($f in $script:Fonts.Values) { try { $f.Dispose() } catch { } }
            $script:Fonts = $null
        }
        if ($script:CurrentSpecs.Count -gt 0) { Rebuild-ProviderRows $form $script:CurrentSpecs }
    })

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { try { Update-Widget -Force } catch { Write-WidgetLog ("f5 $($_.Exception.Message)") } }
    })

    $miRefresh.Add_Click({ try { Update-Widget -Force } catch { Write-WidgetLog ("refresh $($_.Exception.Message)") } })
    $miExportRaw.Add_Click({ Export-UsageHistoryInteractive })
    $miExportDaily.Add_Click({ Export-UsageReportInteractive -Kind 'daily' })
    $miExportReportMd.Add_Click({ Export-UsageReportInteractive -Kind 'markdown' })
    $miExportReportHtml.Add_Click({ Export-UsageReportInteractive -Kind 'html' })
    $miExportCompareMd.Add_Click({ Export-UsageReportComparisonInteractive -Kind 'markdown' -Months 3 })
    $miExportCompareHtml.Add_Click({ Export-UsageReportComparisonInteractive -Kind 'html' -Months 3 })
    $miTrend.Add_Click({ Show-WidgetTrend -Days $script:TrendDays })
    $miAccounts.Add_Click({ Show-AccountManager })
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
    $miAddGemini.Add_Click({
        $result = Add-CurrentGeminiAccount
        Update-Widget
        try {
            if ($result.Status -eq 'same-account') {
                $msg = (T 'cli.geminiSameAccount' @($result.Name))
                $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
            } elseif ($result.Status -eq 'registered') {
                $msg = (T 'cli.geminiRegistered' @($result.Name))
                $script:Ui.Tray.ShowBalloonTip(6000, (T 'app.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), (T 'cli.geminiAuthMissing'), [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        } catch { }
    })
    $miAddKimi.Add_Click({ Show-AccountRegistration (Add-CurrentKimiAccount); Update-Widget -Force })
    $miAddClaude.Add_Click({ Show-AccountRegistration (Add-CurrentClaudeAccount); Update-Widget -Force })
    $miAddCommandCode.Add_Click({ Show-AccountRegistration (Add-CurrentCommandCodeAccount); Update-Widget -Force })
    $miAddCursor.Add_Click({ Show-AccountRegistration (Add-CurrentCursorAccount); Update-Widget -Force })
    $miAddGlm.Add_Click({ Show-AccountRegistration (Add-CurrentZaiAccount); Update-Widget -Force })
    $miAddCopilot.Add_Click({ Show-AccountRegistration (Add-CurrentCopilotAccount); Update-Widget -Force })
    $miAddCline.Add_Click({
        $result = Add-CurrentClineAccount
        Update-Widget
        try {
            if ($result.Status -eq 'same-account') {
                $msg = (T 'cli.clineSameAccount' @($result.Name))
                $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
            } elseif ($result.Status -eq 'registered') {
                $msg = (T 'cli.clineRegistered' @($result.Name))
                $script:Ui.Tray.ShowBalloonTip(6000, (T 'app.title'), $msg, [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $script:Ui.Tray.ShowBalloonTip(8000, (T 'app.title'), (T 'cli.clineAuthMissing'), [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        } catch { }
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
    $miOpenCline.Add_Click({ Start-Process $script:ClineUsagePageUrl })
    $miOpenClaude.Add_Click({ Start-Process $script:ClaudeUsagePageUrl })
    $miOpenCursor.Add_Click({ Start-Process $script:CursorUsagePageUrl })
    $miOpenGlm.Add_Click({ Start-Process $script:ZaiUsagePageUrl })
    $miOpenCopilot.Add_Click({ Start-Process $script:CopilotUsagePageUrl })
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
            if ($script:TrendWindowRequested) {
                try { Show-WidgetTrend -Days $script:TrendDays } catch { Write-WidgetLog ("trend window $($_.Exception.Message)") }
            }
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
    param([string]$Id, $ErrorRecord)
    $n = 1
    if ($script:FailCount.ContainsKey($Id)) { $n = [int]$script:FailCount[$Id] + 1 }
    $script:FailCount[$Id] = $n
    $category = Get-FetchFailureCategory -ErrorRecord $ErrorRecord -Message ([string]$ErrorRecord)
    $seed = if ($Id) { [int]([Math]::Abs($Id.GetHashCode()) % 20) } else { 0 }
    $sec = Get-ProviderBackoffSeconds -Category $category -FailureCount $n -JitterSeed $seed
    $script:BackoffUntil[$Id] = [datetime]::UtcNow.AddSeconds($sec)
    Write-WidgetLog ("backoff {0} category={1} retry={2}s fails={3}" -f $Id, $category, $sec, $n)
    return $script:BackoffUntil[$Id]
}

function Update-Widget {
    param([switch]$Force)
    $ui = $script:Ui
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    if ($script:FetchRunning) { return }

    try {
        $allSpecs = @(Get-ProviderRows | Where-Object { Test-ProviderEnabled $script:Config $_.Kind })
        $script:AccountSpecs = $allSpecs
        $specs = @(Apply-WidgetAccountPreferences -Rows $allSpecs -Config $script:Config)
        $script:CurrentSpecs = $specs
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
        Start-BackgroundFetch $specs -Force:$Force
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
        'Test-FiniteNumber', 'Assert-UsagePercent', 'Assert-PositiveFiniteNumber', 'Convert-UsageRatioPercent', 'Convert-OptionalNumber',
        'Assert-CredentialAccountId', 'Set-CredentialVersion', 'Assert-CredentialIdentity',
        'Test-CredentialAccountChanged', 'Test-CredentialStale',
        'Resolve-TrustedHttpsEndpoint', 'Get-WidgetTrustedHosts', 'Assert-TrustedHttpsHost', 'Get-AccountFingerprint', 'Convert-SafeLogText',
        'Get-SecureSnapshotRoot', 'Get-SecureSnapshotPath', 'ConvertTo-SnapshotCipherText',
        'ConvertFrom-SnapshotCipherText', 'Set-SecureSnapshotAcl', 'Invoke-SecureSnapshotFileLock', 'Move-SecureSnapshotFile',
        'Write-SecureSnapshotLocked', 'Write-JsonFileAtomic', 'Update-JsonFile',
        'Write-SecureSnapshot', 'Update-SecureSnapshot', 'Read-SecureSnapshot',
        'Get-SecureSnapshotFiles', 'Remove-SecureSnapshot',
        'Get-GrokAccountId', 'Get-GrokAccountFingerprint', 'Get-GrokAccountAlias', 'Get-GrokAliasPath', 'Get-GrokAliasMap',
        'Get-GrokAccountLabel', 'Get-GrokRowName', 'Get-GrokRowId',
        'Get-GrokSnapshotFileName', 'Get-GrokSnapshotPath', 'Get-GrokLegacySnapshotPath', 'Convert-GrokRawAuth', 'Read-GrokAuthFromFile',
        'Get-GrokAccounts', 'Sync-ActiveGrokSnapshot', 'Sync-GrokAuthFromDisk',
        'Get-ProductLabel', 'Read-GrokAuth', 'Set-GrokAuthFields', 'Save-GrokAuth', 'Update-GrokToken',
        'Get-GrokAuthHeaders', 'Invoke-GrokGet', 'Get-GrokUsageSnapshot', 'Get-GrokRowData',
        'Ensure-AntigravityCredType', 'Test-AntigravityCredExists', 'Read-AntigravityCred',
        'Save-AntigravityCred', 'Update-AntigravityToken', 'Get-AntigravityAuth',
        'Get-GeminiPropertyText', 'Get-GeminiJwtEmail', 'Get-GeminiAccountId', 'Convert-GeminiRawAuth',
        'Set-GeminiAuthFields', 'Save-GeminiSnapshot', 'Save-GeminiAuth',
        'Convert-GeminiQuota', 'Invoke-AntigravityQuota', 'Get-GeminiUsageSnapshot', 'Get-GeminiRowData',
        'Get-KimiAccountId', 'Convert-KimiRawAuth', 'Read-KimiAuthFromFile',
        'Set-KimiAuthFields', 'Save-KimiSnapshot', 'Get-KimiHosts', 'Read-KimiAuth', 'Save-KimiAuth', 'Update-KimiToken',
        'Invoke-KimiGet', 'Get-KimiWindowLabel', 'Resolve-KimiUsedLimit', 'Convert-KimiUsagePayload',
        'Get-KimiUsageSnapshot', 'Get-KimiRowData',
        'Get-TokenEmail', 'Convert-CodexRawAuth', 'Read-CodexAuth', 'Get-AccountLabel', 'Get-SnapshotPath', 'Set-CodexAuthFields', 'Save-CodexAuth',
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
        'Get-DeepSeekUsageSnapshot', 'Get-DeepSeekRowData',
        'Get-ClineProperty', 'Convert-ClineResetTime', 'Convert-ClineUsageLimit', 'Convert-ClineUsageLimits',
        'Convert-ClineAuthExpiry', 'ConvertTo-ClineStoredAccessToken', 'Get-ClineAuthEntry', 'Convert-ClineRawAuth',
        'Read-ClineAuth', 'Get-ClineSnapshotPath', 'Set-ClineAuthFields', 'Save-ClineSnapshot', 'Save-ClineAuth', 'Update-ClineToken',
        'Get-ClineAuthHeaders', 'Get-ClineUsageSnapshot', 'Get-ClineRowData',
        'Get-ClaudeAccountId', 'Convert-ClaudeWindow', 'Convert-ClaudeUsage', 'Convert-ClaudeRawAuth',
        'Test-ClaudeCredExists', 'Read-ClaudeAuthFromFile', 'Set-ClaudeAuthFields', 'Save-ClaudeSnapshot', 'Save-ClaudeAuth', 'Update-ClaudeToken',
        'Get-ClaudeAuthHeaders', 'Get-ClaudeUsageSnapshot', 'Get-ClaudeRowData',
        'ConvertTo-CursorDollars', 'Convert-CursorUnixMs', 'Get-CursorPlanUsageObject', 'Convert-CursorPeriodUsage',
        'Find-Utf8NeedleIndex', 'Get-CursorJwtFromBytes', 'Get-CursorSqliteTextValue',
        'Get-CursorStateDbPath', 'Read-CursorAuth', 'Test-CursorCredExists', 'Get-CursorUsageSnapshot', 'Get-CursorRowData',
        'Convert-ZaiResetTime', 'Convert-ZaiLimitItem', 'Test-ZaiFiveHourType', 'Test-ZaiWeeklyType',
        'Get-ZaiBusinessError', 'Get-ZaiBigModelKey', 'Convert-ZaiQuota',
        'Get-ZaiZcodeKey', 'Resolve-ZaiCredential', 'Test-ZaiCredExists',
        'Get-ZaiAuthHeaders', 'Get-ZaiUsageSnapshot', 'Get-ZaiRowData',
        'Get-CopilotProperty', 'Convert-CopilotQuotaDetail', 'Convert-CopilotResetDate', 'Convert-CopilotQuota',
        'ConvertTo-CopilotTokenText', 'Find-CopilotToken',
        'Get-CopilotAuthToken', 'Read-CopilotTokenFromFile', 'Get-CopilotToken', 'Test-CopilotCredExists', 'Get-CopilotAuthHeaders',
        'Get-CopilotUsageSnapshot', 'Get-CopilotRowData'
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
                   'DeepSeekAuthPath', 'DeepSeekApiBaseUrl', 'DeepSeekDisplayName',
                   'ClineProvidersPath', 'ClineUsageUrl', 'ClineRefreshUrl', 'ClineDisplayName',
                   'ClaudeCredPath', 'ClaudeUsageUrl', 'ClaudeTokenUrl', 'ClaudeTokenUrlLegacy', 'ClaudeOAuthClientId', 'ClaudeDisplayName',
                   'CursorStateDbPath', 'CursorUsageUrl', 'CursorDisplayName', 'CursorTokenCache',
                   'ZaiAuthPath', 'ZhipuAuthPath', 'BigModelAuthPath', 'ZcodeConfigPath', 'ZaiApiBaseUrl', 'ZhipuApiBaseUrl', 'ZaiDisplayName',
                   'CopilotHostsPath', 'CopilotAppsPath', 'CopilotOpencodeAuthPath', 'CopilotUsageUrl', 'CopilotDisplayName',
                   'SecureSnapshotRoot',
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
            'gemini' { $d = Get-GeminiRowData -Auth $row.Auth -Name $row.Name }
            'kimi'  { $d = Get-KimiRowData -Auth $row.Auth -Name $row.Name }
            'codex' { $d = Get-CodexRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            'commandcode' { $d = Get-CommandCodeRowData -Auth $row.Auth -Name $row.Name }
            'openrouter' { $d = Get-OpenRouterRowData -Auth $row.Auth -Name $row.Name -Id $row.Id }
            'deepseek' { $d = Get-DeepSeekRowData -Auth $row.Auth -Name $row.Name }
            'cline' { $d = Get-ClineRowData -Auth $row.Auth -Name $row.Name }
            'claude' { $d = Get-ClaudeRowData -Auth $row.Auth -Name $row.Name }
            'cursor' { $d = Get-CursorRowData -Auth $row.Auth -Name $row.Name }
            'glm' { $d = Get-ZaiRowData -Auth $row.Auth -Name $row.Name }
            'copilot' { $d = Get-CopilotRowData -Auth $row.Auth -Name $row.Name }
            default { throw '未找到登录凭证' }
        }
        $results += [pscustomobject]@{ Id = $row.Id; Percent = $d.Percent; Display = $d.Display; Detail = $d.Detail; Tip = $d.Tip; Reset = $d.Reset; ResetAt = $d.ResetAt; MetricType = $d.MetricType; Value = $d.Value; Unit = $d.Unit; Window = $d.Window; Cycle = $d.Cycle; Used = $d.Used; Limit = $d.Limit; FetchedAt = $d.FetchedAt; Error = $null }
    } catch {
            $results += [pscustomobject]@{ Id = $row.Id; Percent = $null; Detail = $null; Tip = $null; Reset = $null; ResetAt = $null; Error = (Convert-SafeLogText $_.Exception.Message 240) }
    }
}
$results
'@)
    return $sb.ToString()
}

function Start-BackgroundFetch {
    param($Specs, [switch]$Force)
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
        ClineProvidersPath       = $script:ClineProvidersPath
        ClineUsageUrl            = $script:ClineUsageUrl
        ClineRefreshUrl          = $script:ClineRefreshUrl
        ClineDisplayName         = $script:ClineDisplayName
        ClaudeCredPath           = $script:ClaudeCredPath
        ClaudeUsageUrl           = $script:ClaudeUsageUrl
        ClaudeTokenUrl           = $script:ClaudeTokenUrl
        ClaudeTokenUrlLegacy     = $script:ClaudeTokenUrlLegacy
        ClaudeOAuthClientId      = $script:ClaudeOAuthClientId
        ClaudeDisplayName        = $script:ClaudeDisplayName
        CursorStateDbPath        = $script:CursorStateDbPath
        CursorUsageUrl           = $script:CursorUsageUrl
        CursorDisplayName        = $script:CursorDisplayName
        CursorTokenCache         = $script:CursorTokenCache
        ZaiAuthPath              = $script:ZaiAuthPath
        ZhipuAuthPath            = $script:ZhipuAuthPath
        BigModelAuthPath         = $script:BigModelAuthPath
        ZcodeConfigPath          = $script:ZcodeConfigPath
        ZaiApiBaseUrl            = $script:ZaiApiBaseUrl
        ZhipuApiBaseUrl          = $script:ZhipuApiBaseUrl
        ZaiDisplayName           = $script:ZaiDisplayName
        CopilotHostsPath        = $script:CopilotHostsPath
        CopilotAppsPath         = $script:CopilotAppsPath
        CopilotOpencodeAuthPath = $script:CopilotOpencodeAuthPath
        CopilotUsageUrl         = $script:CopilotUsageUrl
        CopilotDisplayName      = $script:CopilotDisplayName
        SecureSnapshotRoot       = $script:SecureSnapshotRoot
        WidgetStrings            = $script:WidgetStrings
        Language                 = $script:Language
    }
    $rows = @()
    foreach ($s in $Specs) {
        if (-not $Force -and (Test-ProviderBackoff $s.Id)) {
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
    $chunks = @(Split-WidgetProviderRows -Rows $rows -MaxWorkers 3)
    $maxWorkers = [Math]::Max(1, $chunks.Count)
    if (-not $script:WorkerPool) {
        $script:WorkerPool = [runspacefactory]::CreateRunspacePool(1, 3)
        $script:WorkerPool.ApartmentState = 'MTA'
        $script:WorkerPool.Open()
    }
    $script:FetchGeneration++
    $generation = $script:FetchGeneration
    $jobs = @()
    foreach ($chunk in @($chunks | Where-Object { @($_).Count -gt 0 })) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:WorkerPool
        [void]$ps.AddScript($script:WorkerSrc)
        [void]$ps.AddArgument(@($chunk))
        [void]$ps.AddArgument($cfg)
        $jobs += @{
            Ps         = $ps
            Handle     = $ps.BeginInvoke()
            StartedAt  = Get-Date
            Rows       = @($chunk)
            Generation = $generation
        }
    }
    $script:FetchJob = @{
        Jobs       = @($jobs)
        StartedAt  = Get-Date
        Generation = $generation
        Force      = [bool]$Force
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
    $metricType = $null
    $value = $null
    $unit = $null
    $window = $null
    $cycle = $null
    $used = $null
    $limit = $null
    $fetchedAt = $null
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
        try { if ($Raw.MetricType) { $metricType = [string]$Raw.MetricType } } catch { }
        try { $value = Convert-OptionalNumber -Value $Raw.Value -Field 'history value' } catch { }
        try { if ($Raw.Unit) { $unit = [string]$Raw.Unit } } catch { }
        try { if ($Raw.Window) { $window = [string]$Raw.Window } } catch { }
        try { if ($Raw.Cycle) { $cycle = [string]$Raw.Cycle } } catch { }
        try { $used = Convert-OptionalNumber -Value $Raw.Used -Field 'history used' } catch { }
        try { $limit = Convert-OptionalNumber -Value $Raw.Limit -Field 'history limit' } catch { }
        try { if ($Raw.FetchedAt) { $fetchedAt = [datetime]$Raw.FetchedAt } } catch { }
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
        MetricType = $metricType
        Value   = $value
        Unit    = $unit
        Window  = $window
        Cycle   = $cycle
        Used    = $used
        Limit   = $limit
        FetchedAt = $fetchedAt
        Error   = $err
    }
}

function Clear-FetchJobs {
    try { if ($script:Ui -and $script:Ui.Poll) { $script:Ui.Poll.Stop() } } catch { }
    if ($script:FetchJob) {
        foreach ($job in @($script:FetchJob.Jobs)) {
            try { $job.Ps.Stop() } catch { }
            try { $job.Ps.Dispose() } catch { }
        }
        $script:FetchJob = $null
    }
    $script:FetchRunning = $false
}

function Close-WorkerRunspace {
    Clear-FetchJobs
    if ($script:WorkerPool) {
        try { $script:WorkerPool.Close() } catch { }
        try { $script:WorkerPool.Dispose() } catch { }
        $script:WorkerPool = $null
    }
}

function Receive-BackgroundFetch {
    $job = $script:FetchJob
    if (-not $job) {
        try { $script:Ui.Poll.Stop() } catch { }
        $script:FetchRunning = $false
        return
    }
    if ($job.Generation -ne $script:FetchGeneration) { Clear-FetchJobs; return }
    $batch = @()
    $remaining = @()
    $hadTimeout = $false
    foreach ($workerJob in @($job.Jobs)) {
        $done = $false
        try { $done = [bool]$workerJob.Handle.IsCompleted } catch { $done = $false }
        if (-not $done) {
            if ((Get-Date) - $workerJob.StartedAt -gt [timespan]::FromMinutes(3)) {
                $hadTimeout = $true
                try { $workerJob.Ps.Stop() } catch { }
                foreach ($row in @($workerJob.Rows)) {
                    $batch += [pscustomobject]@{ Id = $row.Id; Error = 'timeout'; Percent = $null; Detail = $null; Tip = $null; Reset = $null; ResetAt = $null }
                }
                try { $workerJob.Ps.Dispose() } catch { }
            } else {
                $remaining += $workerJob
            }
            continue
        }
        $out = $null
        try {
            $iar = $workerJob.Handle
            try { if ($iar.PSObject -and $iar.PSObject.BaseObject) { $iar = $iar.PSObject.BaseObject } } catch { }
            $out = $workerJob.Ps.EndInvoke([System.IAsyncResult]$iar)
            if ($workerJob.Ps.HadErrors) {
                $err0 = $null
                try { $err0 = $workerJob.Ps.Streams.Error | Select-Object -First 1 } catch { }
                if ($err0) { Write-WidgetLog ("bg fetch error: {0}" -f $err0.ToString()) }
            }
        } catch {
            Write-WidgetLog ("bg fetch failed: {0}" -f $_.Exception.Message)
        } finally {
            try { $workerJob.Ps.Dispose() } catch { }
        }
        foreach ($item in @($out)) {
            $rowData = Convert-FetchRow $item
            if ($rowData.Id) { $batch += ,$rowData }
        }
    }
    if (@($batch).Count -gt 0) {
        try {
            Apply-FetchResults @($batch) -StillRunning:(@($remaining).Count -gt 0)
            Write-WidgetLog ("applied {0}" -f @($batch).Count)
        } catch {
            Write-WidgetLog ("apply $($_.Exception.Message)`n$($_.ScriptStackTrace)")
        }
    } elseif (@($remaining).Count -eq 0 -and $script:Ui -and -not $script:Ui.Form.IsDisposed) {
        $script:Ui.Stamp.Text = (T 'status.updated' @([datetime]::Now.ToString('HH:mm')))
    }
    if (@($remaining).Count -gt 0) {
        $job.Jobs = @($remaining)
        if ($script:Ui -and -not $script:Ui.Form.IsDisposed) { $script:Ui.Stamp.Text = (T 'status.refreshing') }
    } else {
        $script:FetchJob = $null
        $script:FetchRunning = $false
        try { if ($script:Ui -and $script:Ui.Poll) { $script:Ui.Poll.Stop() } } catch { }
    }
    if ($hadTimeout -and $script:Ui -and -not $script:Ui.Form.IsDisposed) { $script:Ui.Stamp.Text = (T 'status.refreshTimeout') }
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

function Select-UsageReportScope {
    param($Records, [string]$DefaultMonth)
    $months = @(Get-UsageHistoryMonths $Records)
    if ($months.Count -eq 0) { return $null }
    $ids = @($Records | ForEach-Object { [string]$_.Id } | Where-Object { $_ } | Sort-Object -Unique)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = (T 'report.scopeTitle')
    $form.ClientSize = New-Object System.Drawing.Size ((Scale-Px 340), (Scale-Px 150))
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $muted = (Get-WidgetColor 'Muted')
    [void](New-SettingLabel $form (T 'report.month') (Scale-Px 14) (Scale-Px 18) $muted)
    $monthCombo = New-SettingCombo $form $months (Scale-Px 110) (Scale-Px 14) (Scale-Px 200)
    $monthIndex = [array]::IndexOf($months, $DefaultMonth)
    if ($monthIndex -ge 0) { $monthCombo.SelectedIndex = $monthIndex }
    [void](New-SettingLabel $form (T 'report.account') (Scale-Px 14) (Scale-Px 54) $muted)
    $accountItems = @((T 'report.allAccounts')) + $ids
    $accountCombo = New-SettingCombo $form $accountItems (Scale-Px 110) (Scale-Px 50) (Scale-Px 200)
    $accountCombo.SelectedIndex = 0
    $btnOk = New-SettingButton $form (T 'report.export') (Scale-Px 140) (Scale-Px 100)
    $btnCancel = New-SettingButton $form (T 'settings.cancel') (Scale-Px 230) (Scale-Px 100)
    $result = $null
    $btnOk.Add_Click({
        $selectedAccount = if ($accountCombo.SelectedIndex -gt 0) { [string]$accountCombo.SelectedItem } else { '' }
        $result = @{ Month = [string]$monthCombo.SelectedItem; Id = $selectedAccount }
        $form.Close()
    })
    $btnCancel.Add_Click({ $form.Close() })
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel
    [void]$form.ShowDialog($script:Ui.Form)
    $form.Dispose()
    return $result
}

# 月度报表导出：默认导出“最近有数据的月份”，没有历史时给出明确提示。
function Export-UsageReportInteractive {
    param([string]$Kind)
    try {
        $now = [datetime]::Now
        $records = @(Read-UsageHistory -Path $script:HistoryPath)
        if ($records.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show((T 'report.empty'), (T 'csv.title'), 'OK', 'Information') | Out-Null
            return
        }
        $months = @(Get-UsageHistoryMonths $records)
        $month = if ($months.Count -gt 0) { $months[0] } else { ConvertTo-UsageReportMonth -Value $null -Now $now }
        $scope = Select-UsageReportScope -Records $records -DefaultMonth $month
        if (-not $scope) { return }
        $month = [string]$scope.Month
        $accountId = [string]$scope.Id
        $rollup = @(Get-UsageHistoryDailyRollup -Records $records -Month $month -Now $now -Id $accountId)
        $summary = @(Get-UsageHistoryMonthlySummary -Records $records -Month $month -Now $now -Id $accountId)
        $inventory = Get-UsageHistoryInventory -Path $script:HistoryPath -MaxBytes $script:Config.historyMaxBytes

        $extension = 'csv'
        $content = $null
        switch ($Kind) {
            'markdown' {
                $extension = 'md'
                $content = ConvertTo-UsageReportMarkdown -Summary $summary -Rollup $rollup -Month $month -GeneratedAt $now -Inventory $inventory
            }
            'html' {
                $extension = 'html'
                $content = ConvertTo-UsageReportHtml -Summary $summary -Rollup $rollup -Month $month -GeneratedAt $now -Inventory $inventory
            }
            default {
                $content = ConvertTo-UsageReportCsv $rollup
            }
        }
        if (-not $content) {
            [System.Windows.Forms.MessageBox]::Show((T 'report.empty'), (T 'csv.title'), 'OK', 'Information') | Out-Null
            return
        }
        $target = Join-Path $script:WidgetDir (Get-UsageReportFileName -Month $month -Extension $extension)
        # CSV 带 BOM 让 Excel 直接认出中文；Markdown / HTML 不需要 BOM。
        [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new(($extension -eq 'csv')))
        Write-WidgetLog ("report export {0} {1}" -f $extension, $target)
        [System.Windows.Forms.MessageBox]::Show(
            (T 'report.exported' @([Environment]::NewLine, $target)),
            (T 'csv.title'), 'OK', 'Information') | Out-Null
    } catch {
        Write-WidgetLog ("report export failed: $($_.Exception.Message)")
        try {
            [System.Windows.Forms.MessageBox]::Show((T 'report.failed'), (T 'csv.title'), 'OK', 'Warning') | Out-Null
        } catch { }
    }
}

# 多月对比导出：默认最近 3 个月，没有历史时同样只提示、不写文件。
function Export-UsageReportComparisonInteractive {
    param([string]$Kind, [int]$Months = 3)
    try {
        $now = [datetime]::Now
        $records = @(Read-UsageHistory -Path $script:HistoryPath)
        $keys = @(Get-UsageReportComparisonMonths -Records $records -Months $Months -Now $now)
        if ($records.Count -eq 0 -or $keys.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show((T 'report.empty'), (T 'csv.title'), 'OK', 'Information') | Out-Null
            return
        }
        $comparison = @(Get-UsageHistoryMonthComparison -Records $records -Months $keys -Now $now)
        $extension = 'md'
        $content = $null
        switch ($Kind) {
            'html' {
                $extension = 'html'
                $content = ConvertTo-UsageReportComparisonHtml -Comparison $comparison -Months $keys -GeneratedAt $now
            }
            default {
                $content = ConvertTo-UsageReportComparisonMarkdown -Comparison $comparison -Months $keys -GeneratedAt $now
            }
        }
        if (-not $content) {
            [System.Windows.Forms.MessageBox]::Show((T 'report.empty'), (T 'csv.title'), 'OK', 'Information') | Out-Null
            return
        }
        $target = Join-Path $script:WidgetDir (Get-UsageReportComparisonFileName -Months $keys -Extension $extension)
        # 对比报表是给人看与传阅的，Markdown / HTML 都不加 BOM。
        [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
        Write-WidgetLog ("report export comparison {0} {1}" -f $extension, $target)
        [System.Windows.Forms.MessageBox]::Show(
            (T 'report.exported' @([Environment]::NewLine, $target)),
            (T 'csv.title'), 'OK', 'Information') | Out-Null
    } catch {
        Write-WidgetLog ("report export failed: $($_.Exception.Message)")
        try {
            [System.Windows.Forms.MessageBox]::Show((T 'report.failed'), (T 'csv.title'), 'OK', 'Warning') | Out-Null
        } catch { }
    }
}
# 趋势图文案：语言包缺键时回落到内置英文，避免窗口标题出现 trend.title 这类键名。
function Get-UsageTrendLabels {
    $labels = @{
        Title = 'AI Usage Widget - Trend chart'
        Days  = 'Last {0} days'
        Empty = 'No history yet, nothing to chart'
        Note  = 'Each line is the last sample of each day'
        Close = 'Close'
    }
    if (Get-Command T -ErrorAction SilentlyContinue) {
        $labels.Title = (Use-WidgetTextFallback (T 'trend.title') 'trend.title' $labels.Title)
        $labels.Days = (Use-WidgetTextFallback (T 'trend.days') 'trend.days' $labels.Days)
        $labels.Empty = (Use-WidgetTextFallback (T 'trend.empty') 'trend.empty' $labels.Empty)
        $labels.Note = (Use-WidgetTextFallback (T 'trend.note') 'trend.note' $labels.Note)
        $labels.Close = (Use-WidgetTextFallback (T 'about.close') 'about.close' $labels.Close)
    }
    return $labels
}

# 趋势图窗口：只读展示，不写任何文件。demo 模式用合成序列，
# 所以 -Demo -TrendWindow 在没有凭证、没有历史时也能跑冒烟与截图。
function Show-WidgetTrend {
    param([int]$Days = 7)
    $labels = Get-UsageTrendLabels
    $muted = (Get-WidgetColor 'Muted')
    $dayOptions = @(7, 14, 30)
    $days = [int]$Days
    if ($dayOptions -notcontains $days) { $days = 7 }

    # 已经打开一个趋势图时只把它提到前面，不叠第二个窗口。
    if ($script:TrendForm -and -not $script:TrendForm.IsDisposed) {
        try { $script:TrendForm.Activate() } catch { }
        return
    }

    $specs = @()
    try { $specs = @(Get-ProviderRows) } catch { $specs = @() }
    $records = @()
    if (-not $script:DemoMode) {
        try { $records = @(Read-UsageHistory -Path $script:HistoryPath -Since ((Get-Date).AddDays(-30))) } catch { $records = @() }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $labels.Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.ClientSize = New-Object System.Drawing.Size ((Scale-Px 720), (Scale-Px 396))
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-UiThemeColor $form 'BackColor' 'Background'
    Set-UiThemeColor $form 'ForeColor' 'Text'

    $pad = Scale-Px 18
    $dayIndex = [array]::IndexOf([object[]]$dayOptions, [object]$days)
    if ($dayIndex -lt 0) { $dayIndex = 0 }
    $combo = New-SettingCombo $form $pad (Scale-Px 14) (Scale-Px 138) @($dayOptions | ForEach-Object { $labels.Days -f $_ }) $dayIndex
    [void](New-SettingLabel $form $labels.Note (Scale-Px 172) (Scale-Px 18) $muted)

    $chart = New-Object System.Windows.Forms.Panel
    $chart.Location = New-Object System.Drawing.Point $pad, (Scale-Px 48)
    $chart.Size = New-Object System.Drawing.Size (($form.ClientSize.Width - 2 * $pad), ($form.ClientSize.Height - (Scale-Px 48) - (Scale-Px 76)))
    $chart.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    Set-UiColor $chart 'BackColor' ((Get-WidgetColor 'Field').ToArgb())
    $chart.Parent = $form

    $legend = New-SettingLabel $form '' $pad ($form.ClientSize.Height - (Scale-Px 62)) $muted
    $legend.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $legend.MaximumSize = New-Object System.Drawing.Size (($form.ClientSize.Width - 2 * $pad - (Scale-Px 100)), 0)
    $legend.AutoEllipsis = $true

    $btnClose = New-SettingButton $form $labels.Close 0 0
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Location = New-Object System.Drawing.Point (($form.ClientSize.Width - $pad - $btnClose.Width), ($form.ClientSize.Height - (Scale-Px 42)))
    $btnClose.Add_Click({ if ($script:TrendForm) { $script:TrendForm.Close() } })
    $form.CancelButton = $btnClose

    $script:TrendUi = @{
        Form    = $form
        Chart   = $chart
        Legend  = $legend
        Combo   = $combo
        Labels  = $labels
        Specs   = $specs
        Records = $records
        Days    = $days
        # 窗口是非模态的，事件处理器在函数返回后才触发，看不到本地变量，
        # 所以下拉框选项与重建回调都要挂到 $script:TrendUi 上。
        DayOptions = $dayOptions
        Model   = @()
        Gutter  = @{ Left = (Scale-Px 36); Top = (Scale-Px 12); Right = (Scale-Px 12); Bottom = (Scale-Px 24) }
    }

    # 重建绘图模型：天数变化、窗口尺寸变化与数据变化都走这里。
    $rebuild = {
        $ui = $script:TrendUi
        if (-not $ui) { return }
        $days = [int]$ui.Days
        $startDay = ([datetime]::Now.Date).AddDays(-($days - 1))
        $entries = @()
        foreach ($spec in @($ui.Specs)) {
            $series = @()
            try {
                if ($script:DemoMode) { $series = @(New-UsageTrendDemoSeries -EndPct ([double]$spec.Percent) -Days $days) }
                else { $series = @(Get-UsageHistoryDaySeries -Records $ui.Records -Id $spec.Id -Days $days -Kind $spec.Kind) }
            } catch { $series = @() }
            if (@($series).Count -lt 1) { continue }
            $entries += @{ Id = $spec.Id; Name = $spec.Name; Series = $series }
        }
        $gutter = $ui.Gutter
        $plotW = [Math]::Max(0, $ui.Chart.ClientSize.Width - $gutter.Left - $gutter.Right)
        $plotH = [Math]::Max(0, $ui.Chart.ClientSize.Height - $gutter.Top - $gutter.Bottom)
        $model = @(Get-UsageTrendChartModel -Entries $entries -StartDay $startDay -Days $days -Width $plotW -Height $plotH -Pad 0)
        $ui.Model = $model
        $ui.Chart.Tag = @{ Days = $days; StartDay = $startDay; Model = $model }
        Write-WidgetLog ('trend rebuilt days={0} series={1} demo={2}' -f $days, @($model).Count, $script:DemoMode)
        $parts = @()
        foreach ($item in $model) {
            $value = '-'
            if (Test-FiniteNumber $item.Latest) { $value = (Get-UsageReportNumber $item.Latest) }
            $parts += ('{0} {1}%' -f $item.Name, $value)
        }
        $ui.Legend.Text = ($parts -join '   ·   ')
        $ui.Chart.Invalidate()
    }

    # 折线画在 Panel 上：坐标已经按 0 - 100 换算好，这里只补边距、坐标轴与颜色。
    $paintChart = {
        param($sender, $e)
        $ui = $script:TrendUi
        $tag = $sender.Tag
        if (-not $ui -or -not $tag) { return }
        $gridPen = $null
        $mutedBrush = $null
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $gutter = $ui.Gutter
            $font = $sender.Font
            $gridPen = New-Object System.Drawing.Pen ((Get-WidgetColor 'Track')), 1
            $mutedBrush = New-Object System.Drawing.SolidBrush ((Get-WidgetColor 'Muted'))
            $left = [float]$gutter.Left
            $top = [float]$gutter.Top
            $plotW = [float][Math]::Max(0, $sender.ClientSize.Width - $gutter.Left - $gutter.Right)
            $plotH = [float][Math]::Max(0, $sender.ClientSize.Height - $gutter.Top - $gutter.Bottom)
            if ($plotW -le 1 -or $plotH -le 1) { return }

            $range = Get-UsageTrendChartRange
            foreach ($tick in @(Get-UsageTrendChartTicks -Min $range.Min -Max $range.Max)) {
                $ratio = ($tick - $range.Min) / ($range.Max - $range.Min)
                $y = $top + $plotH * (1.0 - $ratio)
                $g.DrawLine($gridPen, $left, $y, ($left + $plotW), $y)
                $text = [string][int]$tick
                $size = $g.MeasureString($text, $font)
                $g.DrawString($text, $font, $mutedBrush, ($left - 4 - $size.Width), ($y - $size.Height / 2))
            }
            foreach ($day in @(Get-UsageTrendChartDayLabels -StartDay $tag.StartDay -Days $tag.Days)) {
                $x = $left + $plotW * $day.Offset / ($tag.Days - 1)
                $text = ([datetime]$day.Day).ToString('MM-dd')
                $size = $g.MeasureString($text, $font)
                # 首尾日期居中会顶出面板，夹回面板内，避免最后一个日期被裁掉半截。
                $textX = $x - $size.Width / 2
                $textX = [Math]::Max([float]0, [Math]::Min($textX, [float]($sender.ClientSize.Width - $size.Width)))
                $g.DrawString($text, $font, $mutedBrush, $textX, ($top + $plotH + 2))
            }

            $model = @($tag.Model)
            if ($model.Count -eq 0) {
                $text = [string]$ui.Labels.Empty
                $size = $g.MeasureString($text, $font)
                $g.DrawString($text, $font, $mutedBrush, ($left + ($plotW - $size.Width) / 2), ($top + ($plotH - $size.Height) / 2))
                return
            }
            foreach ($item in $model) {
                $points = @($item.Points)
                if ($points.Count -lt 1) { continue }
                $color = (Get-UsageColor ([double]$item.Latest))
                if ($points.Count -eq 1) {
                    $dot = New-Object System.Drawing.SolidBrush $color
                    $g.FillEllipse($dot, ($left + [float]$points[0].X - 2), ($top + [float]$points[0].Y - 2), 4, 4)
                    $dot.Dispose()
                    continue
                }
                $pts = New-Object 'System.Drawing.PointF[]' $points.Count
                for ($i = 0; $i -lt $points.Count; $i++) {
                    $pts[$i] = [System.Drawing.PointF]::new(($left + [float]$points[$i].X), ($top + [float]$points[$i].Y))
                }
                $pen = New-Object System.Drawing.Pen $color, 1.8
                $g.DrawLines($pen, $pts)
                $pen.Dispose()
            }
        } catch { } finally {
            if ($gridPen) { $gridPen.Dispose() }
            if ($mutedBrush) { $mutedBrush.Dispose() }
        }
    }

    $chart.Add_Paint($paintChart)
    # 拉伸窗口时坐标要按新的面板尺寸重算，否则折线还留在旧几何上。
    $chart.Add_Resize({
        $ui = $script:TrendUi
        if ($ui -and $ui.Rebuild) { & $ui.Rebuild }
    })
    $combo.Add_SelectedIndexChanged({
        $ui = $script:TrendUi
        if (-not $ui) { return }
        $options = @($ui.DayOptions)
        $index = [int]$ui.Combo.SelectedIndex
        if ($index -lt 0 -or $index -ge $options.Count) { return }
        $ui.Days = [int]$options[$index]
        $script:TrendDays = [int]$options[$index]
        & $ui.Rebuild
    })
    $form.Add_FormClosed({
        $script:TrendForm = $null
        $script:TrendUi = $null
    })

    $script:TrendUi.Rebuild = $rebuild
    & $rebuild
    $script:TrendForm = $form
    $form.Show()
    Write-WidgetLog ('trend window shown days={0} series={1} demo={2}' -f $days, @($script:TrendUi.Model).Count, $script:DemoMode)
    if ($script:DemoMode) {
        Write-WidgetLog ('trend demo series days={0} series={1} synthetic=true' -f $days, @($script:TrendUi.Model).Count)
    }
}
function Write-UsageHistory {
    param(
        [string]$Id,
        [double]$Percent,
        [string]$Provider,
        [string]$AccountId,
        [string]$MetricType = 'percent',
        $Value,
        [string]$Unit,
        [string]$Window,
        [string]$Cycle,
        [string]$ResetAt,
        $Used,
        $Limit,
        [string]$SampleState = 'changed'
    )
    try {
        if ($script:DemoMode) { return }
        $retentionDays = if ($script:Config) { [int]$script:Config.historyRetentionDays } else { 90 }
        $maxBytes = if ($script:Config) { [long]$script:Config.historyMaxBytes } else { 10485760 }
        [void](Write-UsageHistoryRecord -Path $script:HistoryPath -Id $Id -Provider $Provider -AccountId $AccountId `
            -MetricType $MetricType -Percent $Percent -Value $Value -Unit $Unit -Window $Window -Cycle $Cycle `
            -ResetAt $ResetAt -Used $Used -Limit $Limit -SampleState $SampleState `
            -RetentionDays $retentionDays -MaxBytes $maxBytes)
    } catch {
        Write-WidgetLog ('history write failed: ' + $_.Exception.Message)
    }
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

# 每日汇总：到点后每天最多弹一次气泡；日期写进 ai-state.json，重启后不会重复提醒。
function Send-DailySummaryIfDue {
    if ($script:DemoMode) { return }
    $now = Get-Date
    $last = [string]::Empty
    try { if ($script:State.lastSummaryDate) { $last = [string]$script:State.lastSummaryDate } } catch { }
    $due = $false
    try { $due = Test-DailySummaryDue -Config $script:Config -Now $now -LastDate $last } catch { return }
    if (-not $due) { return }
    $parts = @()
    foreach ($row in @($script:Ui.Rows)) {
        if ($row.Pct -and $row.Pct.Text -and $row.Pct.Text -ne '--%') {
            $parts += ('{0} {1}' -f $row.Name, $row.Pct.Text)
        }
    }
    if ($parts.Count -eq 0) { return }
    $script:State.lastSummaryDate = $now.ToString('yyyy-MM-dd')
    Save-State $null
    Write-WidgetLog ('daily summary sent: {0} rows' -f $parts.Count)
    $body = T 'alert.summaryBody' @($now.ToString('HH:mm'), $parts.Count, ($parts -join ', '))
    try {
        $script:Ui.Tray.ShowBalloonTip(8000, (T 'alert.summaryTitle'), $body, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
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
    $historySampleMinutes = 15
    try {
        if ($script:Config) {
            $wantTrend = [bool]$script:Config.showTrend
            $showForecast = [bool]$script:Config.showForecast
            $trendDays = [int]$script:Config.trendDays
            $historySampleMinutes = [int]$script:Config.historySampleMinutes
        }
    } catch { }
    $historySince = (Get-Date).AddDays(-[Math]::Max(1, $trendDays))
    $historyRecords = @(Read-UsageHistory -Path $script:HistoryPath -Since $historySince)
    $historyLatest = @{}
    foreach ($record in $historyRecords) {
        if (-not $record -or -not $record.Id) { continue }
        $id = [string]$record.Id
        if (-not $historyLatest.ContainsKey($id) -or [datetime]$record.Ts -ge [datetime]$historyLatest[$id].Ts) {
            $historyLatest[$id] = $record
        }
    }
    foreach ($r in @($Results)) {
        if (-not $r -or -not $r.Id) { continue }
        $row = @($ui.Rows | Where-Object { $_.Id -eq $r.Id })[0]
        if (-not $row) { continue }
        if ($r.Error) {
            $nextRetry = Register-ProviderFailure $r.Id $r.Error
            $safeError = Convert-SafeLogText ([string]$r.Error) 240
            Write-WidgetLog ("error {0}: {1}" -f $r.Id, $safeError)
            $errorText = Format-FetchError $safeError
            $state = if ($script:RowState.ContainsKey($r.Id)) { $script:RowState[$r.Id] } else { $null }
            $lastSuccessText = if ($state -and $state.LastSuccessAt) { T 'row.stale' @($state.LastSuccessAt.ToString('HH:mm')) } else { $null }
            if ($lastSuccessText) { $errorText += (' · ' + $lastSuccessText) }
            Set-RowError $row $errorText
            Set-RowTip $row @((T 'tip.errorTitle' @($row.Name)), (Format-FetchError $safeError -Detail), $lastSuccessText, (T 'row.nextRetry' @($nextRetry.ToLocalTime().ToString('HH:mm'))))
            $script:RowState[$r.Id] = @{ LastSuccessAt = $(if ($state) { $state.LastSuccessAt } else { $null }); LastText = $(if ($state) { $state.LastText } else { $null }); NextRetry = $nextRetry }
        } else {
            try {
                $pct = Assert-UsagePercent $r.Percent 'provider result percent'
            } catch {
                $nextRetry = Register-ProviderFailure $r.Id $_
                $safeError = Convert-SafeLogText $_.Exception.Message
                Write-WidgetLog ("error {0}: {1}" -f $r.Id, $safeError)
                $state = if ($script:RowState.ContainsKey($r.Id)) { $script:RowState[$r.Id] } else { $null }
                $lastSuccessText = if ($state -and $state.LastSuccessAt) { T 'row.stale' @($state.LastSuccessAt.ToString('HH:mm')) } else { $null }
                $errorText = Format-FetchError $safeError
                if ($lastSuccessText) { $errorText += (' · ' + $lastSuccessText) }
                Set-RowError $row $errorText
                Set-RowTip $row @((T 'tip.errorTitle' @($row.Name)), (Format-FetchError $safeError -Detail), $lastSuccessText, (T 'row.nextRetry' @($nextRetry.ToLocalTime().ToString('HH:mm'))))
                continue
            }
            Register-ProviderSuccess $r.Id
            $recentRequest = Get-RecentRequestLabel $row $requestEvents
            $rowDetail = [string]$r.Detail
            if ($recentRequest) { $rowDetail = @($rowDetail, $recentRequest) -join ' · ' }
            Set-RowUsage $row $pct $rowDetail $r.Display
            $script:RowState[$r.Id] = @{
                LastSuccessAt = Get-Date
                LastText = (Format-RowValueText -Display $r.Display -Percent $pct)
                NextRetry = $null
            }
            $script:LastOkAt = Get-Date

            $usageNow = Convert-DisplayPercentToUsagePercent $pct $row.Kind
            $metricType = if ($r.MetricType) { [string]$r.MetricType } elseif ($row.Kind -eq 'deepseek') { 'balance' } else { 'percent' }
            $forecastLine = $null
            $series = @()
            if ($historyRecords.Count -gt 0 -and $metricType -eq 'percent') {
                $series = @(Get-UsageHistoryDaySeries -Records $historyRecords -Id $r.Id -Days $trendDays -Kind $row.Kind -ResetAt ([string]$r.ResetAt))
                if ($wantTrend) { Set-RowTrend $row $series $usageNow }
                if ($showForecast) {
                    $forecastSince = (Get-Date).AddDays(-[Math]::Max(1, $trendDays))
                    $forecastSeries = @(Get-UsageHistorySampleSeries -Records $historyRecords -Id $r.Id -Since $forecastSince -Kind $row.Kind -ResetAt ([string]$r.ResetAt))
                    $forecastLine = Format-ForecastText (Get-UsageForecast -Series $forecastSeries -CurrentPercent $usageNow -ResetAt $r.ResetAt)
                }
            }

            $delta = $null
            if ($script:LastPct.ContainsKey($r.Id)) { $delta = $pct - [double]$script:LastPct[$r.Id] }
            $script:LastPct[$r.Id] = $pct
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

            $latest = if ($historyLatest.ContainsKey($r.Id)) { $historyLatest[$r.Id] } else { $null }
            $changed = $false
            if ($metricType -eq 'percent') {
                $changed = $null -eq $latest -or $null -eq $latest.Pct -or [Math]::Abs($usageNow - [double]$latest.Pct) -ge 0.05
            } else {
                $changed = $null -eq $latest -or $null -eq $latest.Value -or [Math]::Abs([double]$r.Value - [double]$latest.Value) -ge 0.000001
            }
            $scheduled = $null -eq $latest -or ((Get-Date) - [datetime]$latest.Ts).TotalMinutes -ge $historySampleMinutes
            if ($changed -or $scheduled) {
                $accountId = ''
                try { $accountId = [string]$row.Auth.AccountId } catch { }
                Write-UsageHistory -Id $r.Id -Percent $(if ($metricType -eq 'percent') { $usageNow } else { 0.0 }) `
                    -Provider $row.Kind -AccountId $accountId -MetricType $metricType -Value $r.Value `
                    -Unit $r.Unit -Window $r.Window -Cycle $(if ($r.Cycle) { $r.Cycle } else { $r.ResetAt }) -ResetAt $r.ResetAt `
                    -Used $r.Used -Limit $r.Limit -SampleState $(if ($changed) { 'changed' } else { 'scheduled' })
            }
            Send-UsageAlert $row $r.Id $pct
        }
    }
    if (-not $StillRunning) { Send-DailySummaryIfDue }
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
if ($AddGeminiAccount) { Add-CurrentGeminiAccount; return }
if ($AddKimiAccount) { Add-CurrentKimiAccount; return }
if ($AddClaudeAccount) { Add-CurrentClaudeAccount; return }
if ($AddCommandCodeAccount) { Add-CurrentCommandCodeAccount; return }
if ($AddCursorAccount) { Add-CurrentCursorAccount; return }
if ($AddGlmAccount) { Add-CurrentZaiAccount; return }
if ($AddCopilotAccount) { Add-CurrentCopilotAccount; return }
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
