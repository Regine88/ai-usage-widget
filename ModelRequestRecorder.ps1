# Model request event recorder.
#
# Events intentionally contain metadata only. Prompts, completions, headers,
# tokens and request bodies must never be written to this file.

function Convert-RequestEventValue {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [int]$MaxLength = 160
    )
    if ($null -eq $Value) { return $null }
    $clean = $Value -replace '[\r\n\t]+', ' '
    $clean = $clean.Trim()
    if (-not $clean) { return $null }
    if ($clean.Length -gt $MaxLength) { return $clean.Substring(0, $MaxLength) }
    return $clean
}

function Normalize-RequestProvider {
    param([Parameter(Mandatory)][string]$Provider)
    $value = (Convert-RequestEventValue $Provider 40).ToLowerInvariant()
    switch ($value) {
        { $_ -in @('xai', 'grok-cli') } { return 'grok' }
        { $_ -in @('openai', 'chatgpt', 'codex') } { return 'codex' }
        { $_ -in @('google', 'gemini', 'antigravity') } { return 'gemini' }
        { $_ -in @('moonshot', 'kimi-code') } { return 'kimi' }
        default { return $value }
    }
}

function Get-ModelRequestEventPath {
    param([string]$Path)
    if ($Path) { return $Path }
    if ($script:RequestEventsPath) { return $script:RequestEventsPath }
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return (Join-Path $base 'ai-request-events.jsonl')
}

function Invoke-RequestEventFileLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AiUsageModelRequestRecorder')
    $locked = $false
    try {
        try {
            $locked = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $locked = $true
        }
        if (-not $locked) { throw '请求事件记录器正在被其他进程占用' }
        return (& $Action)
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() | Out-Null } catch { } }
        $mutex.Dispose()
    }
}

function Trim-ModelRequestEventFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$MaxBytes = 2MB,
        [int]$KeepLines = 5000
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -le $MaxBytes) { return }
    $tail = @(Get-Content -LiteralPath $Path -Tail $KeepLines -ErrorAction Stop)
    Set-Content -LiteralPath $Path -Value $tail -Encoding utf8 -ErrorAction Stop
}

function Write-ModelRequestEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Model,
        [string]$AccountId,
        [string]$RequestId,
        [ValidateSet('started', 'completed', 'failed')][string]$Status = 'completed',
        [string]$Operation = 'chat',
        [string]$Source = 'api',
        [datetime]$StartedAt = [datetime]::MinValue,
        [datetime]$CompletedAt = [datetime]::MinValue,
        [Nullable[double]]$DurationMs,
        [string]$Error,
        [string]$Path,
        [switch]$Strict
    )

    $eventPath = Get-ModelRequestEventPath $Path
    $providerValue = Normalize-RequestProvider $Provider
    $modelValue = Convert-RequestEventValue $Model 120
    if (-not $modelValue) {
        if ($Strict) { throw '模型名称不能为空' }
        return $null
    }

    $started = if ($StartedAt -ne [datetime]::MinValue) { $StartedAt.ToUniversalTime() } else { [datetime]::UtcNow }
    $completed = if ($CompletedAt -ne [datetime]::MinValue) { $CompletedAt.ToUniversalTime() } else { [datetime]::UtcNow }
    $duration = $DurationMs
    if ($null -eq $duration -and $completed -ge $started) {
        $duration = [Math]::Round(($completed - $started).TotalMilliseconds, 1)
    }
    if ($null -ne $duration) {
        $duration = [Math]::Max([double]0, [double][Math]::Round([double]$duration, 1))
    }

    $record = [ordered]@{
        ts         = $completed.ToString('o')
        provider   = $providerValue
        model      = $modelValue
        accountId  = Convert-RequestEventValue $AccountId 160
        requestId  = if ($RequestId) { Convert-RequestEventValue $RequestId 120 } else { [guid]::NewGuid().ToString('n') }
        operation  = Convert-RequestEventValue $Operation 40
        status     = $Status
        durationMs = $duration
        source     = Convert-RequestEventValue $Source 80
        error      = Convert-RequestEventValue $Error 240
    }

    try {
        $parent = Split-Path -Parent $eventPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $line = ([pscustomobject]$record | ConvertTo-Json -Compress -Depth 4)
        Invoke-RequestEventFileLock -Path $eventPath -Action {
            Add-Content -LiteralPath $eventPath -Value $line -Encoding utf8 -ErrorAction Stop
            Trim-ModelRequestEventFile -Path $eventPath
        }
        return [pscustomobject]$record
    } catch {
        if ($Strict) { throw }
        return $null
    }
}

function Invoke-RecordedModelRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$AccountId,
        [string]$Operation = 'chat',
        [string]$Source = 'wrapper',
        [string]$Path
    )

    $requestId = [guid]::NewGuid().ToString('n')
    $started = [datetime]::UtcNow
    try {
        $result = & $Action
        $completed = [datetime]::UtcNow
        Write-ModelRequestEvent -Provider $Provider -Model $Model -AccountId $AccountId `
            -RequestId $requestId -Status completed -Operation $Operation -Source $Source `
            -StartedAt $started -CompletedAt $completed -Path $Path
        return $result
    } catch {
        $completed = [datetime]::UtcNow
        Write-ModelRequestEvent -Provider $Provider -Model $Model -AccountId $AccountId `
            -RequestId $requestId -Status failed -Operation $Operation -Source $Source `
            -StartedAt $started -CompletedAt $completed -Error $_.Exception.Message -Path $Path
        throw
    }
}

function Get-ModelRequestEvents {
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Limit = 5000,
        [datetime]$Since = [datetime]::MinValue
    )
    $eventPath = Get-ModelRequestEventPath $Path
    if (-not (Test-Path -LiteralPath $eventPath)) { return @() }
    $lines = if ($Limit -gt 0) {
        @(Get-Content -LiteralPath $eventPath -Tail $Limit -ErrorAction SilentlyContinue)
    } else {
        @(Get-Content -LiteralPath $eventPath -ErrorAction SilentlyContinue)
    }
    $events = @()
    foreach ($line in $lines) {
        if (-not $line) { continue }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if ($Since -ne [datetime]::MinValue) {
                $when = [datetime]::Parse([string]$event.ts).ToUniversalTime()
                if ($when -lt $Since.ToUniversalTime()) { continue }
            }
            $events += $event
        } catch { }
    }
    return $events
}

function Get-LatestModelRequest {
    [CmdletBinding()]
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Provider,
        [string]$AccountId,
        [object[]]$Events
    )
    if ($null -eq $Events) { $Events = @(Get-ModelRequestEvents -Path $Path) }
    $normalizedProvider = Normalize-RequestProvider $Provider
    $normalizedAccount = Convert-RequestEventValue $AccountId 160
    $matches = @($Events | Where-Object {
        if (-not $_.provider -or (Normalize-RequestProvider ([string]$_.provider)) -ne $normalizedProvider) { return $false }
        if ($normalizedAccount) { return ([string]$_.accountId -eq $normalizedAccount) }
        return $true
    })
    if ($matches.Count -eq 0) { return $null }
    return ($matches | Select-Object -Last 1)
}

function Get-ModelRequestSummary {
    [CmdletBinding()]
    param([string]$Path, [int]$Limit = 5000)
    $events = @(Get-ModelRequestEvents -Path $Path -Limit $Limit)
    $groups = $events | Group-Object -Property provider, model
    return @($groups | ForEach-Object {
        $groupEvents = @($_.Group)
        $completed = @($groupEvents | Where-Object { $_.status -eq 'completed' }).Count
        $failed = @($groupEvents | Where-Object { $_.status -eq 'failed' }).Count
        [pscustomobject]@{
            Provider  = [string]$groupEvents[0].provider
            Model     = [string]$groupEvents[0].model
            Requests  = $groupEvents.Count
            Completed = $completed
            Failed    = $failed
            LastSeen  = [string]$groupEvents[-1].ts
        }
    } | Sort-Object Provider, Model)
}
