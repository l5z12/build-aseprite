<#
.SYNOPSIS
    Builds Aseprite from its official source code on Windows, for personal use.

.DESCRIPTION
    Downloads the official Aseprite source and the Skia it needs, builds it with
    Visual Studio, and delivers a portable copy (.\Aseprite) or an installer
    (-Installer). Re-running updates incrementally.

    Aseprite's EULA allows compiling it for your own personal use but forbids
    distributing copies, including installers made by this script.

.PARAMETER Version
    latest (default), latest-beta, a tag such as v1.3.14, a branch (main, beta),
    a commit SHA, or local to build -SourceDir as-is.

.PARAMETER BuildType
    Release (default), RelWithDebInfo (includes a .pdb) or Debug.

.PARAMETER Arch
    x64 (default) or x86.

.PARAMETER SourceMode
    Git (default) or Zip (official release source zip; tags only, no Git needed).

.PARAMETER WorkDir
    Folder for source, dependencies, build files and logs. Default: script folder.

.PARAMETER SourceDir
    Git checkout location. Default: <WorkDir>\src.

.PARAMETER InstallDir
    Portable copy location. Default: <WorkDir>\Aseprite. With -Installer, a
    portable copy is only made when this is given.

.PARAMETER SkiaDir
    Use an existing Skia build instead of downloading one.

.PARAMETER VsVersion
    Visual Studio to use: latest (default), 2019, 2022, 2026 or a major version.

.PARAMETER Jobs
    Parallel compile jobs (default: automatic). Lower it if the compiler runs out of memory.

.PARAMETER Translations
    Include community translations.

.PARAMETER Portable
    Store the portable copy's settings next to its exe instead of %APPDATA%\Aseprite.

.PARAMETER NoUpdateCheck
    Disable the update check and the news on the Home tab.

.PARAMETER Tests
    Also build and run the unit tests.

.PARAMETER CMakeArgs
    Extra CMake arguments, e.g. -CMakeArgs '-DENABLE_PSD=ON'.

.PARAMETER Clean
    Full rebuild.

.PARAMETER NoInstall
    Don't make the portable copy.

.PARAMETER Installer
    Build an installer in dist\ with shortcuts, optional file associations and an
    uninstaller. Requires Inno Setup 6.3 or newer.

.PARAMETER RunInstaller
    Build the installer and launch it.

.PARAMETER SilentInstall
    Build the installer and run it unattended, keeping earlier install options.

.PARAMETER InstallPrereqs
    Install missing tools with winget (Git, CMake, Ninja, Visual Studio Build Tools,
    and Inno Setup when needed).

.PARAMETER FullHistory
    Fetch full git history instead of a shallow checkout.

.PARAMETER Force
    Discard local source changes; allow a portable folder the script didn't create.

.PARAMETER Run
    Launch Aseprite when done.

.PARAMETER ShowBuildOutput
    Show all tool output instead of progress bars.

.PARAMETER ListVersions
    Show available and installed versions, then exit.

.EXAMPLE
    .\build-aseprite.ps1

.EXAMPLE
    .\build-aseprite.ps1 -InstallPrereqs -RunInstaller

.EXAMPLE
    .\build-aseprite.ps1 -SilentInstall

.EXAMPLE
    .\build-aseprite.ps1 v1.3.14 -Translations

.EXAMPLE
    .\build-aseprite.ps1 -ListVersions
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Version = 'latest',

    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$BuildType = 'Release',

    [ValidateSet('x64', 'x86')]
    [string]$Arch = 'x64',

    [ValidateSet('Git', 'Zip')]
    [string]$SourceMode = 'Git',

    [string]$WorkDir = $PSScriptRoot,
    [string]$SourceDir,
    [string]$InstallDir,
    [string]$SkiaDir,
    [string]$VsVersion = 'latest',

    [ValidateRange(0, 1024)]
    [int]$Jobs = 0,

    [switch]$Translations,
    [switch]$Portable,
    [switch]$NoUpdateCheck,
    [switch]$Tests,
    [string[]]$CMakeArgs = @(),
    [switch]$Clean,
    [switch]$NoInstall,
    [switch]$Installer,
    [switch]$RunInstaller,
    [switch]$SilentInstall,
    [switch]$InstallPrereqs,
    [switch]$FullHistory,
    [switch]$Force,
    [switch]$Run,
    [switch]$ShowBuildOutput,
    [switch]$ListVersions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

$ScriptVersion   = '1.0.0'
$RepoUrl         = 'https://github.com/aseprite/aseprite.git'
$ReleasesApi     = 'https://api.github.com/repos/aseprite/aseprite/releases'
$ReleaseDownload = 'https://github.com/aseprite/aseprite/releases/download'
$SkiaDownload    = 'https://github.com/aseprite/skia/releases/download'
$MarkerFile      = 'build-info.json'
$UserAgent       = 'aseprite-build-script'
$InstallerAppId  = '{E9A4EDAE-B3A7-420D-969F-23AFD5695220}'
$MinInnoVersion  = [version]'6.3'

$LegacySkiaTags = @{
    'm124' = 'm124-08a5439a6b'
    'm102' = 'm102-861e4743af'
    'm96'  = 'm96-2f1f21b8a9'
    'm81'  = 'm81-b607b32047'
}

$script:LogWriter  = $null
$script:LogPath    = $null
$script:FailHints  = @()
$script:Phase      = $null
$script:Timings    = New-Object System.Collections.Generic.List[object]
$script:RemoteRefs = $null
$script:GitExe     = $null
$script:LastLines  = New-Object System.Collections.Generic.List[string]
$script:CommandLine = $MyInvocation.Line
$script:NinjaNoise = '^(Microsoft \(R\) Macro Assembler|Copyright \(C\) Microsoft Corporation|\s*Assembling: |cl : Command line warning D9025)'

# --------------------------------------------------------------------------
# Output and logging
# --------------------------------------------------------------------------

function Write-BuildLog([string]$Text) {
    if ($script:LogWriter) { $script:LogWriter.WriteLine($Text) }
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
    Write-BuildLog ''
    Write-BuildLog "==> $Text  [$(Get-Date -Format 'HH:mm:ss')]"
}

function Write-Info([string]$Text) {
    Write-Host "    $Text"
    Write-BuildLog "    $Text"
}

function Write-Detail([string]$Text) {
    Write-Host "    $Text" -ForegroundColor DarkGray
    Write-BuildLog "    $Text"
}

function Write-Warn([string]$Text) {
    Write-Host "    WARNING: $Text" -ForegroundColor Yellow
    Write-BuildLog "    WARNING: $Text"
}

function Stop-Build {
    param([string]$Message, [string[]]$Hint = @())
    $script:FailHints = $Hint
    throw $Message
}

function Start-Phase([string]$Name) {
    Complete-Phase
    Write-Step $Name
    $script:Phase = @{ Name = $Name; Watch = [Diagnostics.Stopwatch]::StartNew() }
}

function Complete-Phase {
    if ($script:Phase) {
        $script:Timings.Add([pscustomobject]@{ Step = $script:Phase.Name; Elapsed = $script:Phase.Watch.Elapsed })
        $script:Phase = $null
    }
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalHours -ge 1) { return '{0}h {1:D2}m {2:D2}s' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds }
    if ($Span.TotalMinutes -ge 1) { return '{0}m {1:D2}s' -f $Span.Minutes, $Span.Seconds }
    return '{0:N1}s' -f $Span.TotalSeconds
}

function Initialize-Log([string]$Root) {
    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Get-ChildItem -LiteralPath $logDir -Filter 'build-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 19 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $script:LogPath = Join-Path $logDir ('build-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:LogWriter = New-Object System.IO.StreamWriter($script:LogPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $script:LogWriter.AutoFlush = $true
    Write-BuildLog "build-aseprite.ps1 v$ScriptVersion  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-BuildLog "PowerShell $($PSVersionTable.PSVersion)  OS $([Environment]::OSVersion.VersionString)"
    Write-BuildLog "Command line: $script:CommandLine"
}

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

function Resolve-FullPath([string]$Path) {
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $p = [IO.Path]::GetFullPath($p)
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Test-SamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    try {
        $na = [IO.Path]::GetFullPath(($A -replace '/', '\')).TrimEnd('\')
        $nb = [IO.Path]::GetFullPath(($B -replace '/', '\')).TrimEnd('\')
        return [string]::Equals($na, $nb, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function ConvertTo-CMakePath([string]$Path) { return ($Path -replace '\\', '/') }

# --------------------------------------------------------------------------
# Running external tools
# --------------------------------------------------------------------------

function Get-FailureHints([string[]]$Lines) {
    $text = $Lines -join "`n"
    $hints = New-Object System.Collections.Generic.List[string]
    if ($text -match 'C1060|C1002|C3859|out of heap space|compiler is out of heap|virtual memory') {
        $hints.Add('The compiler ran out of memory. Re-run with fewer parallel jobs, e.g. -Jobs 4.')
    }
    if ($text -match 'LNK1104: cannot open file .*aseprite\.exe') {
        $hints.Add('aseprite.exe is locked: close any running Aseprite started from the build folder.')
    }
    if ($text -match 'LNK2038|RuntimeLibrary|LNK1112|machine type') {
        $hints.Add('Library mismatch between Skia and this build. Re-run with -Clean; check -Arch and -BuildType.')
    }
    if ($text -match 'C1083: Cannot open (include|source) file') {
        $hints.Add('A source file is missing, usually an incomplete submodule. Re-run with -Force to repair the checkout.')
    }
    if ($text -match 'Compatibility with CMake < ') {
        $hints.Add('A dependency is too old for this CMake. Install CMake 3.x or set -CMakeArgs "-DCMAKE_POLICY_VERSION_MINIMUM=3.5".')
    }
    if ($text -match 'Could not resolve host|Failed to connect|unable to access|Connection (timed out|reset)') {
        $hints.Add('Network problem talking to GitHub. Check your connection/proxy and re-run (finished steps are cached).')
    }
    if ($text -match 'error C\d{4}' -and $hints.Count -eq 0) {
        $hints.Add('Compile error. Older Aseprite versions may not compile with a newer MSVC: try a newer version, or -VsVersion 2022.')
    }
    return $hints.ToArray()
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateSet('Show', 'Progress', 'Ninja')][string]$Display = 'Progress',
        [string]$Activity = '',
        [int[]]$OkExitCodes = @(0),
        [switch]$AllowFailure
    )
    if ($ShowBuildOutput) { $Display = 'Show' }
    if (-not $Activity) { $Activity = [IO.Path]::GetFileNameWithoutExtension($FilePath) }

    Write-BuildLog ("> `"{0}`" {1}" -f $FilePath, ($ArgumentList -join ' '))
    $script:LastLines.Clear()
    $state = @{ Last = [DateTime]::MinValue }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-BuildLog $line
            $script:LastLines.Add($line)
            if ($script:LastLines.Count -gt 600) { $script:LastLines.RemoveAt(0) }
            switch ($Display) {
                'Show' { Write-Host $line }
                'Progress' {
                    $now = [DateTime]::UtcNow
                    if (($now - $state.Last).TotalMilliseconds -ge 150 -and $line.Trim()) {
                        $status = $line.Trim()
                        if ($status.Length -gt 110) { $status = $status.Substring(0, 107) + '...' }
                        Write-Progress -Id 1 -Activity $Activity -Status $status
                        $state.Last = $now
                    }
                }
                'Ninja' {
                    $m = [regex]::Match($line, '^\[(\d+)/(\d+)\]\s*(.*)$')
                    if ($m.Success) {
                        $now = [DateTime]::UtcNow
                        if (($now - $state.Last).TotalMilliseconds -ge 150) {
                            $done = [int]$m.Groups[1].Value
                            $total = [Math]::Max(1, [int]$m.Groups[2].Value)
                            $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                            $what = $m.Groups[3].Value
                            if ($what.Length -gt 100) { $what = '...' + $what.Substring($what.Length - 97) }
                            Write-Progress -Id 1 -Activity $Activity -Status "$done / $total  ($pct%)" -CurrentOperation $what -PercentComplete $pct
                            $state.Last = $now
                        }
                    } elseif ($line.Trim() -and $line -notmatch $script:NinjaNoise) {
                        Write-Host $line
                    }
                }
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        Write-Progress -Id 1 -Activity $Activity -Completed
    }
    if ($null -eq $code) { $code = 0 }
    Write-BuildLog "< exit code $code"
    if ($AllowFailure) { return $code }
    if ($OkExitCodes -notcontains $code) {
        $lines = $script:LastLines.ToArray()
        if ($Display -ne 'Show') {
            $important = @($lines | Where-Object { $_ -match '(?i)(\berror\b|FAILED:|fatal|CMake Error|LNK\d{4})' } | Select-Object -First 25)
            if ($important.Count -eq 0) { $important = @($lines | Select-Object -Last 30) }
            Write-Host ''
            foreach ($l in $important) { Write-Host "    $l" -ForegroundColor Red }
        }
        Stop-Build ("{0} failed (exit code {1})." -f [IO.Path]::GetFileName($FilePath), $code) -Hint (Get-FailureHints $lines)
    }
}

function Get-NativeOutput {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$AllowFailure)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @ArgumentList 2>$null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldEap }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        Stop-Build ("'{0} {1}' failed (exit code {2})." -f [IO.Path]::GetFileName($FilePath), ($ArgumentList -join ' '), $code)
    }
    return $out
}

function Invoke-Git {
    param([string[]]$GitArgs, [string]$Activity = 'git', [switch]$AllowFailure)
    if ($AllowFailure) {
        return (Invoke-Native -FilePath $script:GitExe -ArgumentList $GitArgs -Activity $Activity -AllowFailure)
    }
    Invoke-Native -FilePath $script:GitExe -ArgumentList $GitArgs -Activity $Activity
}

# --------------------------------------------------------------------------
# Downloads and archives
# --------------------------------------------------------------------------

function Save-Download([string]$Url, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        Write-Detail "Using cached $([IO.Path]::GetFileName($Destination))"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $part = "$Destination.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Write-Info "Downloading $Url"
    Write-BuildLog "download $Url -> $Destination"

    $ok = $false
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $progress = '--progress-bar'
            try { if ([Console]::IsErrorRedirected) { $progress = '--silent' } } catch { }
            & $curl --fail --location --retry 3 --retry-delay 2 --ssl-revoke-best-effort $progress --show-error --user-agent $UserAgent --output $part $Url
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Write-Warn "curl failed (exit code $LASTEXITCODE); retrying with Invoke-WebRequest." }
        } finally { $ErrorActionPreference = $oldEap }
    }
    if (-not $ok) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $oldPp = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -UserAgent $UserAgent
        } catch {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $status = ''
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ("$status" -eq '404') { Stop-Build "Not found on GitHub: $Url" }
            Stop-Build "Download failed: $Url ($($_.Exception.Message))" -Hint @('Check your internet connection / proxy and re-run.')
        } finally { $ProgressPreference = $oldPp }
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
}

function Expand-Zip([string]$Zip, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        $code = Invoke-Native -FilePath $tar -ArgumentList @('-xf', $Zip, '-C', $Destination) -Activity "Extracting $([IO.Path]::GetFileName($Zip))" -AllowFailure
        if ($code -eq 0) { return }
        Write-Warn 'tar.exe could not extract the archive; trying Expand-Archive.'
    }
    $oldPp = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force }
    finally { $ProgressPreference = $oldPp }
}

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

function Update-PathFromRegistry {
    $current = @($env:Path -split ';' | Where-Object { $_ })
    $fresh = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) -split ';' } | Where-Object { $_ }
    $add = @($fresh | Where-Object { $current -notcontains $_ } | Select-Object -Unique)
    if ($add.Count -gt 0) { $env:Path = (@($current) + $add) -join ';' }
}

function Install-WithWinget([string]$Name, [string]$Id, [string[]]$Extra = @()) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Stop-Build "$Name is missing and winget is not available to install it." -Hint @("Install $Name manually, then re-run.", 'winget comes with "App Installer" from the Microsoft Store.')
    }
    Write-Info "Installing $Name with winget ($Id)..."
    $wingetArgs = @('install', '--id', $Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $Extra
    $code = Invoke-Native -FilePath $winget.Source -ArgumentList $wingetArgs -Display Show -AllowFailure
    if (@(0, -1978335189, -1978335135) -notcontains $code) {
        Stop-Build "winget could not install $Name (exit code $code)." -Hint @("Install $Name manually, then re-run.")
    }
    Update-PathFromRegistry
}

function Find-Git {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if (-not $base) { continue }
        $candidate = Join-Path $base 'Git\cmd\git.exe'
        if (Test-Path -LiteralPath $candidate) {
            $env:Path = (Split-Path -Parent $candidate) + ';' + $env:Path
            return $candidate
        }
    }
    return $null
}

function Enable-GitLongPaths {
    $count = 0
    if ($env:GIT_CONFIG_COUNT -match '^\d+$') { $count = [int]$env:GIT_CONFIG_COUNT }
    for ($i = 0; $i -lt $count; $i++) {
        if ([Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_$i") -eq 'core.longpaths') { return }
    }
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$count", 'core.longpaths')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$count", 'true')
    $env:GIT_CONFIG_COUNT = "$($count + 1)"
}

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }

    $range = $null
    switch -Regex ($VsVersion) {
        '^(latest|)$' { break }
        '^2017$' { $range = '[15.0,16.0)'; break }
        '^2019$' { $range = '[16.0,17.0)'; break }
        '^2022$' { $range = '[17.0,18.0)'; break }
        '^2026$' { $range = '[18.0,19.0)'; break }
        '^\d{2}$' { $range = '[{0}.0,{1}.0)' -f [int]$VsVersion, ([int]$VsVersion + 1); break }
        default { Stop-Build "Unknown -VsVersion '$VsVersion'." -Hint @('Use latest, 2019, 2022, 2026 or a major version such as 17.') }
    }
    $vsArgs = @('-products', '*', '-prerelease', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json')
    if ($range) { $vsArgs += @('-version', $range) }
    $json = (Get-NativeOutput -FilePath $vswhere -ArgumentList $vsArgs -AllowFailure) | Out-String
    if (-not $json.Trim()) { return $null }
    $parsed = $json | ConvertFrom-Json
    $instances = foreach ($i in $parsed) {
        if (Test-Path -LiteralPath (Join-Path $i.installationPath 'VC\Auxiliary\Build\vcvarsall.bat')) { $i }
    }
    $vs = @($instances | Sort-Object -Property @{ Expression = { [version]$_.installationVersion } } -Descending) | Select-Object -First 1
    if (-not $vs) { return $null }
    return [pscustomobject]@{
        Name    = $vs.displayName
        Path    = $vs.installationPath
        Version = $vs.installationVersion
        VcVars  = Join-Path $vs.installationPath 'VC\Auxiliary\Build\vcvarsall.bat'
    }
}

function Import-VsEnvironment($Vs) {
    if ([Environment]::Is64BitOperatingSystem) {
        $vcArg = if ($Arch -eq 'x64') { 'x64' } else { 'x64_x86' }
    } else {
        $vcArg = if ($Arch -eq 'x86') { 'x86' } else { 'x86_x64' }
    }
    $marker = '###ASEPRITE-BUILD-ENV###'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aseprite-vcvars-{0}.cmd' -f [guid]::NewGuid().ToString('N'))
    $cmdText = "@echo off`r`ncall `"$($Vs.VcVars)`" $vcArg`r`necho $marker`r`nset`r`n"
    [IO.File]::WriteAllText($tmp, $cmdText, [Text.Encoding]::ASCII)
    try {
        $out = Get-NativeOutput -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d', '/c', $tmp) -AllowFailure
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $lines = @($out)
    $idx = [Array]::IndexOf($lines, $marker)
    if ($idx -lt 0) {
        $lines | ForEach-Object { Write-BuildLog $_ }
        Stop-Build "Could not load the Visual Studio environment ($($Vs.VcVars) $vcArg)."
    }
    foreach ($line in $lines[($idx + 1)..($lines.Count - 1)]) {
        $m = [regex]::Match($line, '^([^=]+)=(.*)$')
        if ($m.Success) { [Environment]::SetEnvironmentVariable($m.Groups[1].Value, $m.Groups[2].Value, 'Process') }
    }
    $before = $lines[0..([Math]::Max(0, $idx - 1))] | Where-Object { $_ -match '\[ERROR' }
    foreach ($l in @($before)) { if ($l) { Write-Warn $l } }
    if (-not $env:VCToolsInstallDir) {
        Stop-Build "vcvarsall.bat ran but the MSVC environment is incomplete." -Hint @('Repair the "Desktop development with C++" workload in the Visual Studio Installer.')
    }
}

function Get-ToolVersion([string]$Exe) {
    $first = @(Get-NativeOutput -FilePath $Exe -ArgumentList @('--version') -AllowFailure) | Select-Object -First 1
    $m = [regex]::Match([string]$first, '(\d+\.\d+(\.\d+)?)')
    if ($m.Success) { return [version]$m.Groups[1].Value }
    return $null
}

function Find-VsBundledTool([string]$Relative) {
    if (-not $env:VSINSTALLDIR) { return $null }
    $p = Join-Path $env:VSINSTALLDIR ("Common7\IDE\CommonExtensions\Microsoft\CMake\" + $Relative)
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Find-CMake {
    $cmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @((Find-VsBundledTool 'CMake\bin\cmake.exe'), (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Find-Ninja {
    $cmd = Get-Command ninja.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Find-VsBundledTool 'Ninja\ninja.exe'
    if ($p) { return $p }
    $links = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ninja.exe'
    if (Test-Path -LiteralPath $links) { return $links }
    return $null
}

# --------------------------------------------------------------------------
# Versions
# --------------------------------------------------------------------------

function Get-TagInfo([string]$Tag) {
    $m = [regex]::Match($Tag, '^v(\d+(?:\.\d+){0,3})(?:-(alpha|beta|rc)(\d*))?$')
    if (-not $m.Success) { return $null }
    $nums = @($m.Groups[1].Value.Split('.') | ForEach-Object { [int]$_ })
    while ($nums.Count -lt 4) { $nums += 0 }
    $kind = $m.Groups[2].Value
    $rank = switch ($kind) { 'alpha' { 0 } 'beta' { 1 } 'rc' { 2 } default { 3 } }
    $pre = 0
    if ($m.Groups[3].Value) { $pre = [int]$m.Groups[3].Value }
    return [pscustomobject]@{
        Tag        = $Tag
        Prerelease = [bool]$kind
        Key        = '{0:D5}.{1:D5}.{2:D5}.{3:D5}.{4}.{5:D5}' -f $nums[0], $nums[1], $nums[2], $nums[3], $rank, $pre
    }
}

function Get-SortedTags([hashtable]$Tags, [switch]$IncludePrerelease) {
    $list = foreach ($t in $Tags.Keys) {
        $info = Get-TagInfo $t
        if ($info -and ($IncludePrerelease -or -not $info.Prerelease)) { $info }
    }
    return @($list | Sort-Object -Property Key -Descending)
}

function Get-RemoteRefs {
    if ($script:RemoteRefs) { return $script:RemoteRefs }
    $tags = @{}
    $branches = @{}
    if ($script:GitExe) {
        $lines = Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('ls-remote', '--tags', '--heads', $RepoUrl) -AllowFailure
        foreach ($l in @($lines)) {
            $m = [regex]::Match([string]$l, '^([0-9a-f]{40})\s+refs/(tags|heads)/(.+?)(\^\{\})?$')
            if (-not $m.Success) { continue }
            if ($m.Groups[2].Value -eq 'tags') { $tags[$m.Groups[3].Value] = $m.Groups[1].Value }
            else { $branches[$m.Groups[3].Value] = $m.Groups[1].Value }
        }
    } else {
        try {
            for ($page = 1; $page -le 5; $page++) {
                $releases = @(Invoke-RestMethod -Uri "$ReleasesApi`?per_page=100&page=$page" -UseBasicParsing -UserAgent $UserAgent)
                if ($releases.Count -eq 0) { break }
                foreach ($r in $releases) { $tags[[string]$r.tag_name] = $null }
            }
        } catch {
            Write-BuildLog "GitHub API error: $($_.Exception.Message)"
        }
    }
    if ($tags.Count -eq 0) {
        Stop-Build 'Could not list Aseprite versions from GitHub.' -Hint @('Check your internet connection / proxy.', 'Without Git, the GitHub API is used, which allows 60 requests per hour.')
    }
    $script:RemoteRefs = [pscustomobject]@{ Tags = $tags; Branches = $branches }
    return $script:RemoteRefs
}

function Resolve-SourceRef([string]$Spec) {
    $s = $Spec.Trim()
    if ($s -eq 'local') { return [pscustomobject]@{ Kind = 'local'; Name = 'local' } }

    $refs = Get-RemoteRefs
    if ($s -in @('latest', 'stable', 'release')) {
        $top = @(Get-SortedTags $refs.Tags) | Select-Object -First 1
        if (-not $top) { Stop-Build 'No stable release tags found.' }
        return [pscustomobject]@{ Kind = 'tag'; Name = $top.Tag }
    }
    if ($s -in @('latest-beta', 'prerelease', 'preview')) {
        $top = @(Get-SortedTags $refs.Tags -IncludePrerelease) | Select-Object -First 1
        return [pscustomobject]@{ Kind = 'tag'; Name = $top.Tag }
    }
    if ($refs.Branches.ContainsKey($s)) { return [pscustomobject]@{ Kind = 'branch'; Name = $s } }
    foreach ($candidate in @($s, "v$s")) {
        foreach ($t in $refs.Tags.Keys) {
            if ([string]::Equals($t, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Kind = 'tag'; Name = $t }
            }
        }
    }
    if ($s -match '^[0-9a-fA-F]{7,40}$') { return [pscustomobject]@{ Kind = 'commit'; Name = $s.ToLowerInvariant() } }

    $needle = $s.TrimStart('v', 'V')
    $similar = @(Get-SortedTags $refs.Tags -IncludePrerelease | Where-Object { $_.Tag -like "*$needle*" } | Select-Object -First 6 | ForEach-Object { $_.Tag })
    $hint = @('Run with -ListVersions to see what is available.')
    if ($similar.Count -gt 0) { $hint = @("Did you mean: $($similar -join ', ')?") + $hint }
    Stop-Build "Unknown version '$s'." -Hint $hint
}

# --------------------------------------------------------------------------
# Source
# --------------------------------------------------------------------------

function Sync-GitSource([string]$Dir, $Ref) {
    $isNew = -not (Test-Path -LiteralPath (Join-Path $Dir '.git'))
    if ($isNew) {
        if ((Test-Path -LiteralPath $Dir) -and @(Get-ChildItem -LiteralPath $Dir -Force).Count -gt 0) {
            Stop-Build "Source folder '$Dir' exists but is not a git checkout." -Hint @('Delete it, or choose another folder with -SourceDir.')
        }
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Invoke-Git @('init', '--quiet', $Dir)
        Invoke-Git @('-C', $Dir, 'remote', 'add', 'origin', $RepoUrl)
    } else {
        $origin = @(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $Dir, 'remote', 'get-url', 'origin') -AllowFailure) | Select-Object -First 1
        if (-not $origin) {
            Invoke-Git @('-C', $Dir, 'remote', 'add', 'origin', $RepoUrl)
        } elseif ($origin -notmatch 'github\.com[/:]aseprite/aseprite(\.git)?/?$') {
            Write-Warn "The checkout's origin is $origin (not the official repository); fetching from it anyway."
        }
        $dirty = @(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $Dir, 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=dirty'))
        if ($dirty.Count -gt 0 -and $dirty[0]) {
            if (-not $Force) {
                Stop-Build 'The source checkout has local changes.' -Hint @('Build them as they are: -Version local', 'Throw them away: -Force', "Checkout: $Dir")
            }
            Write-Warn 'Discarding local changes in the source checkout (-Force).'
        }
    }
    Invoke-Git @('-C', $Dir, 'config', 'core.longpaths', 'true')

    $isShallow = $isNew -or ((@(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $Dir, 'rev-parse', '--is-shallow-repository') -AllowFailure) | Select-Object -First 1) -eq 'true')
    if ($FullHistory) {
        if ($isShallow -and -not $isNew) { Invoke-Git @('-C', $Dir, 'fetch', '--unshallow', '--tags', 'origin') -Activity 'Fetching full history' }
        $fetchOpts = @('--tags')
        $isShallow = $false
    } else {
        $fetchOpts = @('--no-tags')
        if ($isShallow) { $fetchOpts += @('--depth', '1') }
    }

    switch ($Ref.Kind) {
        'tag' {
            $refspec = "+refs/tags/$($Ref.Name):refs/tags/$($Ref.Name)"
            $target = "refs/tags/$($Ref.Name)"
        }
        'branch' {
            $refspec = "+refs/heads/$($Ref.Name):refs/remotes/origin/$($Ref.Name)"
            $target = "refs/remotes/origin/$($Ref.Name)"
        }
        'commit' {
            $refspec = $Ref.Name
            $target = $Ref.Name
        }
    }

    $haveCommit = $false
    if ($Ref.Kind -eq 'commit') {
        $haveCommit = $null -ne (Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $Dir, 'rev-parse', '--verify', '--quiet', "$($Ref.Name)^{commit}") -AllowFailure)
        if (-not $haveCommit -and $Ref.Name.Length -lt 40 -and -not $FullHistory) {
            Stop-Build "A short commit SHA can't be fetched shallowly." -Hint @('Pass the full 40-character SHA, or add -FullHistory.')
        }
    }
    if (-not $haveCommit) {
        if ($Ref.Kind -eq 'commit' -and $FullHistory) {
            Invoke-Git (@('-C', $Dir, 'fetch') + $fetchOpts + @('origin')) -Activity 'Fetching Aseprite history'
        } else {
            Invoke-Git (@('-C', $Dir, 'fetch') + $fetchOpts + @('origin', $refspec)) -Activity "Fetching Aseprite $($Ref.Name)"
        }
        if ($Ref.Kind -eq 'commit' -and $Ref.Name.Length -eq 40 -and -not $FullHistory) { $target = 'FETCH_HEAD' }
    }
    Invoke-Git @('-C', $Dir, '-c', 'advice.detachedHead=false', 'checkout', '--force', '--detach', $target) -Activity 'Checking out'

    Write-Info 'Updating submodules...'
    Invoke-Git @('-C', $Dir, 'submodule', 'sync', '--recursive', '--quiet') -Activity 'Syncing submodules'
    $subArgs = @('-C', $Dir, '-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--recursive', '--jobs', '8')
    if ($Force) { $subArgs += '--force' }
    if ($isShallow) {
        $code = Invoke-Git ($subArgs + @('--depth', '1')) -Activity 'Fetching submodules' -AllowFailure
        if ($code -ne 0) {
            Write-Warn 'Shallow submodule fetch failed; retrying with full submodule history.'
            Invoke-Git $subArgs -Activity 'Fetching submodules'
        }
    } else {
        Invoke-Git $subArgs -Activity 'Fetching submodules'
    }
}

function Get-ZipSource([string]$Tag) {
    $dir = Join-Path $script:WorkRoot "src-zip\$Tag"
    $stamp = Join-Path $dir '.extracted'
    if (Test-Path -LiteralPath $stamp) {
        Write-Detail "Using cached source $dir"
        return $dir
    }
    $zipName = "Aseprite-$Tag-Source.zip"
    $zip = Join-Path $script:WorkRoot "deps\downloads\$zipName"
    Save-Download "$ReleaseDownload/$Tag/$zipName" $zip

    $tmp = "$dir.tmp"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    try { Expand-Zip $zip $tmp }
    catch {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Stop-Build "The source zip was damaged and has been deleted; re-run to download it again."
    }
    $root = $tmp
    if (-not (Test-Path -LiteralPath (Join-Path $root 'CMakeLists.txt'))) {
        $sub = @(Get-ChildItem -LiteralPath $tmp -Directory)
        if ($sub.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $sub[0].FullName 'CMakeLists.txt'))) { $root = $sub[0].FullName }
        else { Stop-Build "$zipName doesn't look like Aseprite source (no CMakeLists.txt)." }
    }
    if ($root -eq $tmp) { Move-Item -LiteralPath $tmp -Destination $dir }
    else {
        Move-Item -LiteralPath $root -Destination $dir
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText($stamp, (Get-Date -Format o))
    return $dir
}

# --------------------------------------------------------------------------
# Skia
# --------------------------------------------------------------------------

function Get-SkiaTag([string]$Src) {
    $tagFile = Join-Path $Src 'laf\misc\skia-tag.txt'
    if (Test-Path -LiteralPath $tagFile) {
        $t = (Get-Content -LiteralPath $tagFile -Raw).Trim()
        if ($t) { return $t }
    }
    $install = Join-Path $Src 'INSTALL.md'
    if (Test-Path -LiteralPath $install) {
        $m = [regex]::Match((Get-Content -LiteralPath $install -Raw), 'aseprite-(m\d+)')
        if ($m.Success) {
            $branch = $m.Groups[1].Value
            if ($LegacySkiaTags.ContainsKey($branch)) { return $LegacySkiaTags[$branch] }
            Stop-Build "This Aseprite version needs Skia branch aseprite-$branch, which has no prebuilt package." -Hint @('Build Skia yourself (https://github.com/aseprite/skia) and pass -SkiaDir, or choose a newer Aseprite version.')
        }
    }
    Stop-Build 'Could not work out which Skia this Aseprite source needs.' -Hint @('Aseprite v1.2 and newer are supported; v1.1.x and older did not use Skia.')
}

function Initialize-Skia([string]$Tag) {
    $flavor = if ($BuildType -eq 'Debug') { 'Debug' } else { 'Release' }
    $libSub = "out\$flavor-$Arch"

    if ($SkiaDir) {
        $dir = Resolve-FullPath $SkiaDir
        if (-not (Test-Path -LiteralPath (Join-Path $dir "$libSub\skia.lib"))) {
            Stop-Build "-SkiaDir '$dir' has no $libSub\skia.lib." -Hint @("Build type $BuildType / $Arch needs Skia's $libSub folder.")
        }
        Write-Info "Using your Skia at $dir"
        return [pscustomobject]@{ Tag = 'custom'; Dir = $dir; LibDir = (Join-Path $dir $libSub); ZipSha256 = $null }
    }

    $milestone = [int](($Tag -replace '^m(\d+).*$', '$1'))
    if ($flavor -eq 'Debug' -and $milestone -lt 124) {
        Stop-Build "There is no prebuilt Debug Skia for $Tag (this Aseprite version)." -Hint @('Use -BuildType RelWithDebInfo instead, or build Skia yourself and pass -SkiaDir.')
    }

    $dir = Join-Path $script:WorkRoot "deps\skia-$Tag"
    $libDir = Join-Path $dir $libSub
    $stamp = Join-Path $libDir '.aseprite-build-ok'
    $zipName = "Skia-Windows-$flavor-$Arch.zip"
    $zip = Join-Path $script:WorkRoot "deps\downloads\skia-$Tag-$zipName"

    if (-not ((Test-Path -LiteralPath $stamp) -and (Test-Path -LiteralPath (Join-Path $libDir 'skia.lib')))) {
        Save-Download "$SkiaDownload/$Tag/$zipName" $zip
        try { Expand-Zip $zip $dir }
        catch {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Stop-Build 'The Skia archive was damaged and has been deleted; re-run to download it again.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $libDir 'skia.lib'))) {
            Stop-Build "$zipName did not contain $libSub\skia.lib."
        }
        [IO.File]::WriteAllText($stamp, (Get-Date -Format o))
    } else {
        Write-Detail "Using cached Skia $Tag ($flavor-$Arch)"
    }
    $sha = $null
    if (Test-Path -LiteralPath $zip) { $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
    return [pscustomobject]@{ Tag = $Tag; Dir = $dir; LibDir = $libDir; ZipSha256 = $sha }
}

# --------------------------------------------------------------------------
# CMake helpers
# --------------------------------------------------------------------------

function Get-CMakeCacheValue([string]$CacheFile, [string]$Name) {
    if (-not (Test-Path -LiteralPath $CacheFile)) { return $null }
    $pattern = '^' + [regex]::Escape($Name) + '(:[A-Z_]+)?=(.*)$'
    foreach ($line in [IO.File]::ReadAllLines($CacheFile)) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) { return $m.Groups[2].Value }
    }
    return $null
}

function Get-StaleReason([string]$BuildDir, [string]$Src, [string]$SkiaPath, [string]$Cl) {
    $cache = Join-Path $BuildDir 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cache)) { return $null }
    $cachedSrc = Get-CMakeCacheValue $cache 'CMAKE_HOME_DIRECTORY'
    if (-not (Test-SamePath $cachedSrc $Src)) { return "it was configured for another source folder ($cachedSrc)" }
    $gen = Get-CMakeCacheValue $cache 'CMAKE_GENERATOR'
    if ($gen -ne 'Ninja') { return "it uses another generator ($gen)" }
    $cachedSkia = Get-CMakeCacheValue $cache 'SKIA_DIR'
    if (-not (Test-SamePath $cachedSkia $SkiaPath)) { return "it was configured with another Skia ($cachedSkia)" }
    $cxx = Get-CMakeCacheValue $cache 'CMAKE_CXX_COMPILER'
    if (-not $cxx -or -not (Test-Path -LiteralPath ($cxx -replace '/', '\')) -or -not (Test-SamePath $cxx $Cl)) {
        return "the C++ compiler changed ($cxx)"
    }
    return $null
}

function Get-MinimumCMake([string]$Src) {
    $text = Get-Content -LiteralPath (Join-Path $Src 'CMakeLists.txt') -Raw
    $m = [regex]::Match($text, '(?i)cmake_minimum_required\s*\(\s*VERSION\s+([\d.]+)')
    if ($m.Success) { return [version]$m.Groups[1].Value }
    return [version]'3.16'
}

# --------------------------------------------------------------------------
# Install and Windows integration
# --------------------------------------------------------------------------

function Assert-NotRunning([string]$Exe) {
    $running = @(Get-Process -Name aseprite -ErrorAction SilentlyContinue | Where-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            Test-SamePath $p $Exe
        })
    if ($running.Count -gt 0) {
        Stop-Build "Aseprite is running from $Exe." -Hint @('Close it and re-run.')
    }
}

function Read-InstallInfo([string]$Dir) {
    $marker = Join-Path $Dir $MarkerFile
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    try { return (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json) } catch { return $null }
}

function Copy-AppFiles([string]$BinDir, [string]$Dest, [string]$Src, $Info) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -LiteralPath (Join-Path $BinDir 'aseprite.exe') -Destination (Join-Path $Dest 'aseprite.exe') -Force
    $pdbSrc = Join-Path $BinDir 'aseprite.pdb'
    $pdbDst = Join-Path $Dest 'aseprite.pdb'
    if ($BuildType -ne 'Release' -and (Test-Path -LiteralPath $pdbSrc)) { Copy-Item -LiteralPath $pdbSrc -Destination $pdbDst -Force }
    elseif (Test-Path -LiteralPath $pdbDst) { Remove-Item -LiteralPath $pdbDst -Force }

    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    Invoke-Native -FilePath $robocopy -ArgumentList @((Join-Path $BinDir 'data'), (Join-Path $Dest 'data'), '/MIR', '/XD', '.git', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -OkExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -Activity 'Copying data files'

    $eula = Join-Path $Src 'EULA.txt'
    if (Test-Path -LiteralPath $eula) { Copy-Item -LiteralPath $eula -Destination (Join-Path $Dest 'EULA.txt') -Force }

    $Info | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Dest $MarkerFile) -Encoding UTF8
}

function Test-ForeignFolder([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Dir $MarkerFile)) { return $false }
    return (@(Get-ChildItem -LiteralPath $Dir -Force).Count -gt 0)
}

function Install-Portable([string]$BinDir, [string]$Dest, [string]$Src, $Info) {
    $exe = Join-Path $Dest 'aseprite.exe'
    if ((Test-ForeignFolder $Dest) -and -not $Force) {
        Stop-Build "Folder '$Dest' already has files and wasn't created by this script." -Hint @('Choose another folder with -InstallDir, or pass -Force to use it anyway.')
    }
    Assert-NotRunning $exe
    Copy-AppFiles $BinDir $Dest $Src $Info

    $ini = Join-Path $Dest 'aseprite.ini'
    if ($Portable) {
        if (-not (Test-Path -LiteralPath $ini)) { [IO.File]::WriteAllText($ini, '') }
        Write-Info 'Portable mode: settings and extensions are stored next to aseprite.exe.'
    } elseif (Test-Path -LiteralPath $ini) {
        Write-Warn "aseprite.ini exists in $Dest, so this copy still runs portable. Delete it to use %APPDATA%\Aseprite."
    }
    return $exe
}

# --------------------------------------------------------------------------
# Inno Setup installer
# --------------------------------------------------------------------------

$InnoScriptTemplate = @'
#ifndef AppVersion
  #error Compile this through build-aseprite.ps1 -Installer
#endif
#define AppName "Aseprite"
#define ExeName "aseprite.exe"

[Setup]
AppId={@APPID@
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} (built from source)
UninstallDisplayName={#AppName} {#AppVersion} (built from source)
AppPublisher=Local build of Aseprite by Igara Studio S.A.
AppPublisherURL=https://www.aseprite.org/
AppComments=Compiled from the official source for personal use under the Aseprite EULA. Do not redistribute.
VersionInfoVersion={#NumericVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} {#AppVersion} setup (built from source)
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
#ifdef EulaFile
LicenseFile={#EulaFile}
#endif
#ifdef IconFile
SetupIconFile={#IconFile}
#endif
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
#if Arch == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "assocsprite"; Description: "Open .ase and .aseprite files with Aseprite"; GroupDescription: "File associations:"
Name: "assocext"; Description: "Install .aseprite-extension files with Aseprite"; GroupDescription: "File associations:"

[InstallDelete]
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Sprite"; ValueType: string; ValueName: ""; ValueData: "Aseprite Sprite"; Flags: uninsdeletekey; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Sprite\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#ExeName}"",1"; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Sprite\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#ExeName}"" ""%1"""; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\.ase"; Flags: uninsdeletekeyifempty; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\.ase\OpenWithProgids"; ValueType: string; ValueName: "Aseprite.SelfBuilt.Sprite"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\.ase"; ValueType: string; ValueName: ""; ValueData: "Aseprite.SelfBuilt.Sprite"; Flags: uninsdeletevalue; Tasks: assocsprite; Check: IsUnclaimed('.ase')
Root: HKA; Subkey: "Software\Classes\.aseprite"; Flags: uninsdeletekeyifempty; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\.aseprite\OpenWithProgids"; ValueType: string; ValueName: "Aseprite.SelfBuilt.Sprite"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assocsprite
Root: HKA; Subkey: "Software\Classes\.aseprite"; ValueType: string; ValueName: ""; ValueData: "Aseprite.SelfBuilt.Sprite"; Flags: uninsdeletevalue; Tasks: assocsprite; Check: IsUnclaimed('.aseprite')
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Extension"; ValueType: string; ValueName: ""; ValueData: "Aseprite Extension"; Flags: uninsdeletekey; Tasks: assocext
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Extension\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#ExeName}"",2"; Tasks: assocext
Root: HKA; Subkey: "Software\Classes\Aseprite.SelfBuilt.Extension\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#ExeName}"" ""%1"""; Tasks: assocext
Root: HKA; Subkey: "Software\Classes\.aseprite-extension"; Flags: uninsdeletekeyifempty; Tasks: assocext
Root: HKA; Subkey: "Software\Classes\.aseprite-extension\OpenWithProgids"; ValueType: string; ValueName: "Aseprite.SelfBuilt.Extension"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assocext
Root: HKA; Subkey: "Software\Classes\.aseprite-extension"; ValueType: string; ValueName: ""; ValueData: "Aseprite.SelfBuilt.Extension"; Flags: uninsdeletevalue; Tasks: assocext; Check: IsUnclaimed('.aseprite-extension')

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  OverwriteConfirmed: Boolean;

procedure InitializeWizard;
begin
  WizardForm.TasksList.Offset := WizardForm.TasksList.Offset + ScaleX(3);
end;

function IsUnclaimed(Ext: String): Boolean;
var
  Current: String;
begin
  if RegQueryStringValue(HKCR, Ext, '', Current) then
    Result := (Current = '') or (Pos('Aseprite.SelfBuilt.', Current) = 1)
  else
    Result := True;
end;

function IsForeignAseprite(Dir: String): Boolean;
begin
  Dir := AddBackslash(Dir);
  Result := FileExists(Dir + '{#ExeName}') and not FileExists(Dir + 'build-info.json');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and IsForeignAseprite(WizardDirValue) then
  begin
    Result := MsgBox('This folder contains an Aseprite that this setup did not install (for example the official release). Installing here would overwrite it.'#13#10#13#10'Install here anyway?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    OverwriteConfirmed := Result;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if IsForeignAseprite(ExpandConstant('{app}')) and not OverwriteConfirmed then
    Result := 'The destination folder contains an Aseprite that this setup did not install. Choose another folder (e.g. /DIR="...").';
end;
'@

function Find-InnoSetup {
    $candidates = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }
    foreach ($major in @('7', '6')) {
        foreach ($hive in @('HKLM:\SOFTWARE\WOW6432Node', 'HKLM:\SOFTWARE', 'HKCU:\SOFTWARE')) {
            $props = Get-ItemProperty -LiteralPath "$hive\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup $($major)_is1" -ErrorAction SilentlyContinue
            if ($props -and $props.PSObject.Properties['InstallLocation'] -and $props.InstallLocation) {
                $candidates.Add((Join-Path $props.InstallLocation 'ISCC.exe'))
            }
        }
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
            if ($root) { $candidates.Add((Join-Path $root "Inno Setup $major\ISCC.exe")) }
        }
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-InnoVersion([string]$Iscc) {
    $dir = Split-Path -Parent $Iscc
    foreach ($major in @('7', '6')) {
        foreach ($hive in @('HKCU:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKLM:\SOFTWARE')) {
            $props = Get-ItemProperty -LiteralPath "$hive\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup $($major)_is1" -ErrorAction SilentlyContinue
            if (-not $props -or -not $props.PSObject.Properties['InstallLocation'] -or -not $props.PSObject.Properties['DisplayVersion']) { continue }
            if (-not (Test-SamePath ([string]$props.InstallLocation) $dir)) { continue }
            $m = [regex]::Match([string]$props.DisplayVersion, '\d+\.\d+(\.\d+)?')
            if ($m.Success) { return [version]$m.Value }
        }
    }
    $vi = (Get-Item -LiteralPath $Iscc).VersionInfo
    foreach ($s in @($vi.ProductVersion, $vi.FileVersion)) {
        $m = [regex]::Match([string]$s, '\d+\.\d+(\.\d+)?')
        if ($m.Success -and ([version]$m.Value).Major -gt 0) { return [version]$m.Value }
    }
    return $null
}

function ConvertTo-NumericVersion([string]$Text) {
    $m = [regex]::Match([string]$Text, '^v?(\d+(\.\d+){1,3})')
    if (-not $m.Success) { return '0.0.0.0' }
    $parts = @($m.Groups[1].Value.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return ($parts -join '.')
}

function New-AsepriteInstaller {
    param([string]$Iscc, [string]$BinDir, [string]$Src, $Info, [string]$DisplayVersion, [string]$FileLabel)
    $dist = Join-Path $script:WorkRoot 'dist'
    $setup = Join-Path $dist "Aseprite-$FileLabel-$Arch-setup.exe"
    if (Test-Path -LiteralPath $setup) {
        try { ([IO.File]::Open($setup, 'Open', 'ReadWrite', 'None')).Dispose() }
        catch { Stop-Build "$([IO.Path]::GetFileName($setup)) is in use, probably by a setup window that is still open." -Hint @('Close the Aseprite setup wizard, then re-run.') }
    }
    $stage = Join-Path $dist ("stage\{0}-{1}" -f $Arch, $BuildType)
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Copy-AppFiles $BinDir $stage $Src $Info

    $iss = Join-Path $dist 'aseprite.iss'
    [IO.File]::WriteAllText($iss, $InnoScriptTemplate.Replace('@APPID@', $InstallerAppId), (New-Object System.Text.UTF8Encoding($true)))

    $baseName = "Aseprite-$FileLabel-$Arch-setup"
    $isccArgs = @(
        "/O$dist", "/F$baseName",
        "/DAppVersion=$DisplayVersion",
        "/DNumericVersion=$(ConvertTo-NumericVersion $DisplayVersion)",
        "/DArch=$Arch",
        "/DStageDir=$stage"
    )
    $eula = Join-Path $stage 'EULA.txt'
    if (Test-Path -LiteralPath $eula) { $isccArgs += "/DEulaFile=$eula" }
    $icon = Join-Path $Src 'data\icons\ase.ico'
    if (Test-Path -LiteralPath $icon) { $isccArgs += "/DIconFile=$icon" }
    $isccArgs += $iss
    Invoke-Native -FilePath $Iscc -ArgumentList $isccArgs -Activity 'Compiling installer'

    if (-not (Test-Path -LiteralPath $setup)) { Stop-Build "Inno Setup finished but $setup is missing." }
    return $setup
}

function Invoke-AsepriteInstaller([string]$Setup, [switch]$Silent) {
    $log = Join-Path (Split-Path -Parent $Setup) 'install.log'
    $setupArgs = @("/LOG=`"$log`"")
    if ($Silent) { $setupArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS') + $setupArgs }
    Write-BuildLog "run installer: $Setup $($setupArgs -join ' ')"
    $p = Start-Process -FilePath $Setup -ArgumentList $setupArgs -PassThru
    $null = $p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
    Write-BuildLog "installer exit code $code"
    switch ($code) {
        0 { return }
        8 { Write-Warn 'Setup finished but Windows needs a restart to complete it.'; return }
        { $_ -in @(2, 5) } { Stop-Build 'The installer was cancelled.' -Hint @("You can run it again later: $Setup") }
        7 { Stop-Build 'The installer refused the destination folder.' -Hint @("See $log") }
        default { Stop-Build "The installer failed (exit code $code)." -Hint @("Installer log: $log") }
    }
}

function Get-SetupInstall {
    foreach ($hive in @('HKCU:\SOFTWARE', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
        $props = Get-ItemProperty -LiteralPath "$hive\Microsoft\Windows\CurrentVersion\Uninstall\$($InstallerAppId)_is1" -ErrorAction SilentlyContinue
        if ($props -and $props.PSObject.Properties['InstallLocation'] -and $props.InstallLocation) {
            $scope = if ($hive -like 'HKCU*') { 'you' } else { 'all users' }
            return [pscustomobject]@{ Location = ([string]$props.InstallLocation).TrimEnd('\'); Version = [string]$props.DisplayVersion; Scope = $scope }
        }
    }
    return $null
}

function Get-DllDependencies([string]$Exe) {
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if (-not $dumpbin) { return $null }
    $out = Get-NativeOutput -FilePath $dumpbin.Source -ArgumentList @('/nologo', '/dependents', $Exe) -AllowFailure
    $dlls = @(@($out) | ForEach-Object {
            $m = [regex]::Match([string]$_, '^\s+(\S+\.dll)\s*$', 'IgnoreCase')
            if ($m.Success) { $m.Groups[1].Value }
        } | Select-Object -Unique)
    $sysDir = Join-Path $env:SystemRoot 'System32'
    if ($Arch -eq 'x86' -and [Environment]::Is64BitOperatingSystem) { $sysDir = Join-Path $env:SystemRoot 'SysWOW64' }
    $foreign = @(foreach ($d in $dlls) {
            $isOs = $false
            $p = Join-Path $sysDir $d
            if (Test-Path -LiteralPath $p) {
                try {
                    $sig = Get-AuthenticodeSignature -LiteralPath $p
                    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
                        $isOs = $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation'
                    }
                } catch { }
            }
            if (-not $isOs) { $d }
        })
    return [pscustomobject]@{ All = $dlls; Foreign = $foreign }
}

function Test-AsepriteExe([string]$Exe) {
    $out = Join-Path ([IO.Path]::GetTempPath()) ('aseprite-version-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList @('--batch', '--version') -RedirectStandardOutput $out -NoNewWindow -PassThru
        $null = $p.Handle
        if (-not $p.WaitForExit(60000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; Text = 'timed out after 60 s' }
        }
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = ([string](Get-Content -LiteralPath $out -Raw)).Trim() }
        return [pscustomobject]@{ Ok = ($p.ExitCode -eq 0 -and $text -match 'Aseprite'); Text = $text; ExitCode = $p.ExitCode }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------

function Show-Versions([string]$InstallPath) {
    $script:GitExe = Find-Git
    $refs = Get-RemoteRefs
    $stable = @(Get-SortedTags $refs.Tags)
    $pre = @(Get-SortedTags $refs.Tags -IncludePrerelease | Where-Object { $_.Prerelease } | Select-Object -First 1)
    Write-Host ''
    if ($stable.Count -gt 0) { Write-Host "Latest stable:      $($stable[0].Tag)" -ForegroundColor Green }
    if ($pre.Count -gt 0) { Write-Host "Latest pre-release: $($pre[0].Tag)" }
    Write-Host "Recent stable:      $((@($stable | Select-Object -First 12 | ForEach-Object { $_.Tag })) -join ', ')"
    if ($refs.Branches.Count -gt 0) {
        $branches = @('main', 'beta') | Where-Object { $refs.Branches.ContainsKey($_) }
        $others = @($refs.Branches.Keys | Where-Object { $_ -notin @('main', 'beta') } | Sort-Object)
        Write-Host "Branches:           $((@($branches) + $others) -join ', ')"
    }
    Write-Host ''
    $found = @()
    $setupInst = Get-SetupInstall
    if ($setupInst) { $found += [pscustomobject]@{ Label = 'Installed'; Path = "$($setupInst.Location) (for $($setupInst.Scope))"; Info = (Read-InstallInfo $setupInst.Location) } }
    $portableInfo = Read-InstallInfo $InstallPath
    if ($portableInfo) { $found += [pscustomobject]@{ Label = 'Portable copy'; Path = $InstallPath; Info = $portableInfo } }
    if ($found.Count -eq 0) { Write-Host "Installed:          nothing (no setup install, no portable copy at $InstallPath)" }
    foreach ($f in $found) {
        $line = '{0,-20}' -f ($f.Label + ':')
        if ($f.Info) {
            $sha = [string]$f.Info.commit
            if ($sha.Length -gt 10) { $sha = $sha.Substring(0, 10) }
            Write-Host ('{0}{1} ({2} {3}, commit {4}, built {5})' -f $line, $f.Info.version, $f.Info.buildType, $f.Info.arch, $sha, $f.Info.builtAt)
        } else {
            Write-Host ('{0}{1}' -f $line, $setupInst.Version)
        }
        Write-Host "                    $($f.Path)"
        if ($f.Info -and $f.Info.refKind -eq 'tag' -and $stable.Count -gt 0) {
            $cur = Get-TagInfo $f.Info.ref
            if ($cur -and -not $cur.Prerelease -and $cur.Key -lt $stable[0].Key) {
                Write-Host "Update available:   $($stable[0].Tag)  (re-run the script to update)" -ForegroundColor Yellow
            }
        }
    }
    Write-Host ''
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

function Invoke-Main {
    $total = [Diagnostics.Stopwatch]::StartNew()

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Stop-Build 'This script builds Aseprite on Windows.' -Hint @('On macOS/Linux use the official ./build.sh in the Aseprite repository.')
    }

    $root = $WorkDir
    if (-not $root) { $root = $PSScriptRoot }
    if (-not $root) { $root = (Get-Location).Path }
    $script:WorkRoot = Resolve-FullPath $root
    $src = if ($SourceDir) { Resolve-FullPath $SourceDir } else { Join-Path $script:WorkRoot 'src' }
    $installPath = if ($InstallDir) { Resolve-FullPath $InstallDir } else { Join-Path $script:WorkRoot 'Aseprite' }

    if ($ListVersions) { Show-Versions $installPath; return }

    $wantInstaller = $Installer -or $RunInstaller -or $SilentInstall
    $wantPortable = -not $NoInstall -and (-not $wantInstaller -or $PSBoundParameters.ContainsKey('InstallDir'))

    New-Item -ItemType Directory -Force -Path $script:WorkRoot | Out-Null
    Initialize-Log $script:WorkRoot

    Write-Host ''
    Write-Host "Aseprite build script v$ScriptVersion" -ForegroundColor White
    Write-Host 'Builds from official source for personal use. The Aseprite EULA forbids' -ForegroundColor DarkGray
    Write-Host 'distributing the resulting binaries: share the script, not the build.' -ForegroundColor DarkGray

    if ($SourceMode -eq 'Zip' -and $Version -eq 'local') {
        Stop-Build '-Version local builds a git checkout; it cannot be combined with -SourceMode Zip.'
    }
    if ($SourceMode -eq 'Zip' -and $FullHistory) { Write-Warn '-FullHistory is ignored with -SourceMode Zip.' }
    if ($RunInstaller -and $SilentInstall) { Stop-Build 'Use either -RunInstaller (interactive) or -SilentInstall, not both.' }
    if ($Portable -and -not $wantPortable) {
        Write-Warn '-Portable applies to the portable copy, which this run does not make (add -InstallDir to make one).'
    }

    if ($wantPortable -and -not $Force -and (Test-ForeignFolder $installPath)) {
        Stop-Build "Folder '$installPath' already has files and wasn't created by this script." -Hint @('Choose another folder with -InstallDir, or pass -Force to use it anyway.')
    }

    Start-Phase 'Checking prerequisites'

    Write-Info "Work folder: $script:WorkRoot"
    if ($script:WorkRoot.Length -gt 80) {
        Write-Warn 'The work folder path is long; MSVC can fail on very long paths. A short path like C:\asebuild is safest.'
    }
    if ($script:WorkRoot -match '[^\x20-\x7E]') {
        Write-Warn 'The work folder path has non-ASCII characters, which some build tools handle badly.'
    }
    try {
        $drive = New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($script:WorkRoot))
        $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $needGb = if ($BuildType -eq 'Debug') { 6 } else { 2 }
        if ($freeGb -lt $needGb) { Write-Warn "Only $freeGb GB free on $($drive.Name); a $BuildType build needs about $needGb GB." }
        else { Write-Detail "Disk: $freeGb GB free on $($drive.Name)" }
    } catch { }
    $osArch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $osArch = $env:PROCESSOR_ARCHITEW6432 }
    if ($osArch -eq 'ARM64') { Write-Detail "Windows on ARM: building $Arch (runs under emulation; no ARM64 Skia exists for Windows)." }

    $needGit = ($SourceMode -eq 'Git') -or $Translations
    $script:GitExe = Find-Git
    $vs = Find-VisualStudio

    $missing = @()
    if ($needGit -and -not $script:GitExe) { $missing += 'Git' }
    if (-not $vs) { $missing += 'Visual Studio C++ tools' }
    if ($missing.Count -gt 0 -and $InstallPrereqs) {
        if (-not $script:GitExe -and $needGit) {
            Install-WithWinget 'Git' 'Git.Git'
            $script:GitExe = Find-Git
        }
        if (-not $vs) {
            Write-Info 'Visual Studio 2022 Build Tools will be installed; a UAC prompt and an installer window will appear.'
            Install-WithWinget 'Visual Studio 2022 Build Tools' 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
            $vs = Find-VisualStudio
        }
    }
    if ($needGit -and -not $script:GitExe) {
        Stop-Build 'Git was not found.' -Hint @('Re-run with -InstallPrereqs, or install it: winget install Git.Git', 'Or use -SourceMode Zip (no Git needed; tags only, no translations).')
    }
    if (-not $vs) {
        $which = if ($VsVersion -eq 'latest') { 'Visual Studio' } else { "Visual Studio $VsVersion" }
        Stop-Build "$which with the C++ tools was not found." -Hint @(
            'Re-run with -InstallPrereqs, or install "Desktop development with C++" (with a Windows SDK) from the Visual Studio Installer.',
            'Free option: https://visualstudio.microsoft.com/visual-cpp-build-tools/')
    }
    if ($script:GitExe) {
        $gitVer = @(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('--version') -AllowFailure) | Select-Object -First 1
        Write-Info "Git:      $gitVer"
        Enable-GitLongPaths
    }

    $alreadyInDevShell = $env:VSCMD_VER -and $env:VCToolsInstallDir -and $env:VSINSTALLDIR -and
        (Test-SamePath $env:VSINSTALLDIR $vs.Path) -and ($env:VSCMD_ARG_TGT_ARCH -eq $Arch)
    if ($alreadyInDevShell) {
        Write-Detail 'Reusing the current Visual Studio developer environment.'
    } else {
        Import-VsEnvironment $vs
    }
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if (-not $cl) { Stop-Build 'cl.exe is not available after loading the Visual Studio environment.' }
    $clPath = $cl.Source
    $sdk = ([string]$env:WindowsSDKVersion).TrimEnd('\')
    if (-not $sdk) {
        Stop-Build 'No Windows SDK found.' -Hint @('Add a Windows 10/11 SDK in the Visual Studio Installer (Individual components).')
    }
    Write-Info "Compiler: MSVC $env:VCToolsVersion ($($vs.Name) $($vs.Version)), target $Arch"
    Write-Info "SDK:      Windows SDK $sdk"

    $cmake = Find-CMake
    $ninja = Find-Ninja
    if ((-not $cmake -or -not $ninja) -and $InstallPrereqs) {
        if (-not $cmake) { Install-WithWinget 'CMake' 'Kitware.CMake'; $cmake = Find-CMake }
        if (-not $ninja) { Install-WithWinget 'Ninja' 'Ninja-build.Ninja'; $ninja = Find-Ninja }
    }
    if (-not $cmake) { Stop-Build 'CMake was not found.' -Hint @('Re-run with -InstallPrereqs, or: winget install Kitware.CMake') }
    if (-not $ninja) { Stop-Build 'Ninja was not found.' -Hint @('Re-run with -InstallPrereqs, or: winget install Ninja-build.Ninja') }
    $cmakeVer = Get-ToolVersion $cmake
    $ninjaVer = Get-ToolVersion $ninja
    Write-Info "CMake:    $cmakeVer  ($cmake)"
    Write-Info "Ninja:    $ninjaVer  ($ninja)"

    $iscc = $null
    if ($wantInstaller) {
        $iscc = Find-InnoSetup
        if (-not $iscc -and $InstallPrereqs) {
            Install-WithWinget 'Inno Setup' 'JRSoftware.InnoSetup'
            $iscc = Find-InnoSetup
        }
        if (-not $iscc) {
            Stop-Build 'Inno Setup was not found (needed for -Installer).' -Hint @('Re-run with -InstallPrereqs, or: winget install JRSoftware.InnoSetup', 'Or drop -Installer to get a portable copy instead.')
        }
        $innoVer = Get-InnoVersion $iscc
        if ($innoVer -and $innoVer -lt $MinInnoVersion) {
            Stop-Build "Inno Setup $innoVer is too old; $MinInnoVersion or newer is needed." -Hint @('Update it: winget upgrade JRSoftware.InnoSetup')
        }
        if ($innoVer) { Write-Info "Inno:     $innoVer  ($iscc)" }
        else { Write-Warn "Could not tell which Inno Setup version $iscc is; $MinInnoVersion or newer is needed." }
    }

    $ignorePaths = @($env:Path -split ';' | Where-Object {
            $hasGcc = $false
            if ($_) { try { $hasGcc = Test-Path -LiteralPath (Join-Path $_.Trim('"') 'gcc.exe') } catch { } }
            $hasGcc
        } | ForEach-Object { $_.Trim('"') } | Select-Object -Unique)
    if ($ignorePaths.Count -gt 0) { Write-Detail "Ignoring GCC toolchains on PATH: $($ignorePaths -join '; ')" }

    Start-Phase 'Resolving version'
    $ref = Resolve-SourceRef $Version
    if ($SourceMode -eq 'Zip' -and $ref.Kind -ne 'tag') {
        Stop-Build "-SourceMode Zip only works with release tags, not the $($ref.Kind) '$($ref.Name)'." -Hint @('Use -SourceMode Git for branches and commits.')
    }
    switch ($ref.Kind) {
        'tag' { Write-Info "Version: $($ref.Name)" }
        'branch' { Write-Info "Branch: $($ref.Name)" }
        'commit' { Write-Info "Commit: $($ref.Name)" }
        'local' { Write-Info "Local source: $src" }
    }

    Start-Phase 'Getting source code'
    if ($SourceMode -eq 'Zip') {
        $src = Get-ZipSource $ref.Name
    } elseif ($ref.Kind -eq 'local') {
        if (-not (Test-Path -LiteralPath (Join-Path $src 'CMakeLists.txt'))) {
            Stop-Build "No Aseprite source in $src." -Hint @('Pass your checkout with -SourceDir, or omit -Version local to fetch it.')
        }
        if (Test-Path -LiteralPath (Join-Path $src '.git')) {
            $code = Invoke-Git @('-C', $src, '-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--recursive', '--jobs', '8') -Activity 'Initializing submodules' -AllowFailure
            if ($code -ne 0) { Write-Warn 'Could not update submodules; building with what is checked out.' }
        }
    } else {
        Sync-GitSource $src $ref
    }
    foreach ($required in @('EULA.txt', 'laf\CMakeLists.txt', 'src\CMakeLists.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $required))) {
            Stop-Build "The source in $src is incomplete (missing $required)." -Hint @('Re-run with -Force to repair the checkout.')
        }
    }

    $commit = $null
    $describe = $ref.Name
    if (Test-Path -LiteralPath (Join-Path $src '.git')) {
        $commit = @(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $src, 'rev-parse', 'HEAD') -AllowFailure) | Select-Object -First 1
        $d = @(Get-NativeOutput -FilePath $script:GitExe -ArgumentList @('-C', $src, 'describe', '--tags', '--always', '--dirty') -AllowFailure) | Select-Object -First 1
        if ($d) { $describe = $d }
    } elseif ($script:RemoteRefs -and $script:RemoteRefs.Tags.ContainsKey($ref.Name)) {
        $commit = $script:RemoteRefs.Tags[$ref.Name]
    }
    Write-Info "Source: $src"
    if ($commit) { Write-Info "Commit: $commit ($describe)" }

    $minCMake = Get-MinimumCMake $src
    if ($cmakeVer -and $cmakeVer -lt $minCMake) {
        Stop-Build "This Aseprite version needs CMake $minCMake or newer (found $cmakeVer)." -Hint @('Update CMake: winget upgrade Kitware.CMake')
    }

    Start-Phase 'Preparing Skia'
    $skiaTag = Get-SkiaTag $src
    $skia = Initialize-Skia $skiaTag
    Write-Info "Skia: $($skia.Tag)  ($($skia.LibDir))"

    Start-Phase 'Configuring (CMake)'
    $buildDir = Join-Path $script:WorkRoot ("build\{0}-{1}" -f $Arch, $BuildType)
    if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
        Write-Info "Deleting $buildDir (-Clean)"
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }
    $stale = Get-StaleReason $buildDir $src $skia.Dir $clPath
    if ($stale) {
        Write-Info "Starting a fresh build tree because $stale."
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }
    $onOff = { param($b) if ($b) { 'ON' } else { 'OFF' } }
    $cfg = @(
        '-S', $src, '-B', $buildDir, '-G', 'Ninja',
        '-Wno-dev', '--no-warn-unused-cli',
        "-DCMAKE_BUILD_TYPE=$BuildType",
        "-DCMAKE_MAKE_PROGRAM=$(ConvertTo-CMakePath $ninja)",
        "-DCMAKE_C_COMPILER=$(ConvertTo-CMakePath $clPath)",
        "-DCMAKE_CXX_COMPILER=$(ConvertTo-CMakePath $clPath)",
        '-DLAF_BACKEND=skia',
        "-DSKIA_DIR=$(ConvertTo-CMakePath $skia.Dir)",
        "-DSKIA_LIBRARY_DIR=$(ConvertTo-CMakePath $skia.LibDir)",
        "-DSKIA_LIBRARY=$(ConvertTo-CMakePath (Join-Path $skia.LibDir 'skia.lib'))",
        "-DENABLE_UPDATER=$(& $onOff (-not $NoUpdateCheck))",
        "-DENABLE_NEWS=$(& $onOff (-not $NoUpdateCheck))",
        "-DENABLE_I18N_STRINGS=$(& $onOff $Translations)",
        "-DENABLE_TESTS=$(& $onOff $Tests)",
        "-DLAF_WITH_TESTS=$(& $onOff $Tests)",
        '-DENABLE_OPENSSL=OFF',
        '-DENABLE_PCREPOSIX=OFF',
        '-DENABLE_PCRE2POSIX=OFF'
    )
    if ($cmakeVer -and $cmakeVer.Major -ge 4) {
        $cfg += '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'
    }
    if ($ignorePaths.Count -gt 0) { $cfg += "-DCMAKE_IGNORE_PATH=$((@($ignorePaths | ForEach-Object { ConvertTo-CMakePath $_ })) -join ';')" }
    if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) {
        $cfg += '-DUPDATE_VERSION_WITH_GIT=OFF'
    }
    if ($CMakeArgs.Count -gt 0) { $cfg += $CMakeArgs; Write-Info "Extra CMake args: $($CMakeArgs -join ' ')" }
    Invoke-Native -FilePath $cmake -ArgumentList $cfg -Activity 'Configuring Aseprite'
    Write-Info "Build tree: $buildDir"

    Start-Phase 'Building'
    $builtExe = Join-Path $buildDir 'bin\aseprite.exe'
    Assert-NotRunning $builtExe
    $buildArgs = @('--build', $buildDir)
    if (-not $Tests) { $buildArgs += @('--target', 'aseprite') }
    if ($Jobs -gt 0) { $buildArgs += @('--parallel', "$Jobs") }
    $jobsText = if ($Jobs -gt 0) { "$Jobs jobs" } else { "$([Environment]::ProcessorCount) threads" }
    Write-Info "Compiling with Ninja ($jobsText); this takes a few minutes on the first run..."
    Invoke-Native -FilePath $cmake -ArgumentList $buildArgs -Display Ninja -Activity "Building Aseprite $describe"
    if (-not (Test-Path -LiteralPath $builtExe)) { Stop-Build "The build finished but $builtExe is missing." }
    $exeSize = [Math]::Round((Get-Item -LiteralPath $builtExe).Length / 1MB, 1)
    Write-Info "Built $builtExe ($exeSize MB)"

    if ($Tests) {
        Start-Phase 'Running unit tests'
        $ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
        if (-not (Test-Path -LiteralPath $ctest)) { $ctest = 'ctest.exe' }
        $ctestArgs = @('--output-on-failure')
        if ($Jobs -gt 0) { $ctestArgs += @('-j', "$Jobs") } else { $ctestArgs += @('-j', "$([Environment]::ProcessorCount)") }
        Push-Location -LiteralPath $buildDir
        try { Invoke-Native -FilePath $ctest -ArgumentList $ctestArgs -Display Show -Activity 'Running tests' }
        finally { Pop-Location }
    }

    Start-Phase 'Verifying'
    $check = Test-AsepriteExe $builtExe
    $reportedVersion = $null
    if ($check.Ok) {
        $reportedVersion = $check.Text
        Write-Info "aseprite --version: $($check.Text)"
    } else {
        Write-Warn "Smoke test inconclusive ($($check.Text)). The build may still be fine; try running it."
    }
    $deps = Get-DllDependencies $builtExe
    $foreignDlls = @()
    if ($deps) {
        $foreignDlls = @($deps.Foreign)
        if ($foreignDlls.Count -eq 0) {
            Write-Info "Self-contained: imports only Windows system DLLs ($(@($deps.All).Count))."
        } else {
            Write-Warn "aseprite.exe depends on non-Windows DLLs: $($foreignDlls -join ', ')."
            Write-Warn 'It works only while that software stays installed. Re-run with -Clean; if it persists, check the log for which library was picked up from your system.'
        }
    }

    $finalExe = $builtExe
    $setupExe = $null
    $binDir = Join-Path $buildDir 'bin'
    if ($wantPortable -or $wantInstaller) {
        $info = [ordered]@{
            version       = if ($reportedVersion) { $reportedVersion -replace '^Aseprite\s+', '' } else { $describe }
            ref           = $ref.Name
            refKind       = $ref.Kind
            commit        = $commit
            sourceMode    = $SourceMode
            buildType     = $BuildType
            arch          = $Arch
            package       = 'portable'
            translations  = [bool]$Translations
            portable      = [bool]$Portable
            updateCheck   = -not $NoUpdateCheck
            skiaTag       = $skia.Tag
            skiaZipSha256 = $skia.ZipSha256
            compiler      = "MSVC $env:VCToolsVersion"
            visualStudio  = "$($vs.Name) $($vs.Version)"
            windowsSdk    = $sdk
            cmake         = "$cmakeVer"
            externalDlls  = $foreignDlls
            builtAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            builtBy       = "build-aseprite.ps1 v$ScriptVersion"
            notice        = 'Personal build compiled under the Aseprite EULA 2(g). Do not distribute (EULA 2(b)).'
        }
    }
    if ($wantPortable) {
        Start-Phase 'Portable copy'
        $finalExe = Install-Portable $binDir $installPath $src $info
        Write-Info "Ready to run: $finalExe"
    } elseif ($wantInstaller -and -not $NoInstall) {
        Write-Detail 'No portable copy in installer mode (pass -InstallDir to make one as well).'
    }

    if ($wantInstaller) {
        Start-Phase 'Creating installer'
        $shortSha = ''
        if ($commit) { $shortSha = $commit.Substring(0, [Math]::Min(7, $commit.Length)) }
        switch ($ref.Kind) {
            'tag' { $displayVersion = $ref.Name.TrimStart('v'); $fileLabel = $ref.Name }
            'branch' { $displayVersion = "$($ref.Name)-$shortSha"; $fileLabel = $displayVersion }
            'commit' { $displayVersion = $shortSha; $fileLabel = $shortSha }
            default { $displayVersion = $describe.TrimStart('v'); $fileLabel = "local-$displayVersion" }
        }
        $fileLabel = $fileLabel -replace '[\\/:*?"<>|\s]', '-'
        $stageInfo = [ordered]@{}
        foreach ($k in $info.Keys) { $stageInfo[$k] = $info[$k] }
        $stageInfo.package = 'installer'
        $stageInfo.portable = $false
        $setupExe = New-AsepriteInstaller -Iscc $iscc -BinDir $binDir -Src $src -Info $stageInfo -DisplayVersion $displayVersion -FileLabel $fileLabel
        Write-Info ('Installer: {0} ({1:N1} MB)' -f $setupExe, ((Get-Item -LiteralPath $setupExe).Length / 1MB))

        if ($RunInstaller -or $SilentInstall) {
            Start-Phase 'Running installer'
            if ($SilentInstall) { Write-Info 'Installing silently (an upgrade keeps your earlier folder and options)...' }
            else { Write-Info 'Follow the setup wizard; this script waits for it to finish.' }
            Invoke-AsepriteInstaller $setupExe -Silent:$SilentInstall
            $inst = Get-SetupInstall
            if ($inst) {
                $finalExe = Join-Path $inst.Location 'aseprite.exe'
                Write-Info "Installed for $($inst.Scope): $($inst.Location)"
            }
        }
    }
    Complete-Phase

    $total.Stop()
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host " Aseprite $describe built in $(Format-Duration $total.Elapsed)" -ForegroundColor Green
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host "  Run:       $finalExe"
    if ($setupExe) { Write-Host "  Installer: $setupExe" }
    if ($reportedVersion) { Write-Host "  Version:   $reportedVersion" }
    Write-Host "  Build:     $BuildType $Arch, MSVC $env:VCToolsVersion, Skia $($skia.Tag)"
    Write-Host "  Log:       $script:LogPath"
    Write-Host ''
    foreach ($t in $script:Timings) { Write-Host ('  {0,-24} {1}' -f $t.Step, (Format-Duration $t.Elapsed)) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  For your personal use only: the Aseprite EULA forbids sharing these binaries,' -ForegroundColor DarkGray
    Write-Host '  and that includes the installer.' -ForegroundColor DarkGray
    Write-BuildLog "SUCCESS in $(Format-Duration $total.Elapsed)"

    if ($Run) { Start-Process -FilePath $finalExe -WorkingDirectory (Split-Path -Parent $finalExe) }
}

$exitCode = 0
try {
    Invoke-Main
} catch {
    $exitCode = 1
    Write-Progress -Id 1 -Activity 'build' -Completed
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    foreach ($h in @($script:FailHints)) { if ($h) { Write-Host "  - $h" -ForegroundColor Yellow } }
    Write-BuildLog "FAILED: $($_.Exception.Message)"
    Write-BuildLog ($_.ScriptStackTrace)
    if ($script:LogPath) { Write-Host "  Full log: $script:LogPath" -ForegroundColor DarkGray }
} finally {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
}
exit $exitCode
