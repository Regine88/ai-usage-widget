# Kimi Code weekly usage desktop widget.
# Polls https://api.kimi.com/coding/v1/usages with the local kimi-code login token.

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

$script:HomeDir = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
$script:CredPath = Join-Path $script:HomeDir 'credentials\kimi-code.json'
$script:RegionPath = Join-Path $script:HomeDir 'region'
$script:OAuthClientId = '17e5f671-d194-4dfb-9706-5516cb48c098'
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:WidgetDir = Split-Path -Parent $script:SelfPath
$script:StatePath = Join-Path $script:WidgetDir 'kimi-state.json'
$script:LogPath = Join-Path $script:WidgetDir 'kimi-widget.log'
$script:VbsPath = Join-Path $script:WidgetDir 'Start-KimiUsageWidget.vbs'

$script:Mutex = $null
$script:Usage = $null
$script:LastError = $null
$script:LastOkAt = $null
$script:Drag = $false
$script:DragOffset = [System.Drawing.Point]::Empty
$script:State = @{ x = $null; y = $null; topMost = $false }

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
        } | ConvertTo-Json -Compress
        $tmp = "$script:StatePath.tmp"
        Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    } catch { }
}

function Get-KimiHosts {
    $oauth = 'https://auth.kimi.com'
    $base = 'https://api.kimi.com/coding/v1'
    $region = ''
    if (Test-Path -LiteralPath $script:RegionPath) {
        try { $region = (Get-Content -LiteralPath $script:RegionPath -Raw -Encoding utf8).Trim() } catch { }
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
    if (-not (Test-Path -LiteralPath $script:CredPath)) {
        throw '未找到 ~/.kimi-code/credentials/kimi-code.json，请先运行 kimi 登录'
    }
    $raw = Get-Content -LiteralPath $script:CredPath -Raw -Encoding utf8 | ConvertFrom-Json
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
    # Re-read the file so fields the CLI may have updated in the meantime are kept.
    $raw = Get-Content -LiteralPath $script:CredPath -Raw -Encoding utf8 | ConvertFrom-Json
    $raw.access_token = $AccessToken
    $raw.refresh_token = $RefreshToken
    $raw.expires_at = [long][DateTimeOffset]::new($ExpiresAt.ToUniversalTime()).ToUnixTimeSeconds()
    $json = $raw | ConvertTo-Json -Depth 8 -Compress
    $tmp = "$script:CredPath.tmp-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:CredPath -Force
}

function Update-KimiToken {
    param($Auth)
    $hosts = Get-KimiHosts
    $body = @{
        client_id     = $script:OAuthClientId
        grant_type    = 'refresh_token'
        refresh_token = $Auth.Refresh
    }
    $resp = Invoke-RestMethod -Method Post -Uri "$($hosts.OAuthHost)/api/oauth/token" -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15
    if (-not $resp.access_token) { throw '刷新令牌失败，请重新运行 kimi 登录' }
    $expires = [datetime]::UtcNow.AddSeconds([int]($resp.expires_in))
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.Refresh }
    Save-KimiAuth -AccessToken $resp.access_token -RefreshToken $newRefresh -ExpiresAt $expires
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    $Auth.ExpiresAt = $expires
    Write-WidgetLog 'token refreshed'
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
        return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -TimeoutSec 15
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -in 401, 403) {
            $Auth = Update-KimiToken -Auth $Auth
            $headers.Authorization = "Bearer $($Auth.Token)"
            return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -TimeoutSec 15
        }
        throw
    }
}

function Get-WindowLabel {
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
        try { $auth = Update-KimiToken -Auth $auth } catch { Write-WidgetLog "preemptive refresh failed: $($_.Exception.Message)" }
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
            Label   = Get-WindowLabel $row.window
            Percent = $wPct
            ResetAt = Convert-ApiTime $d.resetTime
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
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Kimi 周用量.lnk'
}

function Write-LauncherVbs {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    $ps1 = $script:SelfPath
    $content = @"
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Wscript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\KimiUsageWidget.ps1"
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
    Write-LauncherVbs
    New-Shortcut -Path (Get-StartupShortcutPath) -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 Kimi 周用量卡片'
    Write-Host "已写入开机启动。程序目录: $($script:WidgetDir)"
}

function Uninstall-Widget {
    $p = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    Write-Host "已移除开机启动。程序仍在 $($script:WidgetDir)"
}

function Ensure-SingleInstance {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\KimiUsageDesktopWidget')
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
    $Control.Add_MouseDoubleClick({ Start-Process 'https://www.kimi.com/code/console' })
}

function New-WidgetForm {
    Read-State
    Hide-ConsoleWindow

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Kimi 周用量'
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

    $lblWindows = New-Label $form 'windows' 16 118 248 22 $chipFont $fg 'MiddleCenter'
    $lblWindows.Text = ''
    $lblReset = New-Label $form 'reset' 16 150 248 20 $footFont $muted 'MiddleCenter'
    $lblReset.Text = ''
    $lblStamp = New-Label $form 'stamp' 16 172 248 18 $footFont $dim 'MiddleCenter'
    $lblStamp.Text = ''

    $script:Ui = @{
        Form = $form
        Pct = $lblPct
        Sub = $lblSub
        Windows = $lblWindows
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
    $tray.Text = 'Kimi 周用量'
    $tray.Visible = $true
    $tray.ContextMenuStrip = $menu
    $script:Ui.Tray = $tray
    try {
        $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
    } catch {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }

    foreach ($c in @($form, $lblPct, $lblSub, $lblWindows, $lblReset, $lblStamp, $barBack, $barFill)) {
        $c.ContextMenuStrip = $menu
        Bind-Drag $c
    }

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { Update-Widget }
    })

    $miRefresh.Add_Click({ Update-Widget })
    $miOpen.Add_Click({ Start-Process 'https://www.kimi.com/code/console' })
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
            New-Shortcut -Path $path -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 Kimi 周用量卡片'
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
        Send-BehindWindows $form
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
        $script:Usage = Get-KimiUsageSnapshot
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
        foreach ($w in @($script:Usage.Windows)) {
            if ($w.Label) { $parts += ('{0} {1:0}%' -f $w.Label, $w.Percent) }
        }
        $ui.Windows.Text = $(if ($parts.Count) { $parts -join '   ·   ' } else { '' })
        $ui.Reset.Text = Format-ResetText $script:Usage.PeriodEnd
        $stamp = $script:Usage.FetchedAt.ToString('HH:mm')
        if ($script:Usage.ExtraCents -gt 0) {
            $symbol = if ($script:Usage.Currency -eq 'CNY') { '¥' } else { '$' }
            $stamp = ('本月额外 {0}{1:0.00}  ·  {2}' -f $symbol, ($script:Usage.ExtraCents / 100.0), $stamp)
        }
        $ui.Stamp.Text = $stamp
        $tip = 'Kimi 周用量 {0}%' -f $pct
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $ui.Tray.Text = $tip
        Write-WidgetLog ("usage {0}% ui-ok" -f $pct)
    } catch {
        $script:LastError = $_.Exception.Message
        Write-WidgetLog ("error {0}" -f $script:LastError)
        if ($ui.Sub) { $ui.Sub.Text = '读取失败' }
        if ($ui.Stamp) { $ui.Stamp.Text = $script:LastError }
        if ($ui.Tray -and -not $script:Usage) { $ui.Tray.Text = 'Kimi 用量读取失败' }
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
