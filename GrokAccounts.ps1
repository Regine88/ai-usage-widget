# Grok multi-account helpers for the usage widget.
# Mapping: user@example.com -> a, student@example.org -> b.

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
    $id = Get-GrokAccountId $Auth
    switch ($id) {
        'user@example.com' { return 'a' }
        'student@example.org' { return 'b' }
    }
    if ($Auth.Email) { return [string]$Auth.Email }
    return 'Grok'
}

function Get-GrokRowName {
    param($Auth)
    $label = Get-GrokAccountLabel $Auth
    if ($label -eq 'Grok') { return 'Grok' }
    return ('Grok {0}' -f $label)
}

function Get-GrokRowId {
    param($Auth)
    $label = Get-GrokAccountLabel $Auth
    if ($label -eq 'a' -or $label -eq 'b') { return ('grok-{0}' -f $label) }
    return ('grok-{0}' -f (Get-GrokAccountId $Auth))
}

function Get-GrokSnapshotFileName {
    param([string]$AccountId)
    $safe = $AccountId -replace '[<>:"/\\|?*]', '_'
    return ('grok-auth-{0}.json' -f $safe)
}

function Get-GrokSnapshotPath {
    param([string]$AccountId)
    Join-Path $script:WidgetDir (Get-GrokSnapshotFileName $AccountId)
}

function Read-GrokAuthFromFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        throw ('未找到 Grok 登录凭证: {0}' -f $Path)
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
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
    if (-not $best) { throw ('auth.json 中没有可用的登录凭证: {0}' -f $Path) }
    $email = [string]$best.entry.email
    $auth = [pscustomobject]@{
        Path         = $Path
        KeyName      = $best.keyName
        Token        = [string]$best.entry.key
        RefreshToken = [string]$best.entry.refresh_token
        ClientId     = [string]$best.entry.oidc_client_id
        Email        = $email
        ExpiresAt    = $best.expires
        Raw          = $raw
        Entry        = $best.entry
        AccountId    = $null
    }
    $auth.AccountId = Get-GrokAccountId $auth
    return $auth
}

function Get-GrokAccounts {
    $byId = [ordered]@{}
    if ($script:WidgetDir -and (Test-Path -LiteralPath $script:WidgetDir)) {
        foreach ($f in Get-ChildItem -LiteralPath $script:WidgetDir -Filter 'grok-auth-*.json' -ErrorAction SilentlyContinue) {
            try {
                $snap = Read-GrokAuthFromFile -Path $f.FullName
                if ($snap -and $snap.AccountId -and -not $byId.Contains($snap.AccountId)) {
                    $byId[$snap.AccountId] = $snap
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
        Expression = {
            switch (Get-GrokAccountLabel $_) {
                'a' { 0 }
                'b' { 1 }
                default { 2 }
            }
        }
    }, @{ Expression = { [string]$_.Email } })
}

function Sync-ActiveGrokSnapshot {
    if (-not $script:GrokAuthPath -or -not (Test-Path -LiteralPath $script:GrokAuthPath)) { return }
    if (-not $script:WidgetDir) { return }
    try {
        $active = Read-GrokAuthFromFile -Path $script:GrokAuthPath
        if (-not $active -or -not $active.AccountId) { return }
        $snap = Get-GrokSnapshotPath $active.AccountId
        Copy-Item -LiteralPath $script:GrokAuthPath -Destination $snap -Force
    } catch { }
}
