# Static provider registry shared by validation and scheduling code.

$script:WidgetProviderRegistry = @(
    [pscustomobject]@{ Kind = 'grok';        DisplayName = 'Grok';              RowFunction = 'Get-GrokRowData';        UsagePageVariable = 'GrokUsagePageUrl';        CredentialFunction = 'Get-GrokAccounts';             Module = 'GrokAccounts.ps1' }
    [pscustomobject]@{ Kind = 'gemini';      DisplayName = 'Gemini';            RowFunction = 'Get-GeminiRowData';      UsagePageVariable = 'GeminiUsagePageUrl';      CredentialFunction = 'Get-GeminiAccounts';           Module = 'GeminiAntigravity.ps1' }
    [pscustomobject]@{ Kind = 'kimi';        DisplayName = 'Kimi';              RowFunction = 'Get-KimiRowData';        UsagePageVariable = 'KimiUsagePageUrl';        CredentialFunction = 'Get-KimiAccounts';             Module = 'KimiQuota.ps1' }
    [pscustomobject]@{ Kind = 'codex';       DisplayName = 'ChatGPT / Codex';   RowFunction = 'Get-CodexRowData';       UsagePageVariable = 'CodexUsagePageUrl';       CredentialFunction = 'Get-CodexAccounts';            Module = 'AiUsageWidget.ps1' }
    [pscustomobject]@{ Kind = 'commandcode'; DisplayName = 'Command Code';      RowFunction = 'Get-CommandCodeRowData'; UsagePageVariable = 'CommandCodeUsagePageUrl'; CredentialFunction = 'Get-CommandCodeAccounts';      Module = 'CommandCodeQuota.ps1' }
    [pscustomobject]@{ Kind = 'openrouter';  DisplayName = 'OpenRouter';        RowFunction = 'Get-OpenRouterRowData';  UsagePageVariable = 'OpenRouterUsagePageUrl';  CredentialFunction = 'Get-ApiKeySources';            Module = 'OpenRouterQuota.ps1' }
    [pscustomobject]@{ Kind = 'deepseek';    DisplayName = 'DeepSeek';          RowFunction = 'Get-DeepSeekRowData';    UsagePageVariable = 'DeepSeekUsagePageUrl';    CredentialFunction = 'Get-ApiKeySources';            Module = 'DeepSeekQuota.ps1' }
    [pscustomobject]@{ Kind = 'cline';       DisplayName = 'Cline';             RowFunction = 'Get-ClineRowData';       UsagePageVariable = 'ClineUsagePageUrl';       CredentialFunction = 'Test-ClineCredExists';          Module = 'ClineQuota.ps1' }
    [pscustomobject]@{ Kind = 'claude';      DisplayName = 'Claude';            RowFunction = 'Get-ClaudeRowData';      UsagePageVariable = 'ClaudeUsagePageUrl';      CredentialFunction = 'Test-ClaudeCredExists';         Module = 'ClaudeQuota.ps1' }
    [pscustomobject]@{ Kind = 'cursor';      DisplayName = 'Cursor';            RowFunction = 'Get-CursorRowData';      UsagePageVariable = 'CursorUsagePageUrl';      CredentialFunction = 'Test-CursorCredExists';         Module = 'CursorQuota.ps1' }
    [pscustomobject]@{ Kind = 'glm';         DisplayName = 'GLM / Z.AI';        RowFunction = 'Get-ZaiRowData';         UsagePageVariable = 'ZaiUsagePageUrl';         CredentialFunction = 'Test-ZaiCredExists';            Module = 'ZaiQuota.ps1' }
    [pscustomobject]@{ Kind = 'copilot';     DisplayName = 'GitHub Copilot';    RowFunction = 'Get-CopilotRowData';     UsagePageVariable = 'CopilotUsagePageUrl';     CredentialFunction = 'Test-CopilotCredExists';        Module = 'CopilotQuota.ps1' }
)

function Get-WidgetProviderRegistry {
    return @($script:WidgetProviderRegistry)
}

function Get-WidgetProviderDefinition {
    param([string]$Kind)
    return @($script:WidgetProviderRegistry | Where-Object { $_.Kind -eq $Kind })[0]
}

function Split-WidgetProviderRows {
    param($Rows, [int]$MaxWorkers = 3)
    $items = @($Rows)
    if ($items.Count -eq 0) { return @() }
    $workerCount = [Math]::Max(1, [Math]::Min($MaxWorkers, @($items | Group-Object Kind).Count))
    $chunks = @()
    for ($i = 0; $i -lt $workerCount; $i++) { $chunks += ,@() }
    foreach ($group in @($items | Group-Object Kind | Sort-Object Count -Descending)) {
        $target = 0
        for ($i = 1; $i -lt $chunks.Count; $i++) {
            if ($chunks[$i].Count -lt $chunks[$target].Count) { $target = $i }
        }
        $chunks[$target] = @($chunks[$target]) + @($group.Group)
    }
    return @($chunks | Where-Object { @($_).Count -gt 0 })
}

function Get-FetchFailureCategory {
    param($ErrorRecord, [string]$Message)
    $text = [string]$Message
    if (-not $text -and $ErrorRecord) { $text = [string]$ErrorRecord.Exception.Message }
    $code = $null
    if (Get-Command Get-HttpStatusCode -ErrorAction SilentlyContinue) {
        $code = Get-HttpStatusCode $ErrorRecord
    }
    if ($code -in @(401, 403)) { return 'auth' }
    if ($code -eq 429) { return 'rate-limit' }
    if ($text -match '(?i)timeout|timed out|canceled due to') { return 'timeout' }
    if ($text -match '(?i)429|too many requests|rate limit') { return 'rate-limit' }
    if ($text -match '(?i)bad-payload|parse|json|payload') { return 'parse' }
    if ($text -match '(?i)401|403|unauthorized|forbidden|auth-expired|missing-credential') { return 'auth' }
    return 'network'
}

function Get-ProviderBackoffSeconds {
    param(
        [string]$Category,
        [int]$FailureCount = 1,
        [datetime]$Now = (Get-Date),
        [int]$JitterSeed = 0
    )
    if ($Category -eq 'rate-limit') { return 60 }
    if ($Category -eq 'auth') { return 300 }
    $base = [int][Math]::Min(900, 30 * [Math]::Pow(2, [Math]::Max(0, $FailureCount - 1)))
    $jitter = [int][Math]::Abs(($JitterSeed + $Now.Minute * 17 + $FailureCount * 13) % 10)
    return [int][Math]::Min(900, $base + $jitter)
}
