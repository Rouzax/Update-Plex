#Requires -Version 5.1

<#
.SYNOPSIS
    Automatically updates Plex Media Server to the latest release of its channel.

.DESCRIPTION
    Robust Plex Media Server updater designed for unattended Task Scheduler
    execution, for a server that runs Plex as a Windows service under its own
    account (for example through FireDaemon). Replaces Plex's own updater,
    which does not work for a service install.

    Features:
    - Latest release from plex.tv: the beta (Plex Pass) channel with the
      server's own token, or the public channel
    - Never downgrades: when the channel's release is older than the installed
      version (the public channel trails the beta one), nothing is installed,
      not even with -Force
    - Installer verified against the SHA1 published by plex.tv and its
      Authenticode signature (Plex, Inc.) before it runs
    - Skips the run while someone is playing something (unless -Force)
    - Backup of the program folder and the databases, with automatic rollback
      when the install, the start or the health check fails
    - Undoes what the installer does by itself: the Plex instance it starts
      under the installing account, a re-enabled Plex Update Service, and Run
      keys it adds
    - Health check: Plex answers /identity with the same server identity and
      the new version
    - Timestamped logging with rotation, lock file against concurrent runs,
      Pushover notifications

.PARAMETER InstallPath
    Path to the Plex Media Server program folder.

.PARAMETER ServiceName
    Name of the Windows service that runs Plex.

.PARAMETER LogDirectory
    Directory for log files. Created if it does not exist.

.PARAMETER Channel
    Beta (Plex Pass releases; needs a token) or Public. Beta falls back to
    Public with a warning when no token is available.

.PARAMETER PlexToken
    Plex token used only to read the download list of the beta channel.
    Defaults to the token of the account the service runs as, read from its
    registry. Never logged.

.PARAMETER HealthCheckTimeoutSeconds
    Maximum seconds to wait for Plex to answer after the update.

.PARAMETER ServiceStopTimeoutSeconds
    Maximum seconds to wait for Plex and its helper processes to stop.

.PARAMETER MaxBackups
    Number of backups to retain. Oldest are pruned.

.PARAMETER MaxLogFiles
    Number of log files to retain. Oldest are pruned.

.PARAMETER Force
    Reinstall even when the installed version is current, and update even
    while someone is playing something. Never downgrades.

.PARAMETER PushoverUserKey
    Pushover user/group key for notifications. If omitted, no notifications are sent.

.PARAMETER PushoverApiToken
    Pushover application API token.

.PARAMETER PushoverDevice
    Optional Pushover device name to target. If omitted, all devices receive the notification.

.EXAMPLE
    .\Update-Plex.ps1
    Checks the beta channel and updates when a newer release is available.

.EXAMPLE
    .\Update-Plex.ps1 -Channel Public -Verbose
    Uses the public channel and shows every log line.

.NOTES
    CONFIGURATION FILE:
    Create Config\config.json next to this script to set Pushover credentials,
    notification preferences, the channel and MaxBackups. Command-line
    parameters override config values. See Config\config.example.json.

    SERVICE SETUP (one-time):
    This script does not register a service. Plex must already run as a
    service (ServiceName) under an account whose registry holds its Plex
    settings. Plex's data folder is read from that registry
    (LocalAppDataPath).

    TASK SCHEDULER:
      Program:   pwsh.exe
      Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\GitHub\Update-Plex\Update-Plex.ps1"
      Run as an administrator account, with highest privileges.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Parameters are used by nested functions via parent scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Script is designed for unattended non-interactive execution')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', 'Test-PreFlightChecks',
    Justification = 'Name reflects that multiple checks are performed')]
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = "${env:ProgramFiles}\Plex\Plex Media Server",

    [ValidateNotNullOrEmpty()]
    [string]$ServiceName = 'PlexMediaServer',

    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = "${env:ProgramData}\Plex\UpdateLogs",

    [ValidateSet('Beta', 'Public')]
    [string]$Channel = 'Beta',

    [string]$PlexToken,

    [ValidateRange(30, 900)]
    [int]$HealthCheckTimeoutSeconds = 300,

    [ValidateRange(10, 600)]
    [int]$ServiceStopTimeoutSeconds = 120,

    [ValidateRange(1, 20)]
    [int]$MaxBackups = 3,

    [ValidateRange(1, 100)]
    [int]$MaxLogFiles = 30,

    [switch]$Force,

    [string]$PushoverUserKey,

    [string]$PushoverApiToken,

    [string]$PushoverDevice
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region -- Configuration File -------------------------------------------------

$Script:Notifications = @{
    'Success'  = @{ Priority = 0;  Sound = 'none'; Ttl = 0 }
    'Info'     = @{ Priority = -1; Sound = 'none'; Ttl = 0 }
    'Rollback' = @{ Priority = 1;  Sound = 'none'; Ttl = 0 }
    'Failed'   = @{ Priority = 1;  Sound = 'none'; Ttl = 0 }
}

$Script:ConfigPath = Join-Path $PSScriptRoot (Join-Path 'Config' 'config.json')

if (Test-Path $Script:ConfigPath) {
    try {
        $fileConfig = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json

        if ($fileConfig.PSObject.Properties['Pushover'] -and $fileConfig.Pushover) {
            if (-not $PSBoundParameters.ContainsKey('PushoverUserKey')  -and $fileConfig.Pushover.UserKey)  { $PushoverUserKey  = $fileConfig.Pushover.UserKey }
            if (-not $PSBoundParameters.ContainsKey('PushoverApiToken') -and $fileConfig.Pushover.ApiToken) { $PushoverApiToken = $fileConfig.Pushover.ApiToken }
            if (-not $PSBoundParameters.ContainsKey('PushoverDevice')   -and $fileConfig.Pushover.Device)   { $PushoverDevice   = $fileConfig.Pushover.Device }

            if ($fileConfig.Pushover.PSObject.Properties['Notifications'] -and $fileConfig.Pushover.Notifications) {
                foreach ($type in @('Success', 'Failed', 'Rollback', 'Info')) {
                    $notif = $fileConfig.Pushover.Notifications.$type
                    if ($notif) {
                        if ($null -ne $notif.Priority) { $Script:Notifications[$type].Priority = [int]$notif.Priority }
                        if ($notif.Sound)              { $Script:Notifications[$type].Sound    = $notif.Sound }
                        if ($null -ne $notif.Ttl)      { $Script:Notifications[$type].Ttl      = [int]$notif.Ttl }
                    }
                }
            }
        }

        if (-not $PSBoundParameters.ContainsKey('MaxBackups') -and $fileConfig.PSObject.Properties['MaxBackups'] -and $null -ne $fileConfig.MaxBackups) {
            $MaxBackups = [int]$fileConfig.MaxBackups
        }
        if (-not $PSBoundParameters.ContainsKey('Channel') -and $fileConfig.PSObject.Properties['Channel'] -and $fileConfig.Channel) {
            if ($fileConfig.Channel -in @('Beta', 'Public')) { $Channel = [string]$fileConfig.Channel }
            else { Write-Warning "Ignoring Channel '$($fileConfig.Channel)' in config: use Beta or Public" }
        }
    }
    catch {
        Write-Warning "Failed to load config file $($Script:ConfigPath): $_"
    }
}

#endregion

#region -- Constants ----------------------------------------------------------

$Script:DownloadsApiUrl  = 'https://plex.tv/api/downloads/5.json'
$Script:ReleaseBuild     = 'windows-x86_64'
$Script:SignerPattern    = '^CN="?Plex, Inc\.?"?,'
$Script:BackupRoot       = Join-Path $env:ProgramData 'Plex\UpdateBackups'
$Script:LockFile         = Join-Path $env:ProgramData 'Plex\update.lock'
$Script:MinDiskSpaceGB   = 3
$Script:MinInstallerMB   = 50    # Sanity check: the real installer is about 90 MB
$Script:LocalUrl         = 'http://127.0.0.1:32400'
$Script:UserAgent        = 'Plex-AutoUpdater/1.0 (PowerShell)'
# Every process a running Plex has; all of them must be gone before files are replaced.
$Script:PlexProcesses    = @('Plex Media Server', 'Plex Tuner Service', 'PlexScriptHost', 'Plex Transcoder', 'Plex DLNA Server', 'Plex Media Scanner', 'Plex Relay', 'Plex Media Fingerprinter')

# Exit codes for Task Scheduler visibility
enum ExitCode {
    Success            = 0
    AlreadyUpToDate    = 0
    ConcurrentRun      = 1
    PreFlightFailed    = 2
    DownloadFailed     = 3
    VerifyFailed       = 4
    ServiceStopFailed  = 5
    InstallFailed      = 6
    RollbackPerformed  = 7
    HealthCheckFailed  = 8
    UnhandledError     = 99
}

#endregion

#region -- Logging ------------------------------------------------------------

function Initialize-Logging {
    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:LogFile = Join-Path $LogDirectory "PlexUpdate_$timestamp.log"

    Get-ChildItem -Path $LogDirectory -Filter 'PlexUpdate_*.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxLogFiles |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-UpdateLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = "[$timestamp] [$Level] $Message"

    Add-Content -Path $Script:LogFile -Value $entry -Encoding UTF8

    switch ($Level) {
        'ERROR'   { Write-Error   $Message -ErrorAction Continue }
        'WARN'    { Write-Warning $Message }
        'SUCCESS' { Write-Information $entry -InformationAction Continue }
        default   { Write-Verbose $entry }
    }
}

#endregion

#region -- Pushover Notifications ---------------------------------------------

function Send-PushoverNotification {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Rollback', 'Failed', 'Info')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Url,
        [string]$UrlTitle
    )

    if (-not $PushoverUserKey -or -not $PushoverApiToken) {
        return
    }

    $notifSettings = $Script:Notifications[$Type]

    $body = @{
        token    = $PushoverApiToken
        user     = $PushoverUserKey
        title    = $Title
        message  = $Message
        html     = 1
        priority = $notifSettings.Priority
        sound    = $notifSettings.Sound
    }
    if ($notifSettings.Ttl -gt 0) { $body['ttl'] = $notifSettings.Ttl }
    if ($PushoverDevice) { $body['device'] = $PushoverDevice }
    if ($Url) {
        $body['url'] = $Url
        if ($UrlTitle) { $body['url_title'] = $UrlTitle }
    }

    try {
        $null = Invoke-RestMethod -Uri 'https://api.pushover.net/1/messages.json' -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        Write-UpdateLog "Pushover notification sent: $Type" -Level INFO
    }
    catch {
        Write-UpdateLog "Pushover notification failed: $_" -Level WARN
    }
}

#endregion

#region -- Lock File ----------------------------------------------------------

function Enter-UpdateLock {
    $lockDir = Split-Path $Script:LockFile -Parent
    if (-not (Test-Path $lockDir)) {
        New-Item -Path $lockDir -ItemType Directory -Force | Out-Null
    }

    if (Test-Path $Script:LockFile) {
        $lockContent = Get-Content $Script:LockFile -Raw -ErrorAction SilentlyContinue
        $lockAge = (Get-Date) - (Get-Item $Script:LockFile).LastWriteTime

        if ($lockAge.TotalMinutes -gt 60) {
            Write-UpdateLog "Removing stale lock file (age: $($lockAge.TotalMinutes.ToString('F0')) min, PID: $lockContent)" -Level WARN
            Remove-Item $Script:LockFile -Force
        }
        else {
            Write-UpdateLog "Another update is already running (lock age: $($lockAge.TotalMinutes.ToString('F1')) min, PID: $lockContent)" -Level ERROR
            return $false
        }
    }

    # Atomic lock acquisition: CreateNew fails if the file appeared since the check
    try {
        $stream = [System.IO.File]::Open($Script:LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $writer = $null
        try {
            $writer = [System.IO.StreamWriter]::new($stream)
            $writer.Write($PID)
            $writer.Flush()
        }
        finally {
            if ($writer) { $writer.Dispose() }
            $stream.Dispose()
        }
        Write-UpdateLog "Acquired update lock (PID: $PID)"
        return $true
    }
    catch [System.IO.IOException] {
        Write-UpdateLog 'Another update acquired the lock before us (race condition avoided)' -Level ERROR
        return $false
    }
}

function Exit-UpdateLock {
    if (Test-Path $Script:LockFile) {
        Remove-Item $Script:LockFile -Force -ErrorAction SilentlyContinue
        Write-UpdateLog 'Released update lock'
    }
}

#endregion

#region -- Plex Account and Settings ------------------------------------------

function Get-PlexServiceAccount {
    # The account the service runs as holds Plex's settings in its registry.
    $escapedName = $ServiceName.Replace("'", "''")
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $account = [string]$svc.StartName
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        $sid = $null
    }
    return [pscustomobject]@{ Account = $account; Sid = $sid }
}

function Get-PlexSetting {
    <#
        Reads the Plex settings of the service account: data folder, token and
        identity. Loads that account's registry hive temporarily when it is
        not loaded (Plex stopped and the account signed out).
    #>
    param([Parameter(Mandatory)][string]$Sid)

    $loaded = Test-Path "Registry::HKEY_USERS\$Sid"
    $root = "HKEY_USERS\$Sid"
    $mount = 'PlexUpdaterHive'
    $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $loaded) {
        if (-not $profilePath) { return $null }
        & reg.exe load "HKU\$mount" (Join-Path $profilePath 'NTUSER.DAT') 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $root = "HKEY_USERS\$mount"
    }
    try {
        $p = Get-ItemProperty -Path "Registry::$root\Software\Plex, Inc.\Plex Media Server" -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        # Without LocalAppDataPath, Plex keeps its data in the account's own AppData\Local.
        $dataRoot = $null
        if ($p.PSObject.Properties['LocalAppDataPath'] -and $p.LocalAppDataPath) { $dataRoot = [string]$p.LocalAppDataPath }
        elseif ($profilePath) { $dataRoot = Join-Path $profilePath 'AppData\Local' }
        $token = $null
        if ($p.PSObject.Properties['PlexOnlineToken'] -and $p.PlexOnlineToken) { $token = [string]$p.PlexOnlineToken }
        $identity = $null
        if ($p.PSObject.Properties['ProcessedMachineIdentifier'] -and $p.ProcessedMachineIdentifier) { $identity = [string]$p.ProcessedMachineIdentifier }
        return [pscustomobject]@{ DataRoot = $dataRoot; Token = $token; Identity = $identity }
    }
    finally {
        if (-not $loaded) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        }
    }
}

#endregion

#region -- Pre-Flight Checks --------------------------------------------------

function Test-PreFlightChecks {
    Write-UpdateLog '-- Pre-flight checks --'

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-UpdateLog "Service '$ServiceName' not found. Available Plex-like services: $((Get-Service | Where-Object Name -like '*plex*').Name -join ', ')" -Level ERROR
        return $false
    }
    Write-UpdateLog "Service '$ServiceName' found (Status: $($service.Status))"

    $exe = Join-Path $InstallPath 'Plex Media Server.exe'
    if (-not (Test-Path $exe)) {
        Write-UpdateLog "Plex Media Server.exe not found in $InstallPath" -Level ERROR
        return $false
    }
    Write-UpdateLog "Install path verified: $InstallPath"

    $systemDrive = $env:SystemDrive
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'" -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-UpdateLog "Could not query disk space for $systemDrive" -Level ERROR
        return $false
    }
    $freeSpaceGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    if ($freeSpaceGB -lt $Script:MinDiskSpaceGB) {
        Write-UpdateLog "Insufficient disk space on $systemDrive : ${freeSpaceGB}GB free, need $($Script:MinDiskSpaceGB)GB" -Level ERROR
        return $false
    }
    Write-UpdateLog "Disk space OK: ${freeSpaceGB}GB free on $systemDrive"

    foreach ($hostname in @('plex.tv', 'downloads.plex.tv')) {
        try {
            $null = [System.Net.Dns]::GetHostAddresses($hostname)
            Write-UpdateLog "DNS resolution for $hostname OK"
        }
        catch {
            Write-UpdateLog "Cannot resolve $hostname -- no internet? Error: $_" -Level ERROR
            return $false
        }
    }

    return $true
}

#endregion

#region -- Version Detection --------------------------------------------------

function Get-InstalledVersion {
    $exe = Join-Path $InstallPath 'Plex Media Server.exe'
    if (-not (Test-Path $exe)) { return $null }
    try {
        return [string](Get-Item $exe).VersionInfo.FileVersion
    }
    catch {
        Write-UpdateLog "Could not read installed version: $_" -Level WARN
        return $null
    }
}

function ConvertTo-ComparableVersion {
    param([AllowEmptyString()][string]$Raw)

    # Plex versions are four numbers plus a build hash: 1.43.6.11212-fa660d0cd.
    # The installed program reports only the numbers: 1.43.6.11212.
    if (-not $Raw) { return $null }
    $match = [regex]::Match($Raw.Trim(), '^v?(?<ver>\d+(\.\d+){1,3})')
    if (-not $match.Success) { return $null }

    $parts = @($match.Groups['ver'].Value -split '\.')
    while ($parts.Count -lt 4) { $parts += '0' }

    try { return [version]($parts -join '.') }
    catch { return $null }
}

function Compare-PlexVersion {
    <#
        Newer: the channel's release is newer than the installed one.
        Same, Older, or Unknown when either version cannot be parsed.
    #>
    param(
        [AllowEmptyString()][string]$Installed,
        [AllowEmptyString()][string]$Latest
    )

    $instVer   = ConvertTo-ComparableVersion -Raw $Installed
    $latestVer = ConvertTo-ComparableVersion -Raw $Latest
    if (-not $instVer -or -not $latestVer) { return 'Unknown' }
    if ($latestVer -gt $instVer) { return 'Newer' }
    if ($latestVer -lt $instVer) { return 'Older' }
    return 'Same'
}

function Get-UpdateDecision {
    <#
        Whether to install: Install, Skip (with a reason). Never downgrades,
        not even with -Force; an unparseable version is never installed.
    #>
    param(
        [AllowEmptyString()][string]$Installed,
        [Parameter(Mandatory)][string]$Latest,
        [switch]$ForceInstall
    )

    $comparison = Compare-PlexVersion -Installed $Installed -Latest $Latest
    switch ($comparison) {
        'Newer'   { return [pscustomobject]@{ Action = 'Install'; Reason = "newer release available: $Installed -> $Latest" } }
        'Same'    {
            if ($ForceInstall) { return [pscustomobject]@{ Action = 'Install'; Reason = "reinstalling $Latest (-Force)" } }
            return [pscustomobject]@{ Action = 'Skip'; Reason = "already up to date: $Installed" }
        }
        'Older'   { return [pscustomobject]@{ Action = 'Skip'; Reason = "installed $Installed is newer than the channel's $Latest; never downgrading" } }
        default   { return [pscustomobject]@{ Action = 'Skip'; Reason = "cannot compare versions (installed '$Installed', latest '$Latest')" } }
    }
}

function Get-DownloadsUri {
    <#
        The downloads API URL: the Plex Pass channel needs a token, sent as a
        header (never in the URL, which could end up in a log).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Beta', 'Public')][string]$Channel,
        [bool]$HasToken
    )
    if ($Channel -eq 'Beta' -and $HasToken) { return "$($Script:DownloadsApiUrl)?channel=plexpass" }
    return $Script:DownloadsApiUrl
}

function Select-PlexRelease {
    <#
        Picks the Windows 64-bit installer from a downloads API response.
    #>
    param([Parameter(Mandatory)][object]$Response)

    if (-not $Response.PSObject.Properties['computer'] -or -not $Response.computer.PSObject.Properties['Windows']) { return $null }
    $windows = $Response.computer.Windows
    $build = @($windows.releases | Where-Object { $_.build -eq $Script:ReleaseBuild }) | Select-Object -First 1
    if (-not $build -or -not $build.url -or -not $build.checksum) { return $null }
    $released = $null
    if ($windows.PSObject.Properties['release_date'] -and $windows.release_date) {
        $released = [DateTimeOffset]::FromUnixTimeSeconds([long]$windows.release_date).LocalDateTime
    }
    return [pscustomobject]@{
        Version  = [string]$windows.version
        Url      = [string]$build.url
        Sha1     = ([string]$build.checksum).ToLowerInvariant()
        Released = $released
    }
}

function Get-LatestRelease {
    param([string]$Token)

    $useChannel = $Channel
    if ($Channel -eq 'Beta' -and -not $Token) {
        Write-UpdateLog 'Beta channel requested but no Plex token is available; using the public channel' -Level WARN
        $useChannel = 'Public'
    }
    $uri = Get-DownloadsUri -Channel $useChannel -HasToken ([bool]$Token)
    $headers = @{ 'User-Agent' = $Script:UserAgent; 'Accept' = 'application/json' }
    if ($Token) { $headers['X-Plex-Token'] = $Token }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        Write-UpdateLog "Could not read the Plex download list ($useChannel channel): $($_.Exception.Message)" -Level ERROR
        return $null
    }

    $release = Select-PlexRelease -Response $response
    if (-not $release) {
        Write-UpdateLog "The Plex download list has no $($Script:ReleaseBuild) installer" -Level ERROR
        return $null
    }
    $release | Add-Member -NotePropertyName Channel -NotePropertyValue $useChannel
    Write-UpdateLog "Latest $useChannel release: $($release.Version) (released $($release.Released))"
    return $release
}

#endregion

#region -- Active Sessions ----------------------------------------------------

function Get-ActiveSessionCount {
    <#
        Number of streams playing right now, or $null when Plex does not
        answer (stopped, or the request was refused).
    #>
    param([string]$Token)

    $headers = @{ 'Accept' = 'application/json' }
    if ($Token) { $headers['X-Plex-Token'] = $Token }
    try {
        $r = Invoke-RestMethod -Uri "$($Script:LocalUrl)/status/sessions" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        return [int]$r.MediaContainer.size
    }
    catch {
        return $null
    }
}

#endregion

#region -- Download & Verify --------------------------------------------------

function Get-PlexInstaller {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '',
        Justification = 'plex.tv publishes only a SHA1; the Authenticode signature check below is the integrity guarantee')]
    param([Parameter(Mandatory)][object]$Release)

    $tempDir = Join-Path $env:TEMP "PlexUpdate_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    $fileName = Split-Path ([uri]$Release.Url).AbsolutePath -Leaf
    $path = Join-Path $tempDir $fileName

    Write-UpdateLog "Downloading $fileName..."
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Release.Url -OutFile $path -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = $Script:UserAgent } -ErrorAction Stop
        }
        finally { $ProgressPreference = $oldProgress }
    }
    catch {
        Write-UpdateLog "Download failed: $($_.Exception.Message)" -Level ERROR
        return [pscustomobject]@{ TempDir = $tempDir; Path = $null; Code = [ExitCode]::DownloadFailed }
    }

    $sizeMB = [math]::Round((Get-Item $path).Length / 1MB, 1)
    if ($sizeMB -lt $Script:MinInstallerMB) {
        Write-UpdateLog "Downloaded installer is only $sizeMB MB; expected at least $($Script:MinInstallerMB) MB" -Level ERROR
        return [pscustomobject]@{ TempDir = $tempDir; Path = $null; Code = [ExitCode]::VerifyFailed }
    }

    $sha1 = (Get-FileHash -Path $path -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($sha1 -ne $Release.Sha1) {
        Write-UpdateLog "Checksum mismatch: downloaded $sha1, plex.tv publishes $($Release.Sha1)" -Level ERROR
        return [pscustomobject]@{ TempDir = $tempDir; Path = $null; Code = [ExitCode]::VerifyFailed }
    }

    $sig = Get-AuthenticodeSignature -FilePath $path
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch $Script:SignerPattern) {
        $signer = 'none'
        if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        Write-UpdateLog "Installer signature is not a valid Plex, Inc. signature (status $($sig.Status), signer $signer)" -Level ERROR
        return [pscustomobject]@{ TempDir = $tempDir; Path = $null; Code = [ExitCode]::VerifyFailed }
    }

    Write-UpdateLog "Installer verified: $sizeMB MB, SHA1 matches plex.tv, signed by Plex, Inc." -Level SUCCESS
    return [pscustomobject]@{ TempDir = $tempDir; Path = $path; Code = [ExitCode]::Success }
}

#endregion

#region -- Service Management -------------------------------------------------

function Get-PlexProcess {
    return @(Get-Process -Name $Script:PlexProcesses -ErrorAction SilentlyContinue)
}

function Stop-PlexService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Write-UpdateLog "Stopping service '$ServiceName' (current status: $($service.Status))..."
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutSeconds))
            Write-UpdateLog 'Service stopped'
        }
        catch {
            Write-UpdateLog "Graceful stop failed: $_" -Level WARN
        }
    }
    else {
        Write-UpdateLog 'Service is already stopped'
    }

    # A service wrapper can report Stopped before Plex itself has exited; wait for every Plex process.
    $deadline = (Get-Date).AddSeconds($ServiceStopTimeoutSeconds)
    while ((Get-Date) -lt $deadline -and @(Get-PlexProcess).Count) { Start-Sleep -Seconds 2 }

    $left = @(Get-PlexProcess)
    if ($left.Count) {
        foreach ($p in $left) {
            Write-UpdateLog "Killing lingering process: $($p.ProcessName) (PID: $($p.Id))" -Level WARN
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (@(Get-PlexProcess).Count -eq 0 -and $service.Status -eq 'Stopped') {
        Write-UpdateLog 'Plex is fully stopped' -Level SUCCESS
        return $true
    }
    Write-UpdateLog "CRITICAL: Plex still running after all stop attempts (service: $($service.Status))" -Level ERROR
    return $false
}

function Start-PlexService {
    Write-UpdateLog "Starting service '$ServiceName'..."
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            Write-UpdateLog 'Service started' -Level SUCCESS
            return $true
        }
        catch {
            Write-UpdateLog "Start attempt $attempt/3 failed: $_" -Level WARN
            if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
        }
    }
    Write-UpdateLog 'Failed to start service after all attempts' -Level ERROR
    return $false
}

#endregion

#region -- Backup & Rollback --------------------------------------------------

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$Files = @(),
        [switch]$Mirror
    )
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $robocopyArgs = @($Source, $Destination) + $Files + @('/R:2', '/W:1', '/NP', '/NDL', '/NFL', ('/LOG+:' + (Join-Path $LogDirectory "robocopy_${Label}_$timestamp.log")))
    if ($Mirror) { $robocopyArgs += '/MIR' }
    $null = & robocopy @robocopyArgs
    return $LASTEXITCODE -lt 8
}

function New-UpdateBackup {
    <#
        Copies the program folder and Plex's databases (Plex stopped, so they
        are consistent). Plex migrates its databases on upgrade, so a rollback
        needs both. Artwork and caches are not copied.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [string]$VersionLabel = 'unknown'
    )

    if (-not (Test-Path $Script:BackupRoot)) { New-Item -Path $Script:BackupRoot -ItemType Directory -Force | Out-Null }
    $backupDir = Join-Path $Script:BackupRoot "${VersionLabel}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Write-UpdateLog "Creating backup in $backupDir..."

    try {
        if (-not (Invoke-Robocopy -Source $InstallPath -Destination (Join-Path $backupDir 'Program') -Label 'backup_program' -Mirror)) {
            Write-UpdateLog 'Backup of the program folder failed' -Level ERROR
            return $null
        }
        # The live databases only: not Plex's own dated backups (*.db-YYYY-MM-DD).
        if (-not (Invoke-Robocopy -Source $DatabasePath -Destination (Join-Path $backupDir 'Databases') -Label 'backup_db' -Files @('*.db', '*.db-wal', '*.db-shm'))) {
            Write-UpdateLog 'Backup of the databases failed' -Level ERROR
            return $null
        }
        $size = (Get-ChildItem $backupDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-UpdateLog "Backup complete: $backupDir ($([math]::Round($size / 1MB, 1)) MB)" -Level SUCCESS

        Get-ChildItem -Path $Script:BackupRoot -Directory |
            Sort-Object CreationTime -Descending |
            Select-Object -Skip $MaxBackups |
            ForEach-Object {
                Write-UpdateLog "Pruning old backup: $($_.Name)"
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        return $backupDir
    }
    catch {
        Write-UpdateLog "Backup failed: $_" -Level ERROR
        return $null
    }
}

function Restore-FromBackup {
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$DatabasePath,
        [bool]$StartAfter = $true
    )

    Write-UpdateLog "ROLLING BACK from backup: $BackupDir" -Level WARN
    if (-not (Test-Path $BackupDir)) {
        Write-UpdateLog "Backup directory not found: $BackupDir" -Level ERROR
        return $false
    }

    $null = Stop-PlexService

    try {
        if (-not (Invoke-Robocopy -Source (Join-Path $BackupDir 'Program') -Destination $InstallPath -Label 'rollback_program' -Mirror)) {
            Write-UpdateLog 'Restoring the program folder failed -- MANUAL INTERVENTION REQUIRED' -Level ERROR
            return $false
        }
        # Write-ahead files from the failed version must not be replayed onto the old databases.
        Get-ChildItem -Path $DatabasePath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.db-wal' -or $_.Name -like '*.db-shm' } | Remove-Item -Force -ErrorAction SilentlyContinue
        if (-not (Invoke-Robocopy -Source (Join-Path $BackupDir 'Databases') -Destination $DatabasePath -Label 'rollback_db' -Files @('*.db', '*.db-wal', '*.db-shm'))) {
            Write-UpdateLog 'Restoring the databases failed -- MANUAL INTERVENTION REQUIRED' -Level ERROR
            return $false
        }
        Write-UpdateLog 'Program folder and databases restored from backup' -Level SUCCESS
        Repair-InstallerSideEffect

        if (-not $StartAfter) {
            Write-UpdateLog 'Rollback complete; Plex left stopped as it was' -Level SUCCESS
            return $true
        }
        if (Start-PlexService) {
            Write-UpdateLog 'Rollback complete, service is running on the previous version' -Level SUCCESS
            return $true
        }
        Write-UpdateLog 'Rollback restored files but the service failed to start -- MANUAL INTERVENTION REQUIRED' -Level ERROR
        return $false
    }
    catch {
        Write-UpdateLog "Rollback failed: $_ -- MANUAL INTERVENTION REQUIRED" -Level ERROR
        return $false
    }
}

#endregion

#region -- Installation -------------------------------------------------------

function Get-InstallerFootprint {
    # What the installer may create for the account that runs it, recorded before it runs.
    [pscustomobject]@{
        UserKey    = Test-Path 'HKCU:\Software\Plex, Inc.'
        UserData   = Test-Path (Join-Path $env:LOCALAPPDATA 'Plex Media Server')
        RunMachine = [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Plex Media Server' -ErrorAction SilentlyContinue)
        RunUser    = [bool](Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Plex Media Server' -ErrorAction SilentlyContinue)
    }
}

function Repair-InstallerSideEffect {
    <#
        The installer starts Plex as the installing account and re-enables
        Plex's own update service. Plex must only ever run as the service,
        and updates are this script's job.
    #>
    param([object]$Before)

    foreach ($p in Get-PlexProcess) {
        Write-UpdateLog "Stopping Plex started outside the service: $($p.ProcessName) (PID: $($p.Id))"
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    $updateSvc = Get-Service -Name 'PlexUpdateService' -ErrorAction SilentlyContinue
    if ($updateSvc -and $updateSvc.StartType -ne 'Disabled') {
        Stop-Service -Name 'PlexUpdateService' -Force -ErrorAction SilentlyContinue
        Set-Service -Name 'PlexUpdateService' -StartupType Disabled
        Write-UpdateLog 'Plex Update Service disabled again'
    }

    if ($Before) {
        if (-not $Before.RunMachine) { Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Plex Media Server' -ErrorAction SilentlyContinue }
        if (-not $Before.RunUser) { Remove-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Plex Media Server' -ErrorAction SilentlyContinue }
        # A Plex identity created for the installing account (only when the
        # script does not run as the service account, whose settings are real).
        $self = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $svc = Get-PlexServiceAccount
        if ($svc -and $svc.Sid -ne $self) {
            if (-not $Before.UserKey -and (Test-Path 'HKCU:\Software\Plex, Inc.')) {
                Remove-Item 'HKCU:\Software\Plex, Inc.' -Recurse -Force -ErrorAction SilentlyContinue
                Write-UpdateLog 'Removed the Plex identity the installer created for this account'
            }
            $userData = Join-Path $env:LOCALAPPDATA 'Plex Media Server'
            if (-not $Before.UserData -and (Test-Path $userData)) {
                Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue
                Write-UpdateLog "Removed the Plex data folder the installer created in $userData"
            }
        }
    }
}

function Install-PlexUpdate {
    param([Parameter(Mandatory)][string]$InstallerPath)

    $before = Get-InstallerFootprint
    $log = Join-Path $LogDirectory "installer_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-UpdateLog 'Running the installer silently...'
    try {
        # Inno Setup installer; /quiet style switches make it hang.
        $p = Start-Process -FilePath $InstallerPath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"" -PassThru
        if (-not $p.WaitForExit(600000)) {
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-UpdateLog 'Installer did not finish within 10 minutes' -Level ERROR
            Repair-InstallerSideEffect -Before $before
            return $false
        }
        Write-UpdateLog "Installer exit code: $($p.ExitCode)"
        Repair-InstallerSideEffect -Before $before
        if ($p.ExitCode -ne 0) {
            Write-UpdateLog "Installer failed with exit code $($p.ExitCode); see $log" -Level ERROR
            return $false
        }
        if (-not (Test-Path (Join-Path $InstallPath 'Plex Media Server.exe'))) {
            Write-UpdateLog "Post-install verification failed: no Plex Media Server.exe in $InstallPath" -Level ERROR
            return $false
        }
        Write-UpdateLog 'Installation completed' -Level SUCCESS
        return $true
    }
    catch {
        Write-UpdateLog "Installation failed: $_" -Level ERROR
        Repair-InstallerSideEffect -Before $before
        return $false
    }
}

#endregion

#region -- Health Check -------------------------------------------------------

function Test-PlexHealth {
    param(
        [string]$ExpectedIdentity,
        [string]$ExpectedVersion
    )

    Write-UpdateLog "Health check against $($Script:LocalUrl)/identity (timeout: ${HealthCheckTimeoutSeconds}s)..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $HealthCheckTimeoutSeconds) {
        try {
            $r = Invoke-RestMethod -Uri "$($Script:LocalUrl)/identity" -Headers @{ 'Accept' = 'application/json' } -TimeoutSec 10 -ErrorAction Stop
            $id = [string]$r.MediaContainer.machineIdentifier
            $version = [string]$r.MediaContainer.version
            if ($ExpectedIdentity -and $id -ne $ExpectedIdentity) {
                Write-UpdateLog "Plex answers with identity $id, expected $ExpectedIdentity" -Level ERROR
                return $false
            }
            if ($ExpectedVersion -and (Compare-PlexVersion -Installed $version -Latest $ExpectedVersion) -ne 'Same') {
                Write-UpdateLog "Plex answers with version $version, expected $ExpectedVersion" -Level ERROR
                return $false
            }
            Write-UpdateLog "Health check passed after $([math]::Round($stopwatch.Elapsed.TotalSeconds))s: version $version, same server identity" -Level SUCCESS
            return $true
        }
        catch {
            Write-UpdateLog "Plex not answering yet ($([math]::Round($stopwatch.Elapsed.TotalSeconds))s): $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 5
    }
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Write-UpdateLog "Health check FAILED after ${HealthCheckTimeoutSeconds}s. Service status: $($service.Status)" -Level ERROR
    return $false
}

#endregion

#region -- Main ---------------------------------------------------------------

function Invoke-PlexUpdate {
    Initialize-Logging
    Write-UpdateLog '================================================================'
    Write-UpdateLog '  Plex Auto-Updater starting'
    Write-UpdateLog "  Host: $env:COMPUTERNAME | User: $env:USERNAME | PID: $PID | Channel: $Channel"
    Write-UpdateLog '================================================================'

    $exitCode = [ExitCode]::Success
    $backupDir = $null
    $tempDir = $null
    $installedVersion = $null
    $release = $null
    $databasePath = $null
    $stopped = $false
    $wasRunning = $false
    $startAfter = $true

    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-UpdateLog 'This script must run elevated (as administrator)' -Level ERROR
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }

        if (-not (Enter-UpdateLock)) {
            return [int][ExitCode]::ConcurrentRun
        }

        if (-not (Test-PreFlightChecks)) {
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }

        # -- The service account's Plex settings: data folder, token, identity --
        $account = Get-PlexServiceAccount
        $settings = $null
        if ($account -and $account.Sid) { $settings = Get-PlexSetting -Sid $account.Sid }
        if (-not $settings) {
            Write-UpdateLog "No Plex settings found for the service account '$(if ($account) { $account.Account })'" -Level ERROR
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }
        $dataRoot = $settings.DataRoot
        if (-not $dataRoot) {
            Write-UpdateLog 'Cannot tell where Plex keeps its data (no LocalAppDataPath and no profile for the service account)' -Level ERROR
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }
        $databasePath = Join-Path $dataRoot 'Plex Media Server\Plug-in Support\Databases'
        if (-not (Test-Path $databasePath)) {
            Write-UpdateLog "Plex databases not found at $databasePath" -Level ERROR
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }
        $token = $PlexToken
        if (-not $token) { $token = $settings.Token }
        Write-UpdateLog "Service account: $($account.Account); data: $dataRoot; token: $(if ($token) { 'available' } else { 'none (unclaimed server)' })"

        # -- Version check --
        $installedVersion = Get-InstalledVersion
        $release = Get-LatestRelease -Token $token
        if (-not $release) {
            $exitCode = [ExitCode]::DownloadFailed
            return [int]$exitCode
        }
        $decision = Get-UpdateDecision -Installed $installedVersion -Latest $release.Version -ForceInstall:$Force
        if ($decision.Action -ne 'Install') {
            Write-UpdateLog ($decision.Reason.Substring(0, 1).ToUpper() + $decision.Reason.Substring(1)) -Level SUCCESS
            return [int][ExitCode]::AlreadyUpToDate
        }
        Write-UpdateLog "Update: $($decision.Reason)"

        # -- Nobody watching --
        $sessions = Get-ActiveSessionCount -Token $token
        if ($sessions -and -not $Force) {
            Write-UpdateLog "$sessions stream(s) playing; not interrupting them. The next run will try again." -Level WARN
            Send-PushoverNotification -Type 'Info' -Title 'Plex update postponed' -Message "<b>$env:COMPUTERNAME</b>: $($release.Version) is available, but $sessions stream(s) were playing."
            return [int][ExitCode]::Success
        }

        # Identity before the update, for the health check
        $identity = $null
        try { $identity = [string](Invoke-RestMethod -Uri "$($Script:LocalUrl)/identity" -Headers @{ 'Accept' = 'application/json' } -TimeoutSec 10 -ErrorAction Stop).MediaContainer.machineIdentifier } catch { $identity = $settings.Identity }
        $svcNow = Get-Service -Name $ServiceName
        $wasRunning = $svcNow.Status -eq 'Running'
        # A stopped Plex that is not set to start by itself stays stopped: on a
        # server that is still being set up, a first start would give it a new identity.
        $startAfter = $wasRunning -or ([string]$svcNow.StartType -eq 'Automatic')

        # -- Download and verify before touching anything --
        $download = Get-PlexInstaller -Release $release
        $tempDir = $download.TempDir
        if (-not $download.Path) {
            $exitCode = $download.Code
            return [int]$exitCode
        }

        # -- Stop, backup, install --
        # Marked before stopping: if stopping throws, the failure handler restarts Plex.
        $stopped = $true
        if (-not (Stop-PlexService)) {
            $exitCode = [ExitCode]::ServiceStopFailed
            if ($wasRunning) { $null = Start-PlexService }
            return [int]$exitCode
        }

        $versionLabel = 'unknown'
        if ($installedVersion) { $versionLabel = $installedVersion }
        $backupDir = New-UpdateBackup -DatabasePath $databasePath -VersionLabel $versionLabel
        if (-not $backupDir) {
            Write-UpdateLog 'Cannot proceed without a valid backup; starting Plex again unchanged' -Level ERROR
            if ($wasRunning) { $null = Start-PlexService }
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }

        if (-not (Install-PlexUpdate -InstallerPath $download.Path)) {
            Write-UpdateLog 'Installation failed, initiating rollback...' -Level ERROR
            $null = Restore-FromBackup -BackupDir $backupDir -DatabasePath $databasePath -StartAfter $startAfter
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        if (-not $startAfter) {
            $newVersion = Get-InstalledVersion
            Write-UpdateLog "Updated to $newVersion; Plex was stopped and is set to $([string]$svcNow.StartType), so it was not started and not health-checked" -Level SUCCESS
            Send-PushoverNotification -Type 'Info' -Title "Plex updated to $newVersion (not started)" -Message "<b>$env:COMPUTERNAME</b>: $installedVersion -> $newVersion. Plex was stopped and set to $([string]$svcNow.StartType), so it was left stopped."
            return [int][ExitCode]::Success
        }

        if (-not (Start-PlexService)) {
            Write-UpdateLog 'Service failed to start after update, initiating rollback...' -Level ERROR
            $null = Restore-FromBackup -BackupDir $backupDir -DatabasePath $databasePath -StartAfter $startAfter
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        if (-not (Test-PlexHealth -ExpectedIdentity $identity -ExpectedVersion $release.Version)) {
            Write-UpdateLog 'Health check failed after update, initiating rollback...' -Level ERROR
            $null = Restore-FromBackup -BackupDir $backupDir -DatabasePath $databasePath -StartAfter $startAfter
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        $newVersion = Get-InstalledVersion
        Write-UpdateLog "Update successful: $installedVersion -> $newVersion" -Level SUCCESS
        Send-PushoverNotification -Type 'Success' `
            -Title "Plex updated to $newVersion" `
            -Message (
                "<b>$env:COMPUTERNAME</b> updated successfully ($($release.Channel) channel)" +
                "<br><b>Previous:</b> $installedVersion" +
                "<br><b>New:</b> $newVersion" +
                "<br><b>Duration:</b> $([math]::Round(((Get-Date) - (Get-Item $Script:LogFile).CreationTime).TotalSeconds))s"
            ) `
            -Url 'https://forums.plex.tv/t/plex-media-server/30447' `
            -UrlTitle 'Release Notes'

        $exitCode = [ExitCode]::Success
        return [int]$exitCode
    }
    catch {
        Write-UpdateLog "UNHANDLED EXCEPTION: $_" -Level ERROR
        Write-UpdateLog "Stack trace: $($_.ScriptStackTrace)" -Level ERROR

        if ($backupDir -and (Test-Path $backupDir) -and $databasePath) {
            Write-UpdateLog 'Attempting emergency rollback...' -Level WARN
            $null = Restore-FromBackup -BackupDir $backupDir -DatabasePath $databasePath -StartAfter $startAfter
            $exitCode = [ExitCode]::RollbackPerformed
        }
        else {
            if ($stopped -and $wasRunning) { $null = Start-PlexService }
            $exitCode = [ExitCode]::UnhandledError
        }
        return [int]$exitCode
    }
    finally {
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-UpdateLog "Cleaned up temp directory: $tempDir"
        }

        Exit-UpdateLock

        if ($exitCode -eq [ExitCode]::RollbackPerformed) {
            Send-PushoverNotification -Type 'Rollback' `
                -Title 'Plex update ROLLED BACK' `
                -Message (
                    "<b>$env:COMPUTERNAME</b> update failed and was rolled back" +
                    "<br><b>Installed:</b> $(if ($installedVersion) { $installedVersion } else { 'unknown' })" +
                    "<br><b>Target:</b> $(if ($release) { $release.Version } else { 'unknown' })" +
                    "<br>Check logs: <b>$Script:LogFile</b>"
                )
        }
        elseif ([int]$exitCode -gt 0 -and $exitCode -ne [ExitCode]::ConcurrentRun) {
            Send-PushoverNotification -Type 'Failed' `
                -Title "Plex update failed ($exitCode)" `
                -Message (
                    "<b>$env:COMPUTERNAME</b> update failed at stage: <b>$exitCode</b>" +
                    "<br><b>Installed:</b> $(if ($installedVersion) { $installedVersion } else { 'unknown' })" +
                    "<br>Check logs: <b>$Script:LogFile</b>"
                )
        }

        Write-UpdateLog "Exit code: $exitCode ($([int]$exitCode))"
        Write-UpdateLog '================================================================'
        Write-UpdateLog '  Plex Auto-Updater finished'
        Write-UpdateLog '================================================================'
    }
}

#endregion

# Dot-sourcing (the tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-PlexUpdate | Select-Object -Last 1
    exit $result
}
