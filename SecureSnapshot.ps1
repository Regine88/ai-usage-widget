# Current-user DPAPI protected account snapshots.
# Snapshot files contain no plaintext credentials and never use the project directory by default.

function Get-SecureSnapshotRoot {
    param([string]$Root)
    if ($Root) { return $Root }
    if ($script:SecureSnapshotRoot) { return $script:SecureSnapshotRoot }
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { throw '未找到 LOCALAPPDATA，无法建立受保护凭据目录' }
    return (Join-Path $localAppData 'AIUsageWidget\accounts')
}

function Get-SecureSnapshotPath {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccountId,
        [string]$Root
    )
    $rootPath = Get-SecureSnapshotRoot $Root
    if (-not (Test-Path -LiteralPath $rootPath)) {
        New-Item -ItemType Directory -Path $rootPath -Force -ErrorAction Stop | Out-Null
    }
    $input = '{0}:{1}' -f $Provider.Trim().ToLowerInvariant(), $AccountId.Trim()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($input)
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $safeProvider = $Provider.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]', '_'
    return (Join-Path $rootPath ('{0}-{1}.snapshot' -f $safeProvider, $hash))
}

function ConvertTo-SnapshotCipherText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Current-user DPAPI wrap of the snapshot JSON; this is not a password.')]
    param([Parameter(Mandatory)][string]$Json)
    $secure = ConvertTo-SecureString -String $Json -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}

function ConvertFrom-SnapshotCipherText {
    param([Parameter(Mandatory)][string]$CipherText)
    $secure = ConvertTo-SecureString -String $CipherText
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}

function Set-SecureSnapshotAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $inherit = [Security.AccessControl.InheritanceFlags]::None
    $propagate = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($name in @($identity, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($name, 'FullControl', $inherit, $propagate, $allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Invoke-SecureSnapshotFileLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $nameBytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $name = ([BitConverter]::ToString($hash.ComputeHash($nameBytes))).Replace('-', '')
    } finally {
        $hash.Dispose()
    }
    $mutex = New-Object Threading.Mutex($false, ('Local\AiUsageWidgetSnapshot-{0}' -f $name))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '受保护凭据正在被其他进程写入' }
        return (& $Action)
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() | Out-Null } catch { } }
        $mutex.Dispose()
    }
}

function Move-SecureSnapshotFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        $backup = '{0}.{1}.bak' -f $Destination, ([guid]::NewGuid().ToString('n'))
        try {
            [IO.File]::Replace($Source, $Destination, $backup)
        } finally {
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        }
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Write-SecureSnapshotLocked {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $cipher = ConvertTo-SnapshotCipherText $json
    $tmp = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('n'))
    try {
        [IO.File]::WriteAllText($tmp, $cipher, (New-Object Text.UTF8Encoding($false)))
        Set-SecureSnapshotAcl -Path $tmp
        if (Test-Path -LiteralPath $Path) {
            Move-SecureSnapshotFile -Source $tmp -Destination $Path
        } else {
            [IO.File]::Move($tmp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-SecureSnapshot {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccountId,
        [Parameter(Mandatory)]$Value,
        [string]$Root
    )
    $path = Get-SecureSnapshotPath -Provider $Provider -AccountId $AccountId -Root $Root
    Invoke-SecureSnapshotFileLock -Path $path -Action {
        Write-SecureSnapshotLocked -Path $path -Value $Value
    }
    return $path
}

function Update-SecureSnapshot {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccountId,
        [Parameter(Mandatory)][scriptblock]$Update,
        [string]$Root
    )
    $path = Get-SecureSnapshotPath -Provider $Provider -AccountId $AccountId -Root $Root
    return (Invoke-SecureSnapshotFileLock -Path $path -Action {
        if (-not (Test-Path -LiteralPath $path)) { throw '受保护凭据文件不存在' }
        $current = Read-SecureSnapshot -Path $path
        $updated = & $Update $current
        if ($null -eq $updated) { throw '受保护凭据更新没有返回新值' }
        Write-SecureSnapshotLocked -Path $path -Value $updated
        return $updated
    })
}

function Read-SecureSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cipher = [IO.File]::ReadAllText($Path)
    if (-not $cipher) { throw '受保护凭据文件为空' }
    $json = ConvertFrom-SnapshotCipherText $cipher
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Get-SecureSnapshotFiles {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [string]$Root
    )
    $rootPath = Get-SecureSnapshotRoot $Root
    if (-not (Test-Path -LiteralPath $rootPath)) { return @() }
    $safeProvider = $Provider.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]', '_'
    return @(Get-ChildItem -LiteralPath $rootPath -Filter ($safeProvider + '-*.snapshot') -File -ErrorAction SilentlyContinue)
}

function Remove-SecureSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}
