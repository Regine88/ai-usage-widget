# Grok multi-account helpers for the usage widget.
# Accounts are identified by a short local fingerprint; source labels never contain email addresses.
# Optional short aliases come from $script:GrokAccountAliases or a local grok-aliases.json file.

if (-not (Get-Command Get-AccountFingerprint -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}
if (-not (Get-Command Get-SecureSnapshotPath -ErrorAction SilentlyContinue)) {
    $snapshotHelper = Join-Path $PSScriptRoot 'SecureSnapshot.ps1'
    if (Test-Path -LiteralPath $snapshotHelper) { . $snapshotHelper }
}

# Local-only account aliases: fingerprint -> short label. Keep the table empty in the
# repository; fill it at runtime, or drop a grok-aliases.json next to this script
# (for example { "Grok-1f4a2c7e": "a" }). Aliases derive from real account identifiers,
# so the alias file is git-ignored and never shipped.
$script:GrokAccountAliases = @{}
$script:GrokAliasFileName = 'grok-aliases.json'

function Get-GrokAliasPath {
    $dir = $script:WidgetDir
    if (-not $dir) { $dir = $PSScriptRoot }
    if (-not $dir) { return $null }
    $name = $script:GrokAliasFileName
    if (-not $name) { $name = 'grok-aliases.json' }
    return (Join-Path $dir $name)
}

function Get-GrokAliasMap {
    $map = @{}
    if ($script:GrokAccountAliases) {
        foreach ($key in @($script:GrokAccountAliases.Keys)) {
            $value = [string]$script:GrokAccountAliases[$key]
            if ($value) { $map[[string]$key] = $value }
        }
    }
    $path = Get-GrokAliasPath
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($property in $raw.PSObject.Properties) {
                $value = [string]$property.Value
                if ($value) { $map[[string]$property.Name] = $value }
            }
        } catch {
            if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
                Write-WidgetLog ('grok alias file ignored: {0}' -f (Convert-SafeLogText $_.Exception.Message))
            }
        }
    }
    return $map
}

function Get-GrokAccountFingerprint {
    param($Auth)
    return (Get-AccountFingerprint -AccountId ([string]$Auth.Email) -Prefix 'Grok')
}

function Get-GrokAccountAlias {
    param($Auth)
    if (-not $Auth.Email) { return $null }
    $map = Get-GrokAliasMap
    $fingerprint = Get-GrokAccountFingerprint $Auth
    if ($map.ContainsKey($fingerprint)) { return [string]$map[$fingerprint] }
    return $null
}

function Get-GrokAccountId {
    param($Auth)
    $email = [string]$Auth.Email
    if ($email) { return $email.Trim().ToLowerInvariant() }
    $key = [string]$Auth.KeyName
    if ($key) { return $key }
    return 'unknown'
}

function Get-GrokAccountLabel {
    param($Auth)
    if (-not $Auth.Email) { return 'Grok' }
    $alias = Get-GrokAccountAlias $Auth
    if ($alias) { return $alias }
    return (Get-GrokAccountFingerprint $Auth)
}

function Get-GrokRowName {
    param($Auth)
    if (-not $Auth.Email) { return 'Grok' }
    $alias = Get-GrokAccountAlias $Auth
    if ($alias) { return ('Grok {0}' -f $alias) }
    return (Get-GrokAccountFingerprint $Auth)
}

function Get-GrokRowId {
    param($Auth)
    $alias = Get-GrokAccountAlias $Auth
    if ($alias) { return ('grok-{0}' -f $alias) }
    return ('grok-{0}' -f (Get-AccountFingerprint -AccountId (Get-GrokAccountId $Auth) -Prefix 'acct'))
}

function Get-GrokSnapshotFileName {
    param([string]$AccountId)
    $safe = $AccountId -replace '[<>:"/\\|?*]', '_'
    return ('grok-auth-{0}.json' -f $safe)
}

function Get-GrokSnapshotPath {
    param([string]$AccountId)
    return (Get-SecureSnapshotPath -Provider grok -AccountId $AccountId)
}

function Get-GrokLegacySnapshotPath {
    param([string]$AccountId)
    if (-not $script:WidgetDir) { return $null }
    Join-Path $script:WidgetDir (Get-GrokSnapshotFileName $AccountId)
}

function Convert-GrokRawAuth {
    param(
        [Parameter(Mandatory)]$Raw,
        [string]$Path
    )
    $best = $null
    foreach ($p in $Raw.PSObject.Properties) {
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
    if (-not $best) { throw 'missing-credential' }
    $auth = [pscustomobject]@{
        Path         = $Path
        KeyName      = $best.keyName
        Token        = [string]$best.entry.key
        RefreshToken = [string]$best.entry.refresh_token
        ClientId     = [string]$best.entry.oidc_client_id
        Email        = [string]$best.entry.email
        ExpiresAt    = $best.expires
        Raw          = $Raw
        Entry        = $best.entry
        AccountId    = $null
    }
    $auth.AccountId = Get-GrokAccountId $auth
    return $auth
}

function Read-GrokAuthFromFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        throw 'missing-credential'
    }
    if ($Path -like '*.snapshot') {
        return (Convert-GrokRawAuth -Raw (Read-SecureSnapshot -Path $Path) -Path $Path)
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    return (Convert-GrokRawAuth -Raw $raw -Path $Path)
}

function Get-GrokAccounts {
    $byId = [ordered]@{}
    if ($script:WidgetDir -and (Test-Path -LiteralPath $script:WidgetDir)) {
        foreach ($f in @(Get-SecureSnapshotFiles -Provider grok)) {
            try {
                $snap = Read-GrokAuthFromFile -Path $f.FullName
                if ($snap -and $snap.AccountId -and -not $byId.Contains($snap.AccountId)) {
                    $byId[$snap.AccountId] = $snap
                }
            } catch { }
        }
        foreach ($f in Get-ChildItem -LiteralPath $script:WidgetDir -Filter 'grok-auth-*.json' -ErrorAction SilentlyContinue) {
            try {
                $snap = Read-GrokAuthFromFile -Path $f.FullName
                if ($snap -and $snap.AccountId) {
                    $securePath = Write-SecureSnapshot -Provider grok -AccountId $snap.AccountId -Value $snap.Raw
                    $snap.Path = $securePath
                    if (-not $byId.Contains($snap.AccountId)) { $byId[$snap.AccountId] = $snap }
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                }
            } catch { }
        }
    }
    if ($script:GrokAuthPath -and (Test-Path -LiteralPath $script:GrokAuthPath)) {
        try {
            $active = Read-GrokAuthFromFile -Path $script:GrokAuthPath
            if ($active -and $active.AccountId) {
                $byId[$active.AccountId] = $active
            }
        } catch { }
    }
    $list = @($byId.Values)
    return @($list | Sort-Object @{
        Expression = { if (Get-GrokAccountAlias $_) { 0 } else { 1 } }
    }, @{ Expression = { Get-GrokAccountLabel $_ } }, @{ Expression = { [string]$_.Email } })
}

function Sync-ActiveGrokSnapshot {
    if (-not $script:GrokAuthPath -or -not (Test-Path -LiteralPath $script:GrokAuthPath)) { return }
    if (-not $script:WidgetDir) { return }
    try {
        $active = Read-GrokAuthFromFile -Path $script:GrokAuthPath
        if (-not $active -or -not $active.AccountId) { return }
        [void](Write-SecureSnapshot -Provider grok -AccountId $active.AccountId -Value $active.Raw)
        $legacy = Get-GrokLegacySnapshotPath $active.AccountId
        if ($legacy -and (Test-Path -LiteralPath $legacy)) { Remove-Item -LiteralPath $legacy -Force -ErrorAction Stop }
    } catch {
        if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
            Write-WidgetLog ("grok snapshot sync failed: {0}" -f (Convert-SafeLogText $_.Exception.Message))
        }
        throw
    }
}
