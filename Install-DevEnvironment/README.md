# Windows 11 Dev Environment Installer

A single Windows PowerShell script that provisions a fresh Windows 11 machine
for development by installing your usual toolchain through
[winget](https://learn.microsoft.com/windows/package-manager/) (the Windows
Package Manager that ships with Windows 11).

Pass an array of the software you want, or run it with no arguments to install
everything. Installers are **cached locally**, so provisioning a second machine
(or re-running) reuses the downloads instead of fetching them again.

## Supported software

Only the latest single version of the two heavyweight products is supported, to
keep the cache small.

| Key               | Software                                                  | winget ID |
|-------------------|----------------------------------------------------------|-----------|
| `VisualStudio`    | Visual Studio Enterprise 2026 (ASP.NET Core + .NET Desktop) | `Microsoft.VisualStudio.Enterprise` |
| `SqlServer`       | SQL Server 2025 Developer Edition                       | `Microsoft.SQLServer.2025.Developer` |
| `SSMS`            | SQL Server Management Studio 22                          | `Microsoft.SQLServerManagementStudio.22` |
| `NotepadPlusPlus` | Notepad++                                                | `Notepad++.Notepad++` |
| `VSCode`          | Visual Studio Code                                       | `Microsoft.VisualStudioCode` |
| `GitHubDesktop`   | GitHub Desktop                                           | `GitHub.GitHubDesktop` |
| `Postman`         | Postman                                                  | `Postman.Postman` |
| `ClaudeDesktop`   | Claude Desktop                                           | `Anthropic.Claude` |
| `PowerShell`      | PowerShell (Core) 7                                      | `Microsoft.PowerShell` |

## Requirements

- Windows 11.
- **Windows PowerShell 5.1** (`powershell.exe`) — the script is written for the
  built-in shell, because PowerShell Core is not on a fresh Windows install. The
  script *installs* PowerShell Core for you (`PowerShell` key), but it runs on
  Windows PowerShell.
- Administrator rights. The script self-elevates if needed.
- Internet access.

> **winget is bootstrapped automatically.** You do not need winget pre-installed.
> If it's missing, the script installs the "App Installer"
> (`Microsoft.DesktopAppInstaller`) and its dependencies first. It tries, in
> order: (1) re-registering an existing App Installer, (2) the official
> `Microsoft.WinGet.Client` PowerShell module (`Repair-WinGetPackageManager`),
> and (3) a direct download of the App Installer bundle + VCLibs + UI.Xaml
> dependencies via `Add-AppxPackage`.

## Usage

Open **Windows PowerShell as Administrator** in the repo folder.

If scripts are blocked by execution policy, either run it through the policy
bypass or set it for your user once:

```powershell
# One-off run without changing machine policy
powershell -ExecutionPolicy Bypass -File .\Install-DevEnvironment.ps1
```

### Install everything (default)

```powershell
.\Install-DevEnvironment.ps1
```

### Install only specific tools

```powershell
.\Install-DevEnvironment.ps1 -Software VSCode, GitHubDesktop, Postman
```

### Use a custom cache folder

```powershell
.\Install-DevEnvironment.ps1 -CachePath D:\DevCache
```

### Preview without installing (shows cache hit/miss)

```powershell
.\Install-DevEnvironment.ps1 -DryRun
```

### Force a fresh download (ignore the cache)

```powershell
.\Install-DevEnvironment.ps1 -RefreshCache
```

### Pre-seed the cache without installing

```powershell
.\Install-DevEnvironment.ps1 -DownloadOnly -CachePath "E:\DevCache"
```

### Force reinstall / repair

```powershell
.\Install-DevEnvironment.ps1 -Software VSCode -Force
```

## Parameters

| Parameter         | Values                | Default                        | Description |
|-------------------|-----------------------|--------------------------------|-------------|
| `-Software`       | any of the keys above | all of them                    | Which tools to install. |
| `-CachePath`      | folder path           | `%LOCALAPPDATA%\DevEnvInstaller\Cache` | Root of the local installer cache. |
| `-RefreshCache`   | switch                | off                            | Ignore cached files and download fresh. |
| `-DownloadOnly`   | switch                | off                            | Only populate the cache; install nothing. |
| `-LogPath`        | file path             | timestamped file (see below)   | Where to write the log. |
| `-Force`          | switch                | off                            | Reinstall even if already present. |
| `-DryRun`         | switch                | off                            | Show planned actions + cache state only. |

## Caching

To avoid re-downloading installers every time you provision a machine, downloads
are cached under `-CachePath` (default `%LOCALAPPDATA%\DevEnvInstaller\Cache`).

| Software group | How it's cached | How it's installed on a cache hit |
|----------------|-----------------|-----------------------------------|
| The 7 simple apps (SSMS, Notepad++, VS Code, GitHub Desktop, Postman, Claude, PowerShell) | `winget download` into `apps\<id>\<version>\` | The cached installer is run directly using the silent switch winget records in the sidecar manifest. If that fails, it falls back to a normal online `winget install`. |
| Visual Studio  | An **offline layout** (`--layout`) under `visualstudio\layout\` | Installed offline with `--noWeb` (no large re-download). |
| SQL Server     | Installation **media** (`/Action=Download`) under `sqlserver\media\` | Installed silently from the cached media. |

The cache key for the simple apps includes the resolved **version**, so when a
new version is released you get a fresh download automatically; otherwise the
existing cached installer is reused. Use `-RefreshCache` to force a re-download.

Use **`-DownloadOnly`** to populate the cache on an online machine without
installing anything (it caches even packages that are already installed, and
ignores the "already installed" skip). This is the recommended way to pre-seed a
shared cache that other machines then install from offline.

> **Why the split?** `winget`'s downloaded manifest still points at a remote URL,
> and `winget install --manifest` both re-downloads and requires an admin-only
> policy (`LocalManifestFiles`). Running the cached installer directly is what
> makes the cache actually save bandwidth. Visual Studio and SQL Server ship
> tiny web bootstrappers, so they only cache meaningfully via their native
> offline mechanisms (VS layout / SQL media).

## Testing the cache offline (VM checkpoint workflow)

The cache is designed so a second machine can install with **no internet**, as
long as the cache folder survives. Recommended VM test:

1. **Put the cache on a folder that survives checkpoint reversal** — e.g. a host
   shared folder or a second virtual disk that isn't part of the snapshot. Keep
   the path short (helps the Visual Studio layout).
2. **Confirm the base image already has winget** (`winget --version`). Windows 11
   ships with it; offline bootstrapping of winget itself is not possible.
3. **First run (online)** — populates the cache *and* installs:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-DevEnvironment.ps1 -CachePath E:\DevCache -LogPath E:\DevCache\logs\run1.log
```

4. **Verify the cache populated** before reverting:
   - `E:\DevCache\apps\<id>\<version>\` has an installer + `.yaml` for each app
   - `E:\DevCache\visualstudio\layout\` is populated (if VS was selected)
   - `E:\DevCache\sqlserver\media\` has `SQLServer*-x64-*.exe` (+ `.box`)
5. **Revert the checkpoint** to the clean state.
6. **Second run (offline)** — disable the network, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-DevEnvironment.ps1 -CachePath E:\DevCache -LogPath E:\DevCache\logs\run2.log
```

   Every package should report `[Cache]` as its source. A handy preview that
   makes no changes and prints cache HIT/MISS per package:

```powershell
.\Install-DevEnvironment.ps1 -CachePath E:\DevCache -DryRun
```

**Notes for the offline run**
- Whatever you want installed offline must have been cached on the first run, so
  run the same `-Software` set (default = all) both times.
- SQL Server's setup may need OS prerequisites (e.g. .NET Framework) that aren't
  on a bare image; the cached media includes the SQL payload, but a fully bare
  offline box can still fail SQL prereqs. The 7 simple apps and Visual Studio
  (from layout) are the most reliable offline.

## Logging & progress

The script logs extensively:

- **Structured log** — every action is written as
  `YYYY-MM-DD HH:mm:ss [LEVEL] message` to both the console (color-coded by
  level: `STEP`, `OK`, `WARN`, `ERROR`, `INFO`, `DEBUG`) and the log file.
- **winget output** — the raw output of each `winget` call is teed into the log.
- **Transcript** — a full `Start-Transcript` capture is saved next to the log
  with a `.transcript.log` extension.
- **Progress bar** — `Write-Progress` shows `[N/Total] <software>` as it works.
- **Cache hit/miss** — each package logs whether it was served from cache,
  downloaded, or installed online.
- **Summary** — a per-package status table (with the source) and total elapsed
  time at the end.

Default log location:

```
%LOCALAPPDATA%\DevEnvInstaller\Logs\Install_<yyyyMMdd_HHmmss>.log
```

Override it with `-LogPath`:

```powershell
.\Install-DevEnvironment.ps1 -LogPath C:\Temp\devsetup.log
```

When the script self-elevates, the elevated run reuses the same log file.

## Notes

- **First run with no winget:** bootstrapping winget may install the
  `Microsoft.WinGet.Client` module from the PowerShell Gallery and/or download
  the App Installer package. This needs internet access and admin rights.
- **Visual Studio workloads:** the script installs the *ASP.NET and web
  development* (`Microsoft.VisualStudio.Workload.NetWeb`) and *.NET desktop
  development* (`Microsoft.VisualStudio.Workload.ManagedDesktop`) workloads plus
  recommended components. To pin specific SDKs (e.g. .NET 8 and .NET 10), add the
  corresponding component IDs to the workload arguments in the script.
- **Disk space:** the VS offline layout and SQL media are large (tens of GB for
  VS). Point `-CachePath` at a drive with room if needed.
- **SQL Server install** uses a sensible silent default (Database Engine only,
  default `MSSQLSERVER` instance, local Administrators as sysadmin). Adjust the
  `setupArgs` in `Install-SqlServerCached` for more features/instances.
- A reboot is recommended after Visual Studio and SQL Server complete.
- Already-installed tools are detected and skipped unless `-Force` is supplied.
