<#
.SYNOPSIS
    Installs a curated set of Windows 11 development tools using winget, with a
    local installer cache so repeat provisioning does not re-download.

.DESCRIPTION
    Provisions a fresh Windows 11 development environment by installing one or
    more pieces of software via the Windows Package Manager (winget).

    Designed to run on the built-in Windows PowerShell 5.1 (powershell.exe),
    since PowerShell Core is not present on a fresh Windows install.

    Key behaviours:
      * Bootstraps winget automatically if it is missing.
      * Caches installers locally (default under %LOCALAPPDATA%) keyed by
        package id + version, so a second machine/run reuses the download:
          - Simple apps: cached via "winget download", then installed by running
            the cached installer directly (using the silent switch winget records
            in the sidecar manifest). Falls back to an online "winget install" if
            the cached path fails, so caching can never break an install.
          - Visual Studio: cached as an offline layout (--layout) and installed
            offline (--noWeb).
          - SQL Server: Developer ISO cached once via a direct download (no admin),
            then installed by mounting the ISO and running setup (admin).
      * Extensive logging (timestamped, leveled) plus a full transcript, and
        live progress reporting.

    Only the latest single version of the heavyweight products is supported to
    keep the cache small: Visual Studio Enterprise 2026 and SQL Server 2022
    Developer.

    Supported software keys:
        VisualStudio      Visual Studio Enterprise 2026 (ASP.NET + .NET Desktop)
        SqlServer         SQL Server 2022 Developer Edition
        SSMS              SQL Server Management Studio 22
        NotepadPlusPlus   Notepad++
        VSCode            Visual Studio Code
        GitHubDesktop     GitHub Desktop
        Postman           Postman
        ClaudeDesktop     Claude Desktop
        PowerShell        PowerShell (Core) 7

.PARAMETER Software
    One or more software keys to install. Defaults to all supported software.

.PARAMETER CachePath
    Root folder for the installer cache. Defaults to
    %LOCALAPPDATA%\DevEnvInstaller\Cache.

.PARAMETER RefreshCache
    Ignore any cached installers/media/layout and download fresh copies.

.PARAMETER LogPath
    Full path to the log file. Defaults to a timestamped file under
    %LOCALAPPDATA%\DevEnvInstaller\Logs.

.PARAMETER Force
    Reinstall / repair even if the package is already detected as installed.

.PARAMETER DownloadOnly
    Only populate the cache (download installers / build VS layout / fetch SQL
    media). Nothing is installed. Useful for pre-seeding a shared cache on an
    online machine for later offline installs.

.PARAMETER DryRun
    Show what would be installed (and cache hit/miss) without changing anything.

.EXAMPLE
    .\Install-DevEnvironment.ps1
    Installs every supported tool, populating the cache as it goes.

.EXAMPLE
    .\Install-DevEnvironment.ps1 -Software VSCode, GitHubDesktop, Postman
    Installs only VS Code, GitHub Desktop and Postman.

.EXAMPLE
    .\Install-DevEnvironment.ps1 -CachePath D:\DevCache -DryRun
    Shows the plan and cache state using a custom cache folder.

.NOTES
    Run from an elevated Windows PowerShell prompt. The script will attempt to
    self-elevate if it is not already running as Administrator.
#>

[CmdletBinding()]
param(
    [ValidateSet(
        'VisualStudio',
        'SqlServer',
        'SSMS',
        'NotepadPlusPlus',
        'VSCode',
        'GitHubDesktop',
        'Postman',
        'ClaudeDesktop',
        'PowerShell'
    )]
    [string[]] $Software = @(
        'VisualStudio',
        'SqlServer',
        'SSMS',
        'NotepadPlusPlus',
        'VSCode',
        'GitHubDesktop',
        'Postman',
        'ClaudeDesktop',
        'PowerShell'
    ),

    [string] $CachePath = (Join-Path $env:LOCALAPPDATA 'DevEnvInstaller\Cache'),

    [switch] $RefreshCache,

    [string] $LogPath = (Join-Path $env:LOCALAPPDATA ("DevEnvInstaller\Logs\Install_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [switch] $Force,

    [switch] $DownloadOnly,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Resolve relative -CachePath / -LogPath against the SCRIPT directory (not the
# caller's working directory). This also matters for self-elevation: the elevated
# process starts in system32, so we forward fully-resolved absolute paths.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not [System.IO.Path]::IsPathRooted($CachePath)) {
    $CachePath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $CachePath))
}
if (-not [System.IO.Path]::IsPathRooted($LogPath)) {
    $LogPath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $LogPath))
}
# Ensure the elevated relaunch receives the resolved absolute paths.
if ($PSBoundParameters.ContainsKey('CachePath')) { $PSBoundParameters['CachePath'] = $CachePath }
if ($PSBoundParameters.ContainsKey('LogPath'))   { $PSBoundParameters['LogPath']   = $LogPath }

#==============================================================================
# Logging infrastructure
#==============================================================================

$script:LogDirectory = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
}

function Write-Log {
    <#
        Writes a timestamped, leveled line to both the console (colored) and the
        log file. Every meaningful action in this script flows through here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Message,

        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR', 'DEBUG')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = '{0} [{1,-5}] {2}' -f $timestamp, $Level, $Message

    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }

    $color = switch ($Level) {
        'STEP'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-LogSection {
    param([string] $Title)
    $bar = '=' * 70
    Write-Log $bar 'STEP'
    Write-Log "  $Title" 'STEP'
    Write-Log $bar 'STEP'
}

function Invoke-LoggedNative {
    <#
        Runs a native executable, streams its output to the console, and tees a
        copy of every line into the log file. Returns the process exit code.
    #>
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Write-Log ("> {0} {1}" -f $FilePath, ($Arguments -join ' ')) 'DEBUG'

    & $FilePath @Arguments 2>&1 | ForEach-Object {
        $text = $_.ToString()
        Write-Host $text
        try { Add-Content -LiteralPath $LogPath -Value ("           | $text") -Encoding UTF8 } catch { }
    }
    return $LASTEXITCODE
}

#==============================================================================
# Environment helpers
#==============================================================================

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    # IMPORTANT: the caller must pass the *script's* $PSBoundParameters. Inside this
    # function, the automatic $PSBoundParameters refers to the function's own (empty)
    # bound parameters, so relying on it here would silently forward nothing and the
    # elevated run would fall back to all defaults.
    param([System.Collections.IDictionary] $BoundParameters)

    if (-not $PSCommandPath) {
        throw 'Cannot self-elevate: script path is unknown. Re-run from an elevated prompt.'
    }

    # Copy into a mutable hashtable and ensure log + cache paths are forwarded so
    # the elevated run is consistent with this one.
    $fwd = @{}
    if ($BoundParameters) {
        foreach ($k in $BoundParameters.Keys) { $fwd[$k] = $BoundParameters[$k] }
    }
    if (-not $fwd.ContainsKey('LogPath'))   { $fwd['LogPath']   = $LogPath }
    if (-not $fwd.ContainsKey('CachePath')) { $fwd['CachePath'] = $CachePath }

    # Forwarding parameters to an elevated process is surprisingly fragile:
    # "powershell -File" does NOT reliably reconstruct array parameters (a
    # comma/space list binds as a single element or spills into positional
    # parameters), and "-Verb RunAs" mishandles array -ArgumentList values.
    # Building a real PowerShell command and passing it via -EncodedCommand sidesteps
    # all of that: the command (with a genuine array literal) is preserved exactly,
    # and the base64 payload is a single space-free token.
    $parts = @("& `"$PSCommandPath`"")
    foreach ($entry in $fwd.GetEnumerator()) {
        $key   = $entry.Key
        $value = $entry.Value
        if ($value -is [switch]) {
            if ($value.IsPresent) { $parts += "-$key" }
        }
        elseif ($value -is [System.Array]) {
            $elements = ($value | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            $parts += "-$key @($elements)"
        }
        else {
            $parts += "-$key '" + ($value -replace "'", "''") + "'"
        }
    }

    $command  = $parts -join ' '
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Write-Log 'Administrator rights are required. Relaunching elevated...' 'WARN'
    Write-Log "Relaunch command: $command" 'DEBUG'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

function Get-WingetCommand {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidate = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.FullName }

    $pkg = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }

    return $null
}

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

#==============================================================================
# winget bootstrap
#==============================================================================

function Install-WingetViaModule {
    Write-Log 'Attempting winget bootstrap via Microsoft.WinGet.Client module...' 'STEP'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Write-Log 'Installing NuGet package provider...' 'INFO'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }

        if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }

        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            Write-Log 'Installing Microsoft.WinGet.Client module from PSGallery...' 'INFO'
            Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -Confirm:$false
        }

        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Log 'Running Repair-WinGetPackageManager...' 'INFO'
        Repair-WinGetPackageManager -ErrorAction Stop
        Write-Log 'Module-based bootstrap completed.' 'OK'
        return $true
    }
    catch {
        Write-Log "Module-based bootstrap failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Install-WingetViaDownload {
    Write-Log 'Attempting winget bootstrap via direct download (Add-AppxPackage)...' 'STEP'
    try {
        $arch = if ([Environment]::Is64BitOperatingSystem) {
            if ($env:PROCESSOR_ARCHITECTURE -match 'ARM') { 'arm64' } else { 'x64' }
        } else { 'x86' }
        Write-Log "Detected architecture: $arch" 'INFO'

        $work = Join-Path $env:TEMP ("winget-bootstrap-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        $downloads = @(
            @{ Name = 'VCLibs';       Url = "https://aka.ms/Microsoft.VCLibs.$arch.14.00.Desktop.appx"; File = "VCLibs.$arch.appx" },
            @{ Name = 'AppInstaller'; Url = 'https://aka.ms/getwinget'; File = 'AppInstaller.msixbundle' }
        )

        foreach ($d in $downloads) {
            $dest = Join-Path $work $d.File
            Write-Log "Downloading $($d.Name) from $($d.Url)" 'INFO'
            Invoke-WebRequest -Uri $d.Url -OutFile $dest -UseBasicParsing
        }

        Write-Log 'Downloading Microsoft.UI.Xaml dependency (NuGet)...' 'INFO'
        $xamlNupkg = Join-Path $work 'uixaml.zip'
        Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6' -OutFile $xamlNupkg -UseBasicParsing
        $xamlExtract = Join-Path $work 'uixaml'
        Expand-Archive -Path $xamlNupkg -DestinationPath $xamlExtract -Force
        $xamlAppx = Get-ChildItem -Path (Join-Path $xamlExtract "tools\AppX\$arch\Release") -Filter '*.appx' -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($xamlAppx) {
            Write-Log "Installing dependency: $($xamlAppx.Name)" 'INFO'
            Add-AppxPackage -Path $xamlAppx.FullName -ErrorAction SilentlyContinue
        }

        Write-Log 'Installing dependency: VCLibs' 'INFO'
        Add-AppxPackage -Path (Join-Path $work "VCLibs.$arch.appx") -ErrorAction SilentlyContinue

        Write-Log 'Installing App Installer (winget) bundle...' 'INFO'
        Add-AppxPackage -Path (Join-Path $work 'AppInstaller.msixbundle') -ErrorAction Stop

        Write-Log 'Download-based bootstrap completed.' 'OK'
        return $true
    }
    catch {
        Write-Log "Download-based bootstrap failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Initialize-Winget {
    <#
        Ensures winget is available, installing it if necessary. Returns the path
        to the winget executable, or throws if it cannot be made available.
    #>
    $existing = Get-WingetCommand
    if ($existing) {
        Write-Log "winget already present: $existing" 'OK'
        return $existing
    }

    Write-Log 'winget was not found. Bootstrapping the Windows Package Manager...' 'WARN'
    Initialize-Tls

    try {
        Write-Log 'Attempting to re-register existing App Installer package...' 'INFO'
        Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register `
                    "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
            }
    } catch { }

    if (Get-WingetCommand) { Write-Log 'winget became available after re-register.' 'OK'; return (Get-WingetCommand) }

    if ((Install-WingetViaModule)   -and (Get-WingetCommand)) { return (Get-WingetCommand) }
    if ((Install-WingetViaDownload) -and (Get-WingetCommand)) { return (Get-WingetCommand) }

    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    $final = Get-WingetCommand
    if ($final) { return $final }

    throw 'Failed to bootstrap winget. Install "App Installer" from the Microsoft Store and re-run.'
}

#==============================================================================
# Cache + download helpers
#==============================================================================

function ConvertTo-SafeName {
    param([string] $Name)
    return ($Name -replace '[^\w.+-]', '_')
}

function Save-CachedFile {
    <#
        Downloads a URL to a fixed cache path, skipping the download if the file
        already exists (unless -RefreshCache was specified).
    #>
    param(
        [string] $Url,
        [string] $Path,
        [string] $Description
    )

    if ((Test-Path -LiteralPath $Path) -and -not $RefreshCache) {
        $sizeMB = [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
        Write-Log "Cache hit: $Description already present ($sizeMB MB) -> $Path" 'OK'
        return
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Write-Log "Downloading $Description ..." 'INFO'
    Write-Log "  from $Url" 'DEBUG'
    Write-Log "  to   $Path" 'DEBUG'
    Initialize-Tls
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    $sizeMB = [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
    Write-Log "Downloaded $Description ($sizeMB MB)." 'OK'
}

function Get-WingetTargetVersion {
    <#
        Resolves the version to use for cache keying. Honors a pinned version if
        provided, otherwise queries winget for the latest available version so the
        cache key is version-aware and re-runs reuse the same download.
    #>
    param([string] $WingetExe, [string] $Id, [string] $Pinned)

    if ($Pinned) { return $Pinned }

    try {
        $out = & $WingetExe show --id $Id --exact --source winget --accept-source-agreements 2>$null
        $match = $out | Select-String -Pattern '^\s*Version:\s*(.+)$' | Select-Object -First 1
        if ($match) { return $match.Matches[0].Groups[1].Value.Trim() }
    } catch { }
    return $null
}

function Resolve-CachedInstallerFile {
    <#
        Returns the path to a cached installer file in a directory, if present.
        Ignores the sidecar .yaml manifest that "winget download" writes.
    #>
    param([string] $Directory)

    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    $exts = @('.exe', '.msi', '.msix', '.appx', '.msixbundle')
    return (Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() } |
        Select-Object -First 1 -ExpandProperty FullName)
}

function Find-AnyCachedInstaller {
    <#
        Returns a cached installer for a package across any cached version folder,
        preferring the highest version name. This is what makes a cache hit work
        offline, when winget cannot be queried to resolve the current version.
    #>
    param([string] $IdDir)

    if (-not (Test-Path -LiteralPath $IdDir)) { return $null }
    $dirs = Get-ChildItem -LiteralPath $IdDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $file = Resolve-CachedInstallerFile -Directory $d.FullName
        if ($file) { return $file }
    }
    return $null
}

function Get-SilentSwitchFromManifest {
    <#
        Reads the authoritative silent install switch winget records in the sidecar
        manifest produced by "winget download".
    #>
    param([string] $InstallerFile)

    $yaml = [IO.Path]::ChangeExtension($InstallerFile, '.yaml')
    if (-not (Test-Path -LiteralPath $yaml)) { return $null }

    $line = Get-Content -LiteralPath $yaml |
        Where-Object { $_ -match '^\s*Silent:\s*\S' } |
        Select-Object -First 1
    if ($line) { return ($line -replace '^\s*Silent:\s*', '').Trim() }
    return $null
}

function Get-FallbackSilentSwitch {
    # Last-resort silent switch derived from the installer-type token that
    # "winget download" embeds in the file name (e.g. ..._nullsoft_en-US.exe).
    param([string] $InstallerFile)

    $base  = [IO.Path]::GetFileNameWithoutExtension($InstallerFile)
    $parts = $base -split '_'
    $token = if ($parts.Count -ge 2) { $parts[-2].ToLower() } else { '' }

    switch -regex ($token) {
        'nullsoft' { '/S' }
        'inno'     { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        'burn'     { '/quiet /norestart' }
        'wix'      { '/quiet /norestart' }
        default    { '/S' }
    }
}

function Invoke-LocalInstaller {
    <#
        Installs from a cached installer file. Returns the process exit code.
        Chooses the right mechanism by file type and uses winget's recorded silent
        switch when available.
    #>
    param([string] $File, [string] $OverrideSilent)

    $ext = [IO.Path]::GetExtension($File).TrimStart('.').ToLower()
    Write-Log "Installing from cached file: $File" 'INFO'

    # Clear the mark-of-the-web so silent installs are not blocked by the security
    # zone (common when the cache lives on a shared/network folder).
    try { Unblock-File -LiteralPath $File -ErrorAction SilentlyContinue } catch { }

    switch -regex ($ext) {
        '^msi$' {
            return (Invoke-LoggedNative -FilePath 'msiexec.exe' -Arguments @('/i', $File, '/qn', '/norestart'))
        }
        '^(msix|appx|msixbundle)$' {
            try {
                Add-AppxPackage -Path $File -ErrorAction Stop
                return 0
            } catch {
                Write-Log "Add-AppxPackage failed: $($_.Exception.Message)" 'ERROR'
                return 1
            }
        }
        default {
            if ($OverrideSilent) {
                $silent = $OverrideSilent
                Write-Log "Using catalog silent-switch override: $silent" 'INFO'
            } else {
                $silent = Get-SilentSwitchFromManifest -InstallerFile $File
                if (-not $silent) {
                    $silent = Get-FallbackSilentSwitch -InstallerFile $File
                    Write-Log "No silent switch in manifest; using fallback '$silent'." 'WARN'
                }
            }
            $argArray = @($silent -split '\s+' | Where-Object { $_ })
            Write-Log ("> {0} {1}" -f $File, ($argArray -join ' ')) 'DEBUG'
            $proc = Start-Process -FilePath $File -ArgumentList $argArray -Wait -PassThru
            return $proc.ExitCode
        }
    }
}

function Install-WingetOnline {
    # Fallback path: let winget perform the install end-to-end (it re-downloads).
    param([string] $WingetExe, [string] $Id, [string[]] $ExtraArgs = @())
    $a = @(
        'install', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    ) + $ExtraArgs
    return (Invoke-LoggedNative -FilePath $WingetExe -Arguments $a)
}

function Test-PackageInstalled {
    # Detection only; no '--source winget' so this never tries to reach the network
    # (works offline by matching locally installed packages).
    param([string] $WingetExe, [string] $Id)
    $null = & $WingetExe list --id $Id --exact --disable-interactivity 2>$null
    return ($LASTEXITCODE -eq 0)
}

function ConvertFrom-ExitCode {
    # Maps common installer exit codes to a status + log level.
    param([int] $Code)
    switch ($Code) {
        0           { @{ Status = 'Installed';                   Level = 'OK' } }
        3010        { @{ Status = 'Installed (reboot required)'; Level = 'WARN' } }
        -1978335189 { @{ Status = 'Already up to date';          Level = 'OK' } }
        -1978334675 { @{ Status = 'Installed (reboot required)'; Level = 'WARN' } }
        1641        { @{ Status = 'Installed (reboot initiated)'; Level = 'WARN' } }
        default     { @{ Status = "Failed (exit code $Code)";    Level = 'ERROR' } }
    }
}

#==============================================================================
# Installers (per method)
#==============================================================================

function Show-StepProgress {
    param([int] $Index, [int] $Total, [string] $DisplayName)
    $pct = [int](($Index - 1) / [math]::Max($Total, 1) * 100)
    Write-Progress -Activity 'Installing Windows 11 development environment' `
        -Status ("[{0}/{1}] {2}" -f $Index, $Total, $DisplayName) -PercentComplete $pct -Id 1
    Write-LogSection ("[{0}/{1}] {2}" -f $Index, $Total, $DisplayName)
}

function Install-CachedApp {
    <#
        Method 'winget': cache the installer via "winget download", then install
        by running the cached file directly. Falls back to an online winget
        install if the cache/direct-run path fails.
    #>
    param([string] $WingetExe, [hashtable] $Item, [int] $Index, [int] $Total)

    Show-StepProgress -Index $Index -Total $Total -DisplayName $Item.DisplayName
    Write-Log "Package id : $($Item.Id)" 'INFO'

    # In download-only mode we still want to cache even if the app is installed.
    if (-not $DownloadOnly -and -not $Force -and (Test-PackageInstalled -WingetExe $WingetExe -Id $Item.Id)) {
        Write-Log 'Already installed -> skipping (use -Force to reinstall).' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Skipped (already installed)'; Source = '-' }
    }

    $idDir   = Join-Path $script:AppCacheRoot (ConvertTo-SafeName $Item.Id)
    $version = Get-WingetTargetVersion -WingetExe $WingetExe -Id $Item.Id -Pinned $Item.PinnedVersion
    if ($version) {
        Write-Log "Target version: $version" 'INFO'
    } else {
        Write-Log 'Could not resolve current version (offline?); will reuse any cached copy.' 'WARN'
    }

    # Resolve a cached installer: prefer the exact target version, otherwise fall
    # back to any cached version (this is what enables fully offline re-runs).
    $installer = $null
    $cacheDir  = $null
    if (-not $RefreshCache) {
        if ($version) {
            $cacheDir  = Join-Path $idDir $version
            $installer = Resolve-CachedInstallerFile -Directory $cacheDir
        }
        if (-not $installer) {
            $installer = Find-AnyCachedInstaller -IdDir $idDir
            if ($installer) { $cacheDir = Split-Path -Parent $installer }
        }
    }
    $cacheHit = [bool]$installer

    if ($DryRun) {
        $tail = if ($DownloadOnly) { 'cache only (no install)' } else { 'install' }
        if ($cacheHit) { Write-Log "[DryRun] Cache HIT -> would $tail from $installer" 'WARN' }
        else           { Write-Log "[DryRun] Cache MISS -> would 'winget download' then $tail" 'WARN' }
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'DryRun'; Source = $(if ($cacheHit) { 'Cache' } else { 'Download' }) }
    }

    $source = 'Cache'
    if (-not $cacheHit) {
        $source   = 'Downloaded'
        $verLabel = if ($version) { $version } else { 'latest' }
        $cacheDir = Join-Path $idDir $verLabel
        if (Test-Path -LiteralPath $cacheDir) {
            if ($RefreshCache) { Get-ChildItem -LiteralPath $cacheDir -File | Remove-Item -Force -ErrorAction SilentlyContinue }
        } else {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        Write-Log 'Cache miss -> downloading installer into cache...' 'INFO'
        $dlArgs = @('download', '--id', $Item.Id, '--exact', '--source', 'winget',
                    '--accept-package-agreements', '--accept-source-agreements', '-d', $cacheDir)
        if ($version) { $dlArgs += @('--version', $version) }
        $null = Invoke-LoggedNative -FilePath $WingetExe -Arguments $dlArgs

        $installer = Resolve-CachedInstallerFile -Directory $cacheDir
        if (-not $installer) {
            if ($DownloadOnly) {
                Write-Log 'winget download produced no installer; nothing cached.' 'ERROR'
                return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Failed (no installer cached)'; Source = 'Download' }
            }
            Write-Log 'winget download produced no installer; falling back to online winget install.' 'WARN'
            $code = Install-WingetOnline -WingetExe $WingetExe -Id $Item.Id
            $map  = ConvertFrom-ExitCode -Code $code
            Write-Log $map.Status $map.Level
            return [pscustomobject]@{ Name = $Item.DisplayName; Status = $map.Status; Source = 'Online' }
        }
    } else {
        Write-Log "Cache hit -> $installer" 'OK'
    }

    if ($DownloadOnly) {
        Write-Log 'Download-only: installer is cached, skipping install.' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Cached (download only)'; Source = $source }
    }

    $start = Get-Date
    $code  = Invoke-LocalInstaller -File $installer -OverrideSilent $Item.SilentArgs
    $map   = ConvertFrom-ExitCode -Code $code

    if ($map.Level -eq 'ERROR') {
        Write-Log "Direct install from cache failed (code $code); falling back to online winget install." 'WARN'
        $code = Install-WingetOnline -WingetExe $WingetExe -Id $Item.Id
        $map  = ConvertFrom-ExitCode -Code $code
        $source = 'Online'
    }

    $elapsed = (Get-Date) - $start
    Write-Log ("{0}  [source {1}, elapsed {2:hh\:mm\:ss}]" -f $map.Status, $source, $elapsed) $map.Level
    return [pscustomobject]@{ Name = $Item.DisplayName; Status = $map.Status; Source = $source }
}

function Install-VisualStudioCached {
    <#
        Method 'visualstudio': build (and cache) an offline layout with the
        required workloads, then install offline with --noWeb.
    #>
    param([string] $WingetExe, [hashtable] $Item, [int] $Index, [int] $Total)

    Show-StepProgress -Index $Index -Total $Total -DisplayName $Item.DisplayName
    Write-Log "Package id : $($Item.Id)" 'INFO'

    if (-not $DownloadOnly -and -not $Force -and (Test-PackageInstalled -WingetExe $WingetExe -Id $Item.Id)) {
        Write-Log 'Already installed -> skipping (use -Force to reinstall).' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Skipped (already installed)'; Source = '-' }
    }

    $vsRoot      = Join-Path $script:CacheRoot 'visualstudio'
    $bootstrapper = Join-Path $vsRoot 'vs_enterprise.exe'
    $layout      = Join-Path $vsRoot 'layout'
    $workloadArgs = @(
        '--add', 'Microsoft.VisualStudio.Workload.NetWeb',
        '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktop',
        '--includeRecommended'
    )

    $layoutReady = (Test-Path -LiteralPath $layout) -and
                   ((Get-ChildItem -LiteralPath $layout -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) -and
                   -not $RefreshCache

    if ($DryRun) {
        $tail = if ($DownloadOnly) { 'cache layout only (no install)' } else { 'install offline from layout' }
        if ($layoutReady) { Write-Log "[DryRun] Layout cache HIT -> would $tail ($layout)" 'WARN' }
        else              { Write-Log "[DryRun] Layout cache MISS -> would download bootstrapper and build layout (tens of GB)" 'WARN' }
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'DryRun'; Source = $(if ($layoutReady) { 'Cache' } else { 'Layout build' }) }
    }

    $source = 'Cache'
    if (-not $layoutReady) {
        $source = 'Layout build'
        Save-CachedFile -Url $Item.BootstrapperUrl -Path $bootstrapper -Description 'Visual Studio bootstrapper'

        Write-Log 'Building offline layout (this downloads tens of GB the first time)...' 'INFO'
        $layoutArgs = @('--layout', $layout, '--lang', 'en-US', '--quiet', '--wait') + $workloadArgs
        $lc = Invoke-LoggedNative -FilePath $bootstrapper -Arguments $layoutArgs
        if ($lc -ne 0 -and $lc -ne 3010) {
            Write-Log "Layout build returned exit code $lc; attempting install anyway." 'WARN'
        }
    } else {
        Write-Log "Layout cache hit -> $layout" 'OK'
    }

    if ($DownloadOnly) {
        Write-Log 'Download-only: Visual Studio layout is cached, skipping install.' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Cached (download only)'; Source = $source }
    }

    $layoutBootstrapper = Join-Path $layout 'vs_enterprise.exe'
    $installExe = if (Test-Path -LiteralPath $layoutBootstrapper) { $layoutBootstrapper } else { $bootstrapper }
    try { Unblock-File -LiteralPath $installExe -ErrorAction SilentlyContinue } catch { }

    Write-Log 'Installing Visual Studio offline from layout (--noWeb)...' 'INFO'
    $start = Get-Date
    $installArgs = @('--noWeb', '--quiet', '--wait', '--norestart') + $workloadArgs
    $code = Invoke-LoggedNative -FilePath $installExe -Arguments $installArgs
    $map  = ConvertFrom-ExitCode -Code $code
    $elapsed = (Get-Date) - $start

    Write-Log ("{0}  [source {1}, elapsed {2:hh\:mm\:ss}]" -f $map.Status, $source, $elapsed) $map.Level
    return [pscustomobject]@{ Name = $Item.DisplayName; Status = $map.Status; Source = $source }
}

function Install-SqlServerCached {
    <#
        Method 'sqlserver': download the SQL Server Developer ISO directly (a plain
        HTTP download that needs NO admin, so it can be cached by a standard user),
        then at install time mount the ISO and run setup silently (mount + install
        require admin).
    #>
    param([string] $WingetExe, [hashtable] $Item, [int] $Index, [int] $Total)

    Show-StepProgress -Index $Index -Total $Total -DisplayName $Item.DisplayName
    Write-Log "Package id : $($Item.Id)" 'INFO'

    if (-not $DownloadOnly -and -not $Force -and (Test-PackageInstalled -WingetExe $WingetExe -Id $Item.Id)) {
        Write-Log 'Already installed -> skipping (use -Force to reinstall).' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Skipped (already installed)'; Source = '-' }
    }

    $sqlRoot = Join-Path $script:CacheRoot 'sqlserver'
    $iso     = Join-Path $sqlRoot 'SQLServer-x64-ENU-Dev.iso'
    $isoReady = (Test-Path -LiteralPath $iso) -and -not $RefreshCache

    if ($DryRun) {
        $tail = if ($DownloadOnly) { 'cache ISO only (no install)' } else { 'mount + install' }
        if ($isoReady) { Write-Log "[DryRun] ISO cache HIT -> would $tail ($iso)" 'WARN' }
        else           { Write-Log "[DryRun] ISO cache MISS -> would download SQL ISO (~1.1 GB) then $tail" 'WARN' }
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'DryRun'; Source = $(if ($isoReady) { 'Cache' } else { 'ISO download' }) }
    }

    # --- Cache the ISO (no admin required) ---
    $source = 'Cache'
    if (-not $isoReady) {
        $source = 'ISO download'
        if ($RefreshCache -and (Test-Path -LiteralPath $iso)) { Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue }
        if (-not $Item.MediaUrl) { throw 'No SQL Server ISO URL configured (Item.MediaUrl).' }
        Save-CachedFile -Url $Item.MediaUrl -Path $iso -Description 'SQL Server Developer ISO (~1.1 GB)'
    } else {
        Write-Log "ISO cache hit -> $iso" 'OK'
    }

    if ($DownloadOnly) {
        Write-Log 'Download-only: SQL Server ISO is cached, skipping install.' 'OK'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Cached (download only)'; Source = $source }
    }

    # --- Install: mount ISO + run setup (requires admin) ---
    if (-not (Test-IsAdmin)) {
        Write-Log 'Installing SQL Server requires administrator rights (mounting the ISO and running setup). Skipping install; ISO is cached.' 'WARN'
        return [pscustomobject]@{ Name = $Item.DisplayName; Status = 'Cached only (install needs admin)'; Source = $source }
    }

    try { Unblock-File -LiteralPath $iso -ErrorAction SilentlyContinue } catch { }

    Write-Log 'Mounting SQL Server ISO...' 'INFO'
    $mount = Mount-DiskImage -ImagePath $iso -PassThru
    try {
        $vol = ($mount | Get-Volume).DriveLetter
        if (-not $vol) { Start-Sleep -Seconds 2; $vol = ($mount | Get-Volume).DriveLetter }
        if (-not $vol) { throw 'Could not determine the mounted ISO drive letter.' }
        $setupExe = "$vol`:\setup.exe"
        if (-not (Test-Path -LiteralPath $setupExe)) { throw "setup.exe not found on mounted ISO ($setupExe)." }
        Write-Log "ISO mounted at ${vol}: -> $setupExe" 'OK'

        Write-Log 'Running silent SQL Server install (Database Engine, default instance)...' 'INFO'
        $start = Get-Date
        $setupArgs = @(
            '/Q', '/ACTION=Install', '/FEATURES=SQLENGINE',
            '/INSTANCENAME=MSSQLSERVER',
            '/SQLSYSADMINACCOUNTS=BUILTIN\Administrators',
            '/IACCEPTSQLSERVERLICENSETERMS', '/TCPENABLED=1', '/UPDATEENABLED=0'
        )
        $code = Invoke-LoggedNative -FilePath $setupExe -Arguments $setupArgs
        $map  = ConvertFrom-ExitCode -Code $code
        $elapsed = (Get-Date) - $start
        Write-Log ("{0}  [source {1}, elapsed {2:hh\:mm\:ss}]" -f $map.Status, $source, $elapsed) $map.Level
    }
    finally {
        Write-Log 'Dismounting SQL Server ISO...' 'INFO'
        try { Dismount-DiskImage -ImagePath $iso | Out-Null } catch { Write-Log "Dismount failed: $($_.Exception.Message)" 'WARN' }
    }

    return [pscustomobject]@{ Name = $Item.DisplayName; Status = $map.Status; Source = $source }
}

#==============================================================================
# Software catalog (single, latest version of the heavyweight products)
#==============================================================================

$catalog = @{
    'VisualStudio' = @{
        DisplayName     = 'Visual Studio Enterprise 2026 (ASP.NET Core + .NET Desktop)'
        Id              = 'Microsoft.VisualStudio.Enterprise'
        Method          = 'visualstudio'
        BootstrapperUrl = 'https://aka.ms/vs/18/Stable/vs_enterprise.exe'
    }
    'SqlServer' = @{
        DisplayName = 'SQL Server 2022 Developer Edition'
        Id          = 'Microsoft.SQLServer.2022.Developer'
        Method      = 'sqlserver'
        # Direct Developer-edition ISO (plain HTTP, no admin to download). This is
        # the same media the SQL Basic installer's "Download Media" fetches.
        MediaUrl    = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'
    }
    'SSMS' = @{
        DisplayName = 'SQL Server Management Studio 22'
        Id          = 'Microsoft.SQLServerManagementStudio.22'
        Method      = 'winget'
    }
    'NotepadPlusPlus' = @{
        DisplayName = 'Notepad++'
        Id          = 'Notepad++.Notepad++'
        Method      = 'winget'
    }
    'VSCode' = @{
        DisplayName = 'Visual Studio Code'
        Id          = 'Microsoft.VisualStudioCode'
        Method      = 'winget'
        # !runcode stops the Inno installer from launching VS Code after a silent
        # install (which would otherwise block the script until the window closes).
        SilentArgs  = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode'
    }
    'GitHubDesktop' = @{
        DisplayName = 'GitHub Desktop'
        Id          = 'GitHub.GitHubDesktop'
        Method      = 'winget'
    }
    'Postman' = @{
        DisplayName = 'Postman'
        Id          = 'Postman.Postman'
        Method      = 'winget'
    }
    'ClaudeDesktop' = @{
        DisplayName = 'Claude Desktop'
        Id          = 'Anthropic.Claude'
        Method      = 'winget'
    }
    'PowerShell' = @{
        DisplayName = 'PowerShell (Core) 7'
        Id          = 'Microsoft.PowerShell'
        Method      = 'winget'
    }
}

#==============================================================================
# Main
#==============================================================================

$script:CacheRoot    = $CachePath
$script:AppCacheRoot = Join-Path $CachePath 'apps'
if (-not (Test-Path -LiteralPath $script:AppCacheRoot)) {
    New-Item -ItemType Directory -Path $script:AppCacheRoot -Force | Out-Null
}

$transcriptPath = [IO.Path]::ChangeExtension($LogPath, '.transcript.log')
try { Start-Transcript -Path $transcriptPath -Append | Out-Null } catch { }

$overallStart = Get-Date
$results = @()

try {
    Write-LogSection 'Windows 11 Development Environment Installer'
    Write-Log "Log file        : $LogPath" 'INFO'
    Write-Log "Transcript      : $transcriptPath" 'INFO'
    Write-Log "Cache root      : $script:CacheRoot" 'INFO'
    Write-Log "PowerShell      : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" 'INFO'

    # Installing requires admin; download-only (caching) does not, so don't force
    # an elevation prompt for it.
    if (Test-IsAdmin) {
        Write-Log 'Running with administrator rights.' 'OK'
    }
    elseif ($DownloadOnly -or $DryRun) {
        Write-Log 'Running without administrator rights (allowed for download-only / dry-run).' 'INFO'
    }
    else {
        Invoke-SelfElevation -BoundParameters $PSBoundParameters
        Write-Log 'Continuing in the elevated window. This window can be closed.' 'INFO'
        return
    }

    $modeLabel = if ($DownloadOnly) { 'Software to cache  ' } else { 'Software to install' }
    Write-Log ("{0} : {1}" -f $modeLabel, ($Software -join ', ')) 'INFO'
    Write-Log "Download only       : $($DownloadOnly.IsPresent)" 'INFO'
    Write-Log "Refresh cache       : $($RefreshCache.IsPresent)" 'INFO'
    Write-Log "Force reinstall     : $($Force.IsPresent)" 'INFO'
    Write-Log "Dry run             : $($DryRun.IsPresent)" 'INFO'

    $wingetExe = Initialize-Winget
    $null      = Invoke-LoggedNative -FilePath $wingetExe -Arguments @('--version')
    Write-Log "winget executable: $wingetExe" 'INFO'

    $total = $Software.Count
    for ($i = 0; $i -lt $total; $i++) {
        $item = $catalog[$Software[$i]]
        # Per-package isolation: a failure in one item (e.g. SQL needing admin)
        # must not abort the rest of the batch.
        try {
            switch ($item.Method) {
                'visualstudio' { $results += Install-VisualStudioCached -WingetExe $wingetExe -Item $item -Index ($i + 1) -Total $total }
                'sqlserver'    { $results += Install-SqlServerCached    -WingetExe $wingetExe -Item $item -Index ($i + 1) -Total $total }
                default        { $results += Install-CachedApp          -WingetExe $wingetExe -Item $item -Index ($i + 1) -Total $total }
            }
        }
        catch {
            Write-Log "$($item.DisplayName) failed: $($_.Exception.Message)" 'ERROR'
            $results += [pscustomobject]@{ Name = $item.DisplayName; Status = "Failed ($($_.Exception.Message))"; Source = '-' }
        }
    }

    Write-Progress -Activity 'Installing Windows 11 development environment' -Completed -Id 1
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'DEBUG'
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------

Write-LogSection 'Installation Summary'
foreach ($r in $results) {
    $lvl = if ($r.Status -match 'Failed') { 'ERROR' }
           elseif ($r.Status -match 'reboot') { 'WARN' }
           else { 'OK' }
    Write-Log ('{0,-55} {1,-30} [{2}]' -f $r.Name, $r.Status, $r.Source) $lvl
}

$overallElapsed = (Get-Date) - $overallStart
Write-Log ("Total time: {0:hh\:mm\:ss}" -f $overallElapsed) 'INFO'
Write-Log "Cache root: $script:CacheRoot" 'INFO'
Write-Log "Full log saved to: $LogPath" 'INFO'

$failed = $results | Where-Object { $_.Status -match 'Failed' }
if ($failed) {
    Write-Log "$($failed.Count) installation(s) failed. Review the log above." 'ERROR'
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

if ($results.Status -match 'reboot') {
    Write-Log 'A reboot is required to finish one or more installs.' 'WARN'
}
if ($DownloadOnly) {
    Write-Log 'Download-only complete: cache populated, nothing installed.' 'OK'
} else {
    Write-Log 'All requested software processed successfully.' 'OK'
}
try { Stop-Transcript | Out-Null } catch { }
