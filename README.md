# Update-Plex

Keeps Plex Media Server up to date on a Windows server where Plex runs as a
Windows service under its own account (for example through FireDaemon), from
Task Scheduler, without anyone watching. Plex's built-in updater does not work
for such a service install; this script replaces it.

## Features

- **Latest release of your channel** from plex.tv: the beta (Plex Pass)
  channel, using the server's own token, or the public channel.
- **Never downgrades.** The public channel often trails the beta one; when the
  channel's release is older than what is installed, nothing is installed, not
  even with `-Force`.
- **Verified installer.** The download must match the SHA1 that plex.tv
  publishes and carry a valid Authenticode signature from Plex, Inc. before it
  runs.
- **Does not interrupt viewers.** While something is playing the run is
  postponed (with a low-priority notification); the next run tries again.
- **Backup and automatic rollback.** The program folder and Plex's databases
  are backed up with Plex stopped. If the install, the start or the health
  check fails, both are restored and Plex is started on the previous version.
- **Cleans up after the installer.** The Plex installer starts Plex under the
  account that runs it and re-enables Plex's own update service. The script
  stops that copy, disables the update service again and removes any Run key or
  stray identity the installer created.
- **Health check.** Plex must answer `/identity` with the same server identity
  and the new version.
- Timestamped logs with rotation, a lock file against overlapping runs, and
  Pushover notifications for success, rollback and failure.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7, run elevated.
- Plex Media Server installed in `C:\Program Files\Plex\Plex Media Server`
  (or pass `-InstallPath`), running as a Windows service (`-ServiceName`,
  default `PlexMediaServer`) under an account whose registry holds its Plex
  settings.
- Internet access to `plex.tv` and `downloads.plex.tv`.
- For the beta channel: a claimed server (its token is read from the service
  account's registry) or `-PlexToken`. Without a token the public channel is
  used, with a warning.

## Quick Start

```powershell
git clone https://github.com/Rouzax/Update-Plex.git C:\GitHub\Update-Plex
Copy-Item C:\GitHub\Update-Plex\Config\config.example.json C:\GitHub\Update-Plex\Config\config.json
# edit config.json: Pushover keys, Channel
pwsh -NoProfile -File C:\GitHub\Update-Plex\Update-Plex.ps1 -Verbose
```

## Configuration File

`Config\config.json` (ignored by git; it holds your Pushover keys):

| Key | Meaning |
|---|---|
| `Pushover.UserKey`, `Pushover.ApiToken`, `Pushover.Device` | Pushover delivery. Without keys no notifications are sent |
| `Pushover.Notifications.<Type>` | `Priority`, `Sound`, `Ttl` per type: `Success`, `Failed`, `Rollback`, `Info` |
| `Channel` | `Beta` (default) or `Public` |
| `MaxBackups` | Backups to keep (default 3) |

Command-line parameters override the file.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-InstallPath` | `C:\Program Files\Plex\Plex Media Server` | Plex program folder |
| `-ServiceName` | `PlexMediaServer` | The service that runs Plex |
| `-LogDirectory` | `C:\ProgramData\Plex\UpdateLogs` | Logs, created if missing |
| `-Channel` | `Beta` | `Beta` or `Public` |
| `-PlexToken` | the service account's token | Used only to read the beta download list; never logged |
| `-HealthCheckTimeoutSeconds` | 300 | How long Plex may take to answer after the update |
| `-ServiceStopTimeoutSeconds` | 120 | How long Plex may take to stop |
| `-MaxBackups` | 3 | Backups to keep |
| `-MaxLogFiles` | 30 | Log files to keep |
| `-Force` | | Reinstall the current version, and update while someone is watching. Never downgrades |
| `-PushoverUserKey`, `-PushoverApiToken`, `-PushoverDevice` | from config | Pushover overrides |

## Examples

```powershell
# Check the beta channel and update when there is a newer release
.\Update-Plex.ps1

# Public releases only, every log line on screen
.\Update-Plex.ps1 -Channel Public -Verbose

# Reinstall the current release, even while someone is watching
.\Update-Plex.ps1 -Force
```

## Task Scheduler Setup

- Program: `pwsh.exe` (or `powershell.exe`)
- Arguments: `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\GitHub\Update-Plex\Update-Plex.ps1"`
- Run as an administrator account (the service account itself works when it
  is a local administrator), whether or not it is signed in, with highest
  privileges.
- Pick a time when nobody watches; a run that finds something playing is
  postponed to the next one.

## How It Works

1. Takes the lock, checks the service, the program folder, 3 GB free disk
   space and name resolution.
2. Reads the service account's Plex settings: data folder
   (`LocalAppDataPath`, or the account's `AppData\Local`), token, identity.
3. Reads the latest release of the channel and decides: install, already up to
   date, or never downgrade.
4. Postpones when something is playing (unless `-Force`).
5. Downloads and verifies the installer (SHA1 and signature) before touching
   anything.
6. Stops Plex and waits until every Plex process has exited.
7. Backs up the program folder and the databases (not Plex's own dated
   database backups, not artwork).
8. Runs the installer silently and undoes its side effects.
9. Starts Plex and runs the health check. A Plex that was stopped and set to
   Manual is updated but left stopped (on a server still being set up, a first
   start would give it a new identity).
10. Rolls back on any failure, and notifies.

Exit codes: 0 success or up to date, 1 another run is busy, 2 pre-flight
failed, 3 download failed, 4 installer verification failed, 5 Plex would not
stop, 6 install failed, 7 rolled back, 8 health check failed, 99 unexpected
error.

## File Locations

| What | Where |
|---|---|
| Logs | `C:\ProgramData\Plex\UpdateLogs\PlexUpdate_<timestamp>.log`, plus robocopy and installer logs |
| Backups | `C:\ProgramData\Plex\UpdateBackups\<version>_<timestamp>\` (`Program`, `Databases`) |
| Lock | `C:\ProgramData\Plex\update.lock` |

## License

MIT, see [LICENSE](LICENSE).
