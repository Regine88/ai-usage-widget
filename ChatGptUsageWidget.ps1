# ChatGPT (Codex) weekly usage desktop widget. Supports multiple accounts.
# Polls https://chatgpt.com/backend-api/wham/usage with local codex login tokens.
#
# Accounts are discovered from:
#   1. the currently active login: ~/.codex/auth.json
#   2. snapshots in this folder:   chatgpt-auth-<accountId>.json
# Run with -AddAccount (or use the right-click menu) while logged into an
# account to snapshot it, so the widget keeps tracking it after you switch
# to another account in codex.

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

$script:HomeDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:AuthPath = Join-Path $script:HomeDir 'auth.json'
$script:OAuthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann'
$script:TokenUrl = 'https://auth.openai.com/oauth/token'
$script:UsageUrl = 'https://chatgpt.com/backend-api/wham/usage'
$script:UsagePageUrl = 'https://chatgpt.com/codex/settings/usage'
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:WidgetDir = Split-Path -Parent $script:SelfPath
$script:StatePath = Join-Path $script:WidgetDir 'chatgpt-state.json'
$script:LogPath = Join-Path $script:WidgetDir 'chatgpt-widget.log'
$script:VbsPath = Join-Path $script:WidgetDir 'Start-ChatGptUsageWidget.vbs'

$script:Mutex = $null
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
    return $Auth.AccountId.Substring(0, 8)
}

function Get-SnapshotPath {
    param([string]$AccountId)
    Join-Path $script:WidgetDir ("chatgpt-auth-{0}.json" -f $AccountId)
}

function Get-CodexAccounts {
    # Active login first, then snapshots; dedupe by account id, active wins.
    $byId = [ordered]@{}
    $active = Read-CodexAuth $script:AuthPath
    if ($active) { $byId[$active.AccountId] = $active }
    foreach ($f in Get-ChildItem -LiteralPath $script:WidgetDir -Filter 'chatgpt-auth-*.json' -ErrorAction SilentlyContinue) {
        $snap = Read-CodexAuth $f.FullName
        if ($snap -and -not $byId.Contains($snap.AccountId)) { $byId[$snap.AccountId] = $snap }
    }
    return @($byId.Values)
}

function Add-CurrentAccount {
    $active = Read-CodexAuth $script:AuthPath
    if (-not $active) {
        Write-Host '未找到 ~/.codex/auth.json，请先运行 codex login'
        return
    }
    $snapPath = Get-SnapshotPath $active.AccountId
    Copy-Item -LiteralPath $script:AuthPath -Destination $snapPath -Force
    Write-Host ("已登记账号 {0} -> {1}" -f (Get-AccountLabel $active), $snapPath)
    Write-WidgetLog ("snapshot account {0}" -f (Get-AccountLabel $active))
}

function Save-CodexAuth {
    param([string]$Path, [string]$AccessToken, [string]$RefreshToken, [string]$IdToken)
    # Re-read the file so fields codex may have updated in the meantime are kept.
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $raw.tokens.access_token = $AccessToken
    $raw.tokens.refresh_token = $RefreshToken
    if ($IdToken) { $raw.tokens.id_token = $IdToken }
    $raw.last_refresh = (Get-Date).ToUniversalTime().ToString('o')
    $json = $raw | ConvertTo-Json -Depth 8
    $tmp = "$Path.tmp-widget"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Update-CodexToken {
    param($Auth)
    $body = @{
        client_id     = $script:OAuthClientId
        grant_type    = 'refresh_token'
        refresh_token = $Auth.Refresh
    }
    $resp = Invoke-RestMethod -Method Post -Uri $script:TokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15
    if (-not $resp.access_token) { throw '刷新令牌失败，请重新登录该账号' }
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $Auth.Refresh }
    $newId = if ($resp.id_token) { [string]$resp.id_token } else { $null }
    Save-CodexAuth -Path $Auth.Path -AccessToken $resp.access_token -RefreshToken $newRefresh -IdToken $newId
    $Auth.Token = [string]$resp.access_token
    $Auth.Refresh = $newRefresh
    Write-WidgetLog ("token refreshed for {0}" -f (Get-AccountLabel $Auth))
    return $Auth
}

function Invoke-CodexGet {
    param($Auth, [string]$Url)
    $headers = @{
        Authorization         = "Bearer $($Auth.Token)"
        'ChatGPT-Account-Id'  = $Auth.AccountId
        Accept                = 'application/json'
        'User-Agent'          = 'codex-cli'
    }
    try {
        return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -TimeoutSec 15
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -in 401, 403) {
            $Auth = Update-CodexToken -Auth $Auth
            $headers.Authorization = "Bearer $($Auth.Token)"
            return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers -TimeoutSec 15
        }
        throw
    }
}

function Get-WindowInfo {
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
    $data = Invoke-CodexGet -Auth $Auth -Url $script:UsageUrl
    if (-not $data.rate_limit) { throw '用量接口没有返回 rate_limit' }

    $primary = Get-WindowInfo $data.rate_limit.primary_window
    $secondary = Get-WindowInfo $data.rate_limit.secondary_window

    # The longer window is the weekly quota; the shorter one is the burst window.
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

    $plan = ''
    if ($data.plan_type) { $plan = [string]$data.plan_type }

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
        Plan      = $plan
        Credits   = $creditBalance
        FetchedAt = [datetime]::Now
    }
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

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'ChatGPT 周用量.lnk'
}

function Write-LauncherVbs {
    $content = @'
Option Explicit

Dim fso, sh, dirName, ps1Path, exePath
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dirName = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = dirName & "\ChatGptUsageWidget.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "Widget script not found:" & vbCrLf & ps1Path, vbExclamation, "ChatGPT Usage Widget"
    WScript.Quit 1
End If

exePath = FindPowerShell()
If exePath = "" Then
    MsgBox "Neither pwsh.exe nor powershell.exe was found.", vbCritical, "ChatGPT Usage Widget"
    WScript.Quit 1
End If

sh.Run """" & exePath & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1Path & """", 0, False

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
    New-Shortcut -Path (Get-StartupShortcutPath) -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 ChatGPT 周用量卡片'
    Write-Host "已写入开机启动。程序目录: $($script:WidgetDir)"
}

function Uninstall-Widget {
    $p = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    Write-Host "已移除开机启动。程序仍在 $($script:WidgetDir)"
}

function Ensure-SingleInstance {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ChatGptUsageDesktopWidget')
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
    $Control.Add_MouseDoubleClick({ Start-Process $script:UsagePageUrl })
}

function Get-FormHeight {
    param([int]$AccountCount)
    # 14 top padding + per-account block (64 + 10 gap) + 26 footer
    return 14 + $AccountCount * 74 - 10 + 26
}

function Rebuild-AccountRows {
    param($Form, $Accounts)
    # Drop old row controls.
    if ($script:Ui.RowControls) {
        foreach ($c in $script:Ui.RowControls) {
            try { $Form.Controls.Remove($c); $c.Dispose() } catch { }
        }
    }
    $script:Ui.RowControls = @()
    $script:Ui.Rows = @()

    $fg = [System.Drawing.Color]::FromArgb(244, 244, 247)
    $muted = [System.Drawing.Color]::FromArgb(152, 152, 160)
    $nameFont = New-Object System.Drawing.Font('Segoe UI', 9)
    $pctFont = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $detailFont = New-Object System.Drawing.Font('Segoe UI', 8.5)

    $y = 14
    foreach ($acct in $Accounts) {
        $label = Get-AccountLabel $acct
        $lblName = New-Label $Form "name-$y" 16 ($y + 4) 180 18 $nameFont $fg 'MiddleLeft'
        $lblName.Text = $label
        $lblPct = New-Label $Form "pct-$y" 196 $y 68 26 $pctFont (Get-UsageColor 0) 'MiddleRight'
        $lblPct.Text = '--%'

        $barBack = New-Object System.Windows.Forms.Panel
        $barBack.Location = New-Object System.Drawing.Point 16, ($y + 30)
        $barBack.Size = New-Object System.Drawing.Size 248, 8
        $barBack.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 50)
        $barBack.Parent = $Form
        $barFill = New-Object System.Windows.Forms.Panel
        $barFill.Location = New-Object System.Drawing.Point 0, 0
        $barFill.Size = New-Object System.Drawing.Size 6, 8
        $barFill.BackColor = Get-UsageColor 0
        $barFill.Parent = $barBack

        $lblDetail = New-Label $Form "detail-$y" 16 ($y + 44) 248 16 $detailFont $muted 'MiddleLeft'
        $lblDetail.Text = ''

        foreach ($c in @($lblName, $lblPct, $barBack, $barFill, $lblDetail)) {
            $c.ContextMenuStrip = $script:Ui.Menu
            Bind-Drag $c
        }
        $script:Ui.RowControls += @($lblName, $lblPct, $barBack, $lblDetail)
        $script:Ui.Rows += @{
            AccountId = $acct.AccountId
            AuthPath  = $acct.Path
            Pct       = $lblPct
            BarFill   = $barFill
            Detail    = $lblDetail
        }
        $y += 74
    }

    $h = Get-FormHeight $Accounts.Count
    $Form.Size = New-Object System.Drawing.Size(280, $h)
    $round = New-RoundRectPath 0 0 $Form.Width $Form.Height 18
    $old = $Form.Region
    $Form.Region = New-Object System.Drawing.Region($round)
    if ($old) { $old.Dispose() }
    $script:Ui.Stamp.Top = $h - 24
    $script:Ui.Sig = (($Accounts | ForEach-Object { $_.AccountId }) -join ',')
}

function New-WidgetForm {
    Read-State
    Hide-ConsoleWindow

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ChatGPT 周用量'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Size = New-Object System.Drawing.Size(280, (Get-FormHeight 1))
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
    $miAdd = $menu.Items.Add('登记当前账号')
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
    $tray.Text = 'ChatGPT 周用量'
    $tray.Visible = $true
    $tray.ContextMenuStrip = $menu
    try {
        $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
    } catch {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }

    $script:Ui = @{
        Form = $form
        Stamp = $lblStamp
        Menu = $menu
        Tray = $tray
        Rows = @()
        RowControls = @()
        Sig = ''
    }

    $form.ContextMenuStrip = $menu
    $lblStamp.ContextMenuStrip = $menu
    Bind-Drag $form
    Bind-Drag $lblStamp

    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') { Update-Widget }
    })

    $miRefresh.Add_Click({ Update-Widget })
    $miAdd.Add_Click({
        Add-CurrentAccount
        Update-Widget
    })
    $miOpen.Add_Click({ Start-Process $script:UsagePageUrl })
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
            New-Shortcut -Path $path -Target $script:VbsPath -WorkDir $script:WidgetDir -Desc '开机启动 ChatGPT 周用量卡片'
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
    $accounts = Get-CodexAccounts
    if ($accounts.Count -eq 0) {
        $ui.Stamp.Text = '未找到登录凭证，请运行 codex login'
        if ($ui.Tray) { $ui.Tray.Text = 'ChatGPT 用量读取失败' }
        return
    }
    # Keep the active account's snapshot in sync: codex rotates the refresh
    # token in auth.json, and a stale snapshot would break after switching away.
    foreach ($acct in $accounts) {
        if ($acct.Path -eq $script:AuthPath) {
            $snap = Get-SnapshotPath $acct.AccountId
            if (Test-Path -LiteralPath $snap) {
                try { Copy-Item -LiteralPath $script:AuthPath -Destination $snap -Force } catch { }
            }
        }
    }
    $sig = (($accounts | ForEach-Object { $_.AccountId }) -join ',')
    if ($sig -ne $ui.Sig) {
        Rebuild-AccountRows $ui.Form $accounts
        Write-WidgetLog ("rows rebuilt: {0} account(s)" -f $accounts.Count)
    }

    $tipParts = @()
    $errors = 0
    foreach ($row in $ui.Rows) {
        $auth = $accounts | Where-Object { $_.AccountId -eq $row.AccountId } | Select-Object -First 1
        if (-not $auth) { continue }
        try {
            $u = Get-CodexUsageSnapshot -Auth $auth
            $script:LastOkAt = Get-Date
            $pct = [double]$u.Percent
            $color = Get-UsageColor $pct
            $big = '{0:0}%' -f $pct
            if (($pct * 10) % 10 -ne 0) { $big = '{0:0.0}%' -f $pct }
            $row.Pct.Text = $big
            $row.Pct.ForeColor = $color
            $row.BarFill.BackColor = $color
            $row.BarFill.Width = [Math]::Max(6, [int](248 * $pct / 100.0))
            $details = @()
            if ($u.Burst -and $u.Burst.Label) { $details += ('{0} {1:0}%' -f $u.Burst.Label, $u.Burst.Percent) }
            $details += Format-ResetText $u.PeriodEnd
            if ($null -ne $u.Credits) { $details += ('余额 ${0:0.00}' -f $u.Credits) }
            $row.Detail.Text = $details -join ' · '
            $row.Detail.ForeColor = [System.Drawing.Color]::FromArgb(152, 152, 160)
            $tipParts += ('{0} {1}' -f (Get-AccountLabel $auth), $big)
            Write-WidgetLog ("usage {0} {1} ui-ok" -f (Get-AccountLabel $auth), $big)
        } catch {
            $errors++
            $msg = $_.Exception.Message
            Write-WidgetLog ("error {0}: {1}" -f (Get-AccountLabel $auth), $msg)
            $row.Detail.Text = $msg
            $row.Detail.ForeColor = [System.Drawing.Color]::FromArgb(255, 107, 107)
        }
    }
    $ui.Stamp.Text = ('更新于 {0}' -f [datetime]::Now.ToString('HH:mm'))
    if ($tipParts.Count -gt 0) {
        $tip = $tipParts -join '  '
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $ui.Tray.Text = $tip
    } elseif ($errors -gt 0) {
        $ui.Tray.Text = 'ChatGPT 用量读取失败'
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
