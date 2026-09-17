# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WorkerSource.ps1
# 把主程序、各解析模块与 worker 拼接逻辑放进同一个进程里跑，专门盯住“新供应商漏加进 worker”这一类静默失效：
# worker 少注入一个函数或变量时，卡片只会显示“暂无用量数据”，很容易被误判成服务端问题。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$failed = 0
function Assert-True {
    param($Condition, [string]$Name)
    if (-not $Condition) {
        Write-Host ("FAIL {0}" -f $Name)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

function Get-ScriptFunctionNames {
    param([string]$Path)
    $names = @{}
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $names[$fn.Name] = $true
    }
    return $names
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$entryText = [IO.File]::ReadAllText($entry)

# worker 里的函数由主程序按名字导出，所以主程序 dot-source 的模块必须先就位。
# 模块清单直接从主程序解析：新模块漏改这里会立刻失败，而不是悄悄少一个函数。
$moduleList = @([regex]::Matches($entryText, '\. \(Join-Path \$script:WidgetDir \x27([^\x27]+)\x27\)') | ForEach-Object { $_.Groups[1].Value })
if ($moduleList.Count -lt 5) { throw 'the entry script does not expose its module list' }
foreach ($module in $moduleList) {
    $path = Join-Path $here $module
    if (-not (Test-Path -LiteralPath $path)) { throw ('module is dot-sourced but missing: ' + $module) }
    . $path
}

$definitions = ''
$entryAst = [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$null)
foreach ($fn in $entryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $definitions += ($fn.Extent.Text + [Environment]::NewLine + [Environment]::NewLine)
}
. ([ScriptBlock]::Create($definitions))

$worker = Get-WorkerScriptSource
$workerTokens = $null
$workerErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($worker, [ref]$workerTokens, [ref]$workerErrors)
Assert-True (@($workerErrors).Count -eq 0) 'worker source parses without errors'

# --- $fnNames 必须都能解析到真实函数（防拼写错误） ---
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
Assert-True $match.Success 'the worker function list is discoverable'
$fnNames = @()
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-True ($fnNames.Count -gt 50) ('the worker exports a full helper set ({0})' -f $fnNames.Count)
$missingFns = @()
foreach ($name in $fnNames) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { $missingFns += $name }
}
Assert-True ($missingFns.Count -eq 0) ('every exported function exists: ' + (($missingFns | Select-Object -First 5) -join ', '))

# --- $vNames 必须都能在 $Cfg 里取到值 ---
$merge = [regex]::Match($entryText, '(?s)foreach \(\$v in (.*?)\) \{')
Assert-True $merge.Success 'the worker variable list is discoverable'
$vNames = @()
if ($merge.Success) { $vNames = @([regex]::Matches($merge.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
$cfgBlock = [regex]::Match($entryText, '(?s)\$cfg = @\{(.*?)\n    \}')
Assert-True $cfgBlock.Success 'the worker config table is discoverable'
$cfgKeys = @()
if ($cfgBlock.Success) { $cfgKeys = @([regex]::Matches($cfgBlock.Groups[1].Value, '(?m)^\s+([A-Za-z0-9]+)\s*=\s*\$script:') | ForEach-Object { $_.Groups[1].Value }) }
$missingVars = @()
foreach ($name in $vNames) { if ($cfgKeys -notcontains $name) { $missingVars += $name } }
Assert-True ($missingVars.Count -eq 0) ('every exported variable is present in $Cfg: ' + (($missingVars | Select-Object -First 5) -join ', '))

# --- 每一条供应商行都要有对应的 worker 分支 ---
$kinds = @([regex]::Matches($entryText, "Kind\s*=\s*'([a-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-True ($kinds.Count -gt 0) 'row kinds are discoverable'
$missingKinds = @()
foreach ($kind in $kinds) {
    if ($worker -notmatch ("'" + [regex]::Escape($kind) + "'\s*\{")) { $missingKinds += $kind }
}
Assert-True ($missingKinds.Count -eq 0) ('every row kind is dispatched by the worker: ' + (($missingKinds | Select-Object -First 5) -join ', '))

# --- 调用图：worker 里调用到的每个命令，要么由 worker 自己定义，要么在全新 runspace 里存在 ---
$workerDefined = @{}
foreach ($fn in $workerAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $workerDefined[$fn.Name] = $true
}
$called = @{}
foreach ($cmd in $workerAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $cmd.GetCommandName()
    if ($name) { $called[$name] = $true }
}
$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
$unresolved = @()
try {
    foreach ($name in $called.Keys) {
        if ($workerDefined.ContainsKey($name)) { continue }
        $null = $ps.Commands.Clear()
        $null = $ps.AddScript('param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue)').AddArgument($name)
        $found = @($ps.Invoke())
        if (-not ($found -and $found[0])) { $unresolved += $name }
    }
} finally {
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()
}
Assert-True ($called.Count -gt 20) ('the worker calls a real command surface ({0})' -f $called.Count)
Assert-True ($unresolved.Count -eq 0) ('every command the worker calls is resolvable: ' + (($unresolved | Select-Object -First 5) -join ', '))

# --- 变量：worker 用到的 $script: 变量必须由 $Cfg 注入（别名是模块内自带默认值的覆盖项，属于例外） ---
$optionalOverrides = @('GrokAccountAliases', 'GrokAliasFileName')
$usedVars = @([regex]::Matches($worker, '\$script:([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$assignedVars = @([regex]::Matches($worker, '(?m)^\$script:([A-Za-z0-9_]+) = \$Cfg\.') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unassigned = @($usedVars | Where-Object { $assignedVars -notcontains $_ -and $optionalOverrides -notcontains $_ })
Assert-True ($usedVars.Count -gt 10) ('the worker reads a real variable surface ({0})' -f $usedVars.Count)
Assert-True ($unassigned.Count -eq 0) ('every $script: variable the worker reads comes from $Cfg: ' + (($unassigned | Select-Object -First 5) -join ', '))
if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
