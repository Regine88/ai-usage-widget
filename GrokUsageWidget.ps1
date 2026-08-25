# Grok weekly usage desktop widget.
# Polls cli-chat-proxy.grok.com with the local grok login token.

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
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
    if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $argList += @('-IntervalSeconds', "$IntervalSeconds") }
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:HomeDir = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $env:USERPROFILE '.grok' }
$script:AuthPath = Join-Path $script:HomeDir 'auth.json'
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:WidgetDir = Split-Path -Parent $script:SelfPath
$script:StatePath = Join-Path $script:WidgetDir 'state.json'
$script:LogPath = Join-Path $script:WidgetDir 'widget.log'
$script:VbsPath = Join-Path $script:WidgetDir 'Start-GrokUsageWidget.vbs'

$script:Mutex = $null
$script:Usage = $null
$script:LastError = $null
$script:LastOkAt = $null
$script:Drag = $false
$script:DragOffset = [System.Drawing.Point]::Empty
$script:State = @{ x = $null; y = $null; topMost = $false }
$script:DesktopHost = [IntPtr]::Zero

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
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string win);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
}
"@ -ErrorAction SilentlyContinue
    try { [NativeWin]::SetProcessDPIAware() | Out-Null } catch { }
    try {
        $hwnd = [NativeWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [NativeWin]::ShowWindow($hwnd, 0) | Out-Null }
    } catch { }
}

function Get-FormScreenPoint {
    param($Form)
    return $Form.Location
}

function Set-FormScreenPoint {
    param($Form, [int]$X, [int]$Y)
    $Form.Location = New-Object System.Drawing.Point $X, $Y
}

function Send-BehindWindows {
    param($Form)
    if (-not $Form -or $Form.IsDisposed) { return }
    if ($Form.TopMost) { return }
    $hwndBottom = [IntPtr]1
    [void][NativeWin]::SetWindowPos($Form.Handle, $hwndBottom, 0, 0, 0, 0, 0x0013)
}

function Enable-DesktopPin {
    param($Form)
    $Form.TopMost = $false
    if ($Form.Handle -ne [IntPtr]::Zero) {
        [void][NativeWin]::SetParent($Form.Handle, [IntPtr]::Zero)
    }
    $script:DesktopHost = [IntPtr]::Zero
    $Form.Visible = $true
    Send-BehindWindows $Form
    Write-WidgetLog 'desktop z-order, not topmost'
    return $true
}

function Disable-DesktopPin {
    param($Form)
    $script:DesktopHost = [IntPtr]::Zero
    [void][NativeWin]::SetParent($Form.Handle, [IntPtr]::Zero)
    $Form.Visible = $true
    Write-WidgetLog 'floating over windows'
}

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
    } catch { }
}

function Save-State {
    param($Form)
    try {
        if ($Form) {
            $pt = Get-FormScreenPoint $Form
            $script:State.x = $pt.X
            $script:State.y = $pt.Y
            $script:State.topMost = [bool]$Form.TopMost
        }
        $dir = Split-Path -Parent $script:StatePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = @{
            x = $script:State.x
            y = $script:State.y
            topMost = $script:State.topMost
        } | ConvertTo-Json -Compress
        $tmp = "$script:StatePath.tmp"
        Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    } catch { }
}

function Read-GrokAuth {
    if (-not (Test-Path -LiteralPath $script:AuthPath)) {
        throw '未找到 ~/.grok/auth.json，请先运行 grok login'
    }
    $raw = Get-Content -LiteralPath $script:AuthPath -Raw -Encoding utf8 | ConvertFrom-Json
    $best = $null
    $bestKey = $null
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
            $bestKey = $p.Name
        }
    }
    if (-not $best) { throw 'auth.json 中没有可用的登录凭证' }
    [pscustomobject]@{
        KeyName      = $bestKey
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
    $tmp = "$script:AuthPath.tmp-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:AuthPath -Force
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
    $resp = Invoke-RestMethod -Method Post -Uri 'https://auth.x.ai/oauth2/token' -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15
    if (-not $resp.access_token) { throw '刷新令牌失败，请运行 grok login' }
    $expires = [datetime]::UtcNow.AddSeconds([int]($resp.expires_in))
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.RefreshToken }
    Save-GrokAuth -Auth $Auth -AccessToken $resp.access_token -RefreshToken $newRefresh -ExpiresAt $expires
    $Auth.Token = [string]$resp.access_token
    $Auth.RefreshToken = $newRefresh
    $Auth.ExpiresAt = $expires
    Write-WidgetLog 'token refreshed'
    return $Auth
}

function Get-AuthHeaders {
    param($Auth)
    return @{
        Authorization        = "Bearer $($Auth.Token)"
        'x-xai-token-auth'   = 'xai-grok-cli'
        Accept               = 'application/json'
        'User-Agent'         = 'grok-usage-widget'
    }
}

function Invoke-GrokGet {
    param($Auth, [string]$Url)
    try {
        return Invoke-RestMethod -Method Get -Uri $Url -Headers (Get-AuthHeaders $Auth) -TimeoutSec 15
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -in 401, 403) {
            $Auth = Update-GrokToken -Auth $Auth
            return Invoke-RestMethod -Method Get -Uri $Url -Headers (Get-AuthHeaders $Auth) -TimeoutSec 15
        }
        throw
    }
}

function Get-GrokUsageSnapshot {
    $auth = Read-GrokAuth
    if ($auth.ExpiresAt -and $auth.ExpiresAt.ToUniversalTime() -lt [datetime]::UtcNow.AddMinutes(2)) {
        try { $auth = Update-GrokToken -Auth $auth } catch { Write-WidgetLog "preemptive refresh failed: $($_.Exception.Message)" }
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

    $start = $null
    $end = $null
    if ($cfg.currentPeriod) {
        $start = Convert-ApiTime $cfg.currentPeriod.start
        $end = Convert-ApiTime $cfg.currentPeriod.end
    }
    if (-not $end) { $end = Convert-ApiTime $cfg.billingPeriodEnd }
    if (-not $start) { $start = Convert-ApiTime $cfg.billingPeriodStart }

    $products = @()
    if ($cfg.productUsage) {
        foreach ($p in @($cfg.productUsage)) {
            $products += [pscustomobject]@{
                Name    = Get-ProductLabel ([string]$p.product)
                Percent = [double]$p.usagePercent
            }
        }
    }

    $plan = 'SuperGrok'
    try {
        $settings = Invoke-GrokGet -Auth $auth -Url 'https://cli-chat-proxy.grok.com/v1/settings'
        if ($settings.subscription_tier_display) { $plan = [string]$settings.subscription_tier_display }
    } catch { }

    $prepaid = 0
    if ($cfg.prepaidBalance -and $null -ne $cfg.prepaidBalance.val) { $prepaid = [int]$cfg.prepaidBalance.val }

    [pscustomobject]@{
        Percent     = [Math]::Round($pct, 1)
        Remaining   = [Math]::Max(0, [Math]::Round(100.0 - $pct, 1))
        Plan        = $plan
        PeriodStart = $start
        PeriodEnd   = $end
        Products    = $products
        PrepaidCents = $prepaid
        Email       = $auth.Email
        FetchedAt   = [datetime]::Now
    }
}

function Format-ResetText {
    param($End)
    if (-not $End) { return '重置时间未知' }
    $local = $End.ToLocalTime()
    $span = $local - [datetime]::Now
    if ($span.TotalSeconds -le 0) { return '本周额度即将重置' }
    if ($span.TotalDays -ge 1) {
        return ('重置还有 {0} 天 {1} 小时' -f [int][Math]::Floor($span.TotalDays), $span.Hours)
    }
    if ($span.TotalHours -ge 1) {
        return ('重置还有 {0} 小时 {1} 分钟' -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
    }
    return ('重置还有 {0} 分钟' -f [Math]::Max(1, [int]$span.TotalMinutes))
}

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Grok 周用量.lnk'
}

function Get-DesktopShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Desktop')) 'Grok 周用量.lnk'
}

function Write-LauncherVbs {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    $ps1 = $script:SelfPath
    $content = @"
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Wscript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\GrokUsageWidget.ps1"
sh.Run """$pwsh"" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
"@
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
    if (-not (Test-Path -LiteralPath $script:WidgetDir)) {
        New-Item -ItemType Directory -Path $script:WidgetDir -Force | Out-Null
    }
    Write-LauncherVbs
    New-Shortcut -Path (Get-StartupShortcutPath) -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 Grok 周用量卡片'
    Write-Host "已写入开机启动。程序目录: $($script:WidgetDir)"
}

function Uninstall-Widget {
    foreach ($p in @((Get-DesktopShortcutPath), (Get-StartupShortcutPath))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Write-Host "已移除开机启动和桌面快捷方式。程序仍在 $($script:WidgetDir)"
}

function Ensure-SingleInstance {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\GrokUsageDesktopWidget')
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
            $pt = Get-FormScreenPoint $f
            $clamped = Get-ClampedLocation $pt.X $pt.Y $f.Width $f.Height
            Set-FormScreenPoint $f $clamped.X $clamped.Y
            Save-State $f
            Send-BehindWindows $f
        }
    })
    $Control.Add_MouseDoubleClick({ Start-Process 'https://grok.com/?_s=usage' })
}

function New-WidgetForm {
    Read-State
    Hide-ConsoleWindow

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '周用量'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Size = New-Object System.Drawing.Size(280, 214)
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

    $fg = [System.Drawing.Color]::FromArgb(244, 244, 247)
    $muted = [System.Drawing.Color]::FromArgb(152, 152, 160)
    $dim = [System.Drawing.Color]::FromArgb(108, 108, 116)
    $bigFont = New-Object System.Drawing.Font('Segoe UI Semibold', 32)
    $capFont = New-Object System.Drawing.Font('Segoe UI', 9)
    $chipFont = New-Object System.Drawing.Font('Segoe UI', 9)
    $footFont = New-Object System.Drawing.Font('Segoe UI', 8.5)

    $lblPct = New-Label $form 'pct' 16 18 248 52 $bigFont (Get-UsageColor 0) 'MiddleCenter'
    $lblPct.Text = '--%'
    $lblSub = New-Label $form 'sub' 16 70 248 18 $capFont $muted 'MiddleCenter'
    $lblSub.Text = '本周已用'

    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Name = 'barBack'
    $barBack.Location = New-Object System.Drawing.Point 24, 98
    $barBack.Size = New-Object System.Drawing.Size 232, 10
    $barBack.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 50)
    $barBack.Parent = $form
    $barFill = New-Object System.Windows.Forms.Panel
    $barFill.Name = 'barFill'
    $barFill.Location = New-Object System.Drawing.Point 0, 0
    $barFill.Size = New-Object System.Drawing.Size 6, 10
    $barFill.BackColor = Get-UsageColor 0
    $barFill.Parent = $barBack

    $lblProducts = New-Label $form 'products' 16 118 248 22 $chipFont $fg 'MiddleCenter'
    $lblProducts.Text = ''
    $lblReset = New-Label $form 'reset' 16 150 248 20 $footFont $muted 'MiddleCenter'
    $lblReset.Text = ''
    $lblStamp = New-Label $form 'stamp' 16 172 248 18 $footFont $dim 'MiddleCenter'
    $lblStamp.Text = ''

    $script:Ui = @{
        Form = $form
        Pct = $lblPct
        Sub = $lblSub
        Products = $lblProducts
        Reset = $lblReset
        Stamp = $lblStamp
        BarFill = $barFill
        BarBack = $barBack
        Tray = $null
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRefresh = $menu.Items.Add('立即刷新')
    $miOpen = $menu.Items.Add('打开用量页')
    $miTop = $menu.Items.Add('浮在窗口上')
    $miTop.Checked = $false
    [void]$menu.Items.Add('-')
    $startupOn = Test-Path -LiteralPath (Get-StartupShortcutPath)
    $miStart = $menu.Items.Add($(if ($startupOn) { '取消开机启动' } else { '开机启动' }))
    [void]$menu.Items.Add('-')
    $miQuit = $menu.Items.Add('退出')
    $form.ContextMenuStrip = $menu

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Text = '周用量'
    $tray.Visible = $true
    $tray.ContextMenuStrip = $menu
    $script:Ui.Tray = $tray
    try {
        $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
    } catch {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }

    foreach ($c in @($form, $lblPct, $lblSub, $lblProducts, $lblReset, $lblStamp, $barBack, $barFill)) {
        $c.ContextMenuStrip = $menu
        Bind-Drag $c
    }

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { Update-Widget }
    })

    $miRefresh.Add_Click({ Update-Widget })
    $miOpen.Add_Click({ Start-Process 'https://grok.com/?_s=usage' })
    $miTop.Add_Click({
        if ($form.TopMost) {
            $form.TopMost = $false
            Enable-DesktopPin $form
            $miTop.Checked = $false
        } else {
            Disable-DesktopPin $form
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
            New-Shortcut -Path $path -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动周用量卡片'
            $miStart.Text = '取消开机启动'
        }
    })
    $miQuit.Add_Click({ $form.Close() })
    $tray.Add_DoubleClick({
        $form.Visible = -not $form.Visible
        if ($form.Visible) { $form.Activate() }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(15000, $IntervalSeconds * 1000)
    $timer.Add_Tick({ Update-Widget })
    $form.Tag = $timer

    $form.Add_Deactivate({ Send-BehindWindows $form })
    $form.Add_Shown({
        Write-WidgetLog 'form shown'
        try { Enable-DesktopPin $form } catch { Write-WidgetLog ("pin $($_.Exception.Message)") }
        Update-Widget
        $timer.Start()
        Write-WidgetLog 'timer started'
    })
    $form.Add_FormClosed({
        Write-WidgetLog 'form closed'
        try { $timer.Stop(); $timer.Dispose() } catch { }
        try { $tray.Visible = $false; $tray.Dispose() } catch { }
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
    if (-not $ui) { return }
    try {
        $script:Usage = Get-GrokUsageSnapshot
        $script:LastError = $null
        $script:LastOkAt = Get-Date
        $pct = [double]$script:Usage.Percent
        $color = Get-UsageColor $pct
        $big = '{0:0}%' -f $pct
        if (($pct * 10) % 10 -ne 0) { $big = '{0:0.0}%' -f $pct }
        $ui.Pct.Text = $big
        $ui.Pct.ForeColor = $color
        $ui.Sub.Text = '本周已用'
        $ui.BarFill.BackColor = $color
        $ui.BarFill.Width = [Math]::Max(6, [int](232 * $pct / 100.0))
        $parts = @()
        foreach ($p in @($script:Usage.Products)) {
            $parts += ('{0} {1:0}%' -f $p.Name, $p.Percent)
        }
        $ui.Products.Text = $(if ($parts.Count) { $parts -join '   ·   ' } else { '' })
        $ui.Reset.Text = Format-ResetText $script:Usage.PeriodEnd
        $stamp = $script:Usage.FetchedAt.ToString('HH:mm')
        if ($script:Usage.PrepaidCents -gt 0) {
            $stamp = ('额外 ${0:0.00}  ·  {1}' -f ($script:Usage.PrepaidCents / 100.0), $stamp)
        }
        $ui.Stamp.Text = $stamp
        $tip = '周用量 {0}%' -f $pct
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $ui.Tray.Text = $tip
        Write-WidgetLog ("usage {0}% ui-ok" -f $pct)
    } catch {
        $script:LastError = $_.Exception.Message
        Write-WidgetLog ("error {0}" -f $script:LastError)
        if ($ui.Sub) { $ui.Sub.Text = '读取失败' }
        if ($ui.Stamp) { $ui.Stamp.Text = $script:LastError }
        if ($ui.Tray -and -not $script:Usage) { $ui.Tray.Text = '用量读取失败' }
    }
}

if ($Install) { Install-Widget; return }
if ($Uninstall) { Uninstall-Widget; return }

try {
    Write-WidgetLog 'starting widget'
    Ensure-SingleInstance
    if (-not (Test-Path -LiteralPath $script:VbsPath)) { try { Write-LauncherVbs } catch { } }
    New-WidgetForm
} catch {
    Write-WidgetLog ("fatal $($_.Exception.Message)")
    throw
}
