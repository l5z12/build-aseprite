[CmdletBinding()]
param(
    [string]$Script,
    [string]$Readme,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Script) { $Script = Join-Path $PSScriptRoot '../../build-aseprite.ps1' }
if (-not $Readme) { $Readme = Join-Path $PSScriptRoot '../../README.md' }
$scriptPath = (Resolve-Path -LiteralPath $Script).Path
$readmePath = (Resolve-Path -LiteralPath $Readme).Path

function Format-Description([string]$Text) {
    $t = ($Text -replace '\s+', ' ').Trim()
    $t = [regex]::Replace($t, "(?<![\w``'-])(-[A-Z][A-Za-z]+(?: '[^']*')?)", '`$1`')
    $t = [regex]::Replace($t, '(?<![\w`])([^\s,;()`]*\\[^\s,;()`]*?)(?=[.,;)]?(?:\s|$))', '`$1`')
    $parts = $t -split '`'
    for ($i = 0; $i -lt $parts.Count; $i += 2) { $parts[$i] = $parts[$i] -replace '<', '&lt;' -replace '>', '&gt;' }
    return (($parts -join '`') -replace '\|', '\|')
}

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
if ($errors) { throw "Could not parse $scriptPath" }

$help = $ast.GetHelpContent()
if (-not $help) { throw "$scriptPath has no comment-based help" }
$descriptions = @{}
foreach ($key in $help.Parameters.Keys) { $descriptions[[string]$key] = [string]$help.Parameters[$key] }

$rows = foreach ($param in $ast.ParamBlock.Parameters) {
    $name = $param.Name.VariablePath.UserPath
    if (-not $descriptions.ContainsKey($name)) { throw "No .PARAMETER help for -$name" }
    '| `-{0}` | {1} |' -f $name, (Format-Description $descriptions[$name])
}

$start = '<!-- options:start -->'
$end = '<!-- options:end -->'
$content = [IO.File]::ReadAllText($readmePath)
$nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
$block = (@($start, '| Option | Description |', '|---|---|') + $rows + $end) -join $nl
$pattern = [regex]::Escape($start) + '(?s).*?' + [regex]::Escape($end)
if (-not [regex]::IsMatch($content, $pattern)) { throw "README is missing the $start / $end markers" }
$updated = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block })

if ($updated -ceq $content) {
    'README options are up to date.'
} elseif ($Check) {
    [Console]::Error.WriteLine('README options are out of date. Run .github/scripts/Update-ReadmeOptions.ps1.')
    exit 1
} else {
    [IO.File]::WriteAllText($readmePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    'README options updated.'
}
