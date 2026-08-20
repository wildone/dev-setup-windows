# Dev Setup Windows

This repository automates the Windows development environment and provides maintenance tools for WSL 2, Docker Desktop, and self-hosted GitHub Actions runners.

The Windows entry points are PowerShell scripts. The WSL analysis script transports a fixed Bash probe into Linux so paths and commands are not reinterpreted by PowerShell or `wsl.exe`.

## Principles

1. **Automation** - configure a machine consistently with repeatable scripts.
2. **Portability** - prefer portable applications where practical.
3. **Least privilege** - run without elevation unless a task genuinely requires administrator access.
4. **Native tools** - use `winget`, PowerShell, WSL, and built-in Windows tools.
5. **WSL for Linux workloads** - use WSL 2 for Linux-native development and runner workloads.
6. **Explicit destructive operations** - analysis is read-only, pruning is opt-in, and disruptive WSL shutdown requires explicit authorization.

## Quick start

On a clean machine, install PowerShell and Git:

```powershell
winget install Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements
winget install Microsoft.Git --silent --accept-package-agreements --accept-source-agreements
```

Then:

1. Clone this repository.
2. Review and update `.env` for local paths and Git settings.
3. Run `setup-env-admin.ps1` from an elevated terminal for machine-level settings.
4. Run `setup-env.ps1` from an elevated terminal for elevated environment changes.
5. Run `setup-env.ps1` as the normal user for user-level environment variables and `PATH`.
6. Run `setup-apps.ps1` as the normal user to install configured applications.

## Script overview

| Script | Purpose | Elevation |
|---|---|---|
| `setup-apps.ps1` | Installs applications through `winget` using repository configuration. | Normally no |
| `setup-env.ps1` | Configures user or elevated environment variables and file associations. | Depends on the requested scope |
| `setup-env-admin.ps1` | Applies machine-level registry and environment configuration. | Yes |
| `functions.ps1` | Shared helper functions used by setup scripts. | Not run directly |
| [`cleanup-temp.ps1`](./cleanup-temp.ps1) | Removes old files and empty directories from the current user's local Temp folder. | No |
| [`wsl-analyse.ps1`](./wsl-analyse.ps1) | Produces a read-only WSL/VHDX disk-usage report. | No |
| [`wsl-runner-status.ps1`](./wsl-runner-status.ps1) | Determines whether custom WSL GitHub Actions runners are idle, busy, offline, or unsafe to inspect. | No |
| [`wsl-compact.ps1`](./wsl-compact.ps1) | Trims and compacts custom runner VHDXs, or all discovered WSL/Docker VHDXs when no custom runners exist or `-All` is requested. | Yes |

## User temp cleanup

`cleanup-temp.ps1` cleans only the current user's `%LOCALAPPDATA%\Temp`
folder. By default, it removes files last modified more than seven days ago and
then removes old directories that are empty. It skips locked files and never
traverses filesystem junctions or symbolic links.

Preview the cleanup without changing anything:

```powershell
.\cleanup-temp.ps1 -ListOnly
```

Remove files older than the default seven days:

```powershell
.\cleanup-temp.ps1
```

Choose a different minimum age or inspect every proposed removal:

```powershell
.\cleanup-temp.ps1 -OlderThanDays 30
.\cleanup-temp.ps1 -OlderThanDays 1 -WhatIf
```

| Parameter | Default | Meaning |
|---|---|---|
| `-OlderThanDays <0-3650>` | `7` | Remove files and empty directories whose last-write time is older than this age. |
| `-ListOnly` | Off | Report candidate counts and estimated reclaimable bytes without deleting anything. |
| `-WhatIf` | Off | Use PowerShell's standard per-item removal preview. |

## WSL storage maintenance

WSL 2 stores each Linux filesystem in a dynamically expanding VHDX file. Deleting data inside Linux makes filesystem blocks free, but it does not necessarily reduce the Windows host file immediately.

Reclaiming host disk space has three distinct stages:

1. Delete or prune data that is no longer needed inside the distribution.
2. Run `fstrim` so free ext4 blocks are reported as discardable.
3. Shut down the shared WSL 2 utility VM and compact the detached VHDX from Windows.

These scripts deliberately keep analysis, runner-state checking, data deletion, and VHDX compaction separate.

### Safety model

| Operation | Starts stopped distributions | Deletes Linux/Docker data | Stops WSL or jobs |
|---|---:|---:|---:|
| `wsl-analyse.ps1` | Yes, for selected targets | No | No |
| `wsl-runner-status.ps1` | No | No | No |
| `wsl-compact.ps1 -ListOnly` | No in normal runner mode | No | No |
| `wsl-compact.ps1 -AllowWslShutdown` | May restart previously active runners afterward | No | Yes, only after every runner is safe |
| `wsl-compact.ps1 -AllowWslShutdown -Force` | Restores selected runners afterward | No | Yes, including active job attempts |
| `wsl-compact.ps1 -All` | May start distributions for `fstrim` | Optional Docker Desktop prune | Yes, every WSL distribution |

`wsl-compact.ps1` requires a shared `wsl --shutdown` maintenance window because DiskPart cannot compact a VHDX while the WSL 2 utility VM still has it attached. Terminating only one distribution may leave PID 4/System holding the file.

## Prerequisites

The WSL scripts require:

- Windows PowerShell 5.1 or PowerShell 7.
- WSL 2 and at least one registered WSL 2 distribution.
- `wsl.exe`, which is provided by WSL.
- `diskpart.exe` for compaction; it is built into Windows.
- An elevated terminal for `wsl-compact.ps1`.
- GitHub CLI (`gh`) authenticated for default remote runner verification.
- Docker CLI when Docker Desktop is running or Docker Desktop pruning is requested.

Useful checks:

```powershell
wsl --version
wsl --list --verbose
gh auth status
docker context show
docker version
```

`wsl-analyse.ps1` uses common Linux utilities such as `bash`, `df`, `du`, `find`, and `ps`. Docker, `journalctl`, `lsof`, `numfmt`, and `timeout` are optional; unavailable checks are reported or skipped.

## `wsl-analyse.ps1`

### What it does

`wsl-analyse.ps1` correlates Windows WSL registrations with their VHDX files and then runs a read-only Linux probe as root. It reports:

- Registered base path, VHDX path, Windows host-file size, attributes, and modification time.
- The ext4 filesystem's virtual capacity, used bytes, free bytes, and inode usage.
- A snapshot of high-CPU processes that may explain active growth.
- Sizes of fixed known paths such as `/var/lib/docker`, `/home`, `/var/log`, `/var/cache`, `/opt`, and database storage folders.
- Docker images, containers, volumes, and build-cache usage when Docker is available.
- Persistent runner containers and nested-Docker storage when present.
- systemd journal and APT cache usage.
- Deleted files that remain allocated because a process still has them open, when `lsof` is installed.
- Optionally, the largest files on the Linux root filesystem.

It does not delete files, prune Docker, install packages, change VHDX settings, or compact disks. Selected stopped distributions are started because the Linux probe must run inside them.

By default, all registered non-Docker WSL 2 distributions are analysed and a timestamped report such as `wsl-analysis-20260802-035000.txt` is written to the current directory.

### Common commands

Fast first pass while runners may be active:

```powershell
.\wsl-analyse.ps1 -SummaryOnly -CommandTimeoutSeconds 20
```

Inspect known folders and Docker without the exhaustive largest-file scan:

```powershell
.\wsl-analyse.ps1 -DistroName creator-signal-org,creator-signal-org-02 -Quick
```

Run the complete analysis for one distribution:

```powershell
.\wsl-analyse.ps1 -DistroName sales-pulse-02 -Top 40 -MinimumFileSizeMB 250
```

Choose an explicit report path:

```powershell
.\wsl-analyse.ps1 -DistroName ontograph -Quick -OutputPath C:\Temp\ontograph-wsl.txt
```

Include Docker Desktop distributions in the default target set:

```powershell
.\wsl-analyse.ps1 -IncludeDockerDesktop -SummaryOnly
```

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-DistroName <name[]>` | All non-Docker WSL 2 distributions | Analyse only the named registered distributions. |
| `-Top <5-100>` | `25` | Maximum number of processes, paths, and files shown in relevant sections. |
| `-MinimumFileSizeMB <n>` | `512` | Minimum size for the exhaustive largest-file scan. |
| `-Quick` | Off | Measure known folders and Docker but skip the root-wide largest-file scan. |
| `-SummaryOnly` | Off | Skip known-folder and largest-file walks; retain filesystem, process, log, open-file, and time-limited Docker checks. |
| `-IncludeDockerDesktop` | Off | Include distributions whose names match `docker-*` when targets are not specified explicitly. |
| `-CommandTimeoutSeconds <5-600>` | `30` | Limit each potentially expensive Linux or Docker query. |
| `-OutputPath <path>` | Timestamped file in the current directory | Write the complete report to this path. Missing parent directories are created. |

### Reading the report

- **VHDX host file size** is the real space currently occupied by the `.vhdx` file on Windows.
- **Filesystem Size** from `df` is the virtual ext4 capacity, not the current Windows allocation.
- **Filesystem Used** is live Linux filesystem usage and is the lower bound for how small the VHDX can become.
- **Docker reclaimable** means Docker considers data unused; it is not deleted by the analysis script.
- **TIMEOUT** usually means a directory contains many files or is changing during an active build. Increase `-CommandTimeoutSeconds`, use `-Quick`, or retry while idle.
- Docker logical totals may not exactly equal the allocated size of `/var/lib/docker` because image layers and build caches can share storage.

The script exits `0` when every selected Linux probe succeeds and `1` when one or more probes fail.

## `wsl-runner-status.ps1`

### What it does

`wsl-runner-status.ps1` performs non-mutating checks against custom WSL GitHub Actions runners. By default, it selects WSL 2 distributions registered below `C:\WSL`.

For each running distribution it checks:

- Whether `/home/*/actions-runner/.runner` exists.
- `Runner.Listener` and `Runner.Worker` processes.
- A `job-active` marker below `/run`.
- Whether the runner maintenance lock is currently held with `flock`.
- The corresponding GitHub runner's `online` and `busy` state through `gh`.

Stopped distributions are reported as `OFFLINE` and are not started.

### Decisions

| Decision | Meaning | Safe to compact |
|---|---|---:|
| `IDLE` | Local signals and, by default, GitHub agree that the runner is idle. | Yes |
| `OFFLINE` | The WSL distribution is stopped and was not started by the check. | Yes |
| `BUSY` | A worker, job marker, or GitHub busy state is present. | No |
| `MAINTENANCE` | The runner maintenance lock is actively held. | No |
| `UNKNOWN` | Configuration, listener, GitHub, or probe state cannot be verified safely. | No |

### Commands

Check every custom runner below `C:\WSL`:

```powershell
.\wsl-runner-status.ps1
```

Check selected distributions:

```powershell
.\wsl-runner-status.ps1 -DistroName sales-pulse,ontograph
```

Use local signals without GitHub verification:

```powershell
.\wsl-runner-status.ps1 -LocalOnly
```

Emit machine-readable JSON:

```powershell
.\wsl-runner-status.ps1 -AsJson
```

Use a different custom-runner storage root:

```powershell
.\wsl-runner-status.ps1 -RunnerRoot D:\WSL-Runners
```

### Parameters and exit codes

| Parameter | Default | Meaning |
|---|---|---|
| `-DistroName <name[]>` | Every WSL 2 registration below `RunnerRoot` | Check only the named distributions. |
| `-RunnerRoot <path>` | `C:\WSL` | Root containing custom runner distribution directories. |
| `-LocalOnly` | Off | Skip GitHub verification. Local checks still run. |
| `-AsJson` | Off | Emit JSON objects instead of the formatted table and summary. |

| Exit code | Meaning |
|---:|---|
| `0` | Every selected runner is `IDLE` or `OFFLINE`. |
| `1` | At least one runner is `BUSY` or in `MAINTENANCE`. |
| `2` | At least one running runner is `UNKNOWN`. |

For automation, treat only exit code `0` as permission to enter a maintenance window.

## `wsl-compact.ps1`

### What it does

`wsl-compact.ps1` uses built-in `fstrim`, `wsl --shutdown`, and DiskPart `compact vdisk`. The Hyper-V PowerShell module and `Optimize-VHD` are not required.

When custom GitHub Actions runner VHDXs exist below `C:\WSL`, the default mode:

1. Checks every selected runner locally and through GitHub.
2. Refuses the whole maintenance window if any runner is busy, under maintenance, or unknown.
3. Runs `fstrim` in the selected runner distributions.
4. Rechecks the complete runner fleet.
5. Pauses matching `WSL Runner Autostart - <distro>` scheduled tasks.
6. Records and temporarily disables Docker Desktop's login setting, then stops its CLI, service, and processes.
7. Performs a final runner check.
8. Runs `wsl --shutdown` and verifies Docker stayed stopped before touching any VHDX.
9. Compacts selected runner VHDXs with up to two concurrent DiskPart jobs by default.
10. Restores the exact Docker startup/service settings captured at entry, then restores previously running runner keepalives and Docker Desktop.
11. Reports before/after sizes and reclaimed space.

An `fstrim` failure is nonfatal: compaction continues, but that VHDX may reclaim less space. Each trim operation has a 45-second timeout.

When no WSL 2 distributions are registered below `RunnerRoot`, the script skips
runner-specific checks and automatically continues with normal Docker and WSL
VHDX discovery. This uses the same targets as `-All`, but always retains the
interactive `COMPACT` confirmation because the whole-machine mode was selected
implicitly. Use `-ListOnly` to preview this fallback without changing anything.

### Normal runner mode

Safe preview:

```powershell
.\wsl-compact.ps1 -ListOnly
```

Compact only when the complete custom-runner fleet is idle or offline:

```powershell
.\wsl-compact.ps1 -AllowWslShutdown
```

The script asks for the exact confirmation `COMPACT FLEET` unless `-Force` is supplied.

Use only local activity signals when GitHub CLI verification is unavailable:

```powershell
.\wsl-compact.ps1 -AllowWslShutdown -LocalOnly
```

`-LocalOnly` is less conservative because it cannot detect a GitHub-side busy/state mismatch.

### Forced runner maintenance

Preview the forced target set without changing anything:

```powershell
.\wsl-compact.ps1 -AllowWslShutdown -Force -ListOnly
```

Force the complete custom-runner maintenance window:

```powershell
.\wsl-compact.ps1 -AllowWslShutdown -Force
```

This exact pair of switches bypasses runner activity probes, selects every registered WSL 2 runner below `RunnerRoot`, pauses its keepalive task, and shuts down the shared WSL VM. Active job attempts are interrupted; configured retry automation can reschedule them after the runners return.

`-Force` by itself does not override busy runners and does not authorize WSL shutdown.

Compaction concurrency is bounded with `-ThrottleLimit`. The default of `2` can reduce elapsed time when several VHDXs are selected. Use `-ThrottleLimit 1` for sequential behavior, or raise it to at most `4` when the storage can sustain the additional I/O. More concurrency is not necessarily faster when every VHDX is on the same physical disk.

### Full Docker and WSL mode

`-All` explicitly selects the legacy whole-machine mode, including on machines
that have custom runners. On machines without custom runners, this mode is
selected automatically. It discovers VHDX files below:

- `%LOCALAPPDATA%\Docker`
- `%LOCALAPPDATA%\wsl`
- `RunnerRoot`, which defaults to `C:\WSL`
- Registered WSL base paths outside those roots

This mode does not perform runner activity gating and does not pause or restore custom-runner keepalive tasks. Treat it as a whole-machine outage and verify runner recovery afterward.

Preview all discovered files:

```powershell
.\wsl-compact.ps1 -All -ListOnly
```

Compact everything and interactively choose Docker Desktop pruning:

```powershell
.\wsl-compact.ps1 -All
```

Compact everything after standard Docker Desktop cleanup:

```powershell
.\wsl-compact.ps1 -All -DockerPrune Standard
```

Delete unused Docker Desktop volumes as well:

```powershell
.\wsl-compact.ps1 -All -DockerPrune Volumes
```

`Volumes` can delete unused persistent data. Review Docker volumes before using it.

The `-DockerPrune` option invokes the Windows Docker CLI against its active context, which is normally Docker Desktop. Verify `docker context show` before pruning. It does not prune Docker images or BuildKit caches inside custom runner distributions. Use each runner's configured idle reaper or another deliberate in-runner cleanup procedure before compaction.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-DockerPrune <Ask|None|Standard|Volumes>` | `Ask` | In `-All` mode, optionally prune the active Windows Docker CLI context. `Standard` preserves volumes; `Volumes` removes unused volumes too. Ignored in normal runner mode. |
| `-All` | Off | Explicitly use disruptive whole-machine discovery and compaction instead of runner-safe mode. This mode is selected automatically when no custom runners exist. |
| `-RunnerRoot <path>` | `C:\WSL` | Root containing custom runner WSL distributions. |
| `-LocalOnly` | Off | Skip GitHub verification in normal runner mode. |
| `-AllowWslShutdown` | Off | Authorize stopping Docker Desktop, every WSL distribution, and the shared utility VM in runner mode. |
| `-Force` | Off | Skip confirmation. Paired with `-AllowWslShutdown`, also bypass runner activity probes and include every registered runner below `RunnerRoot`. |
| `-NoRestartDocker` | Off | Do not restart Docker Desktop if the script stopped it. |
| `-NoRestartRunners` | Off | Do not restart runner distributions or previously running keepalive tasks after runner-mode compaction. |
| `-ThrottleLimit <1-4>` | `2` | Maximum number of VHDX files compacted concurrently. Use `1` for the previous sequential behavior. |
| `-ListOnly` | Off | Display target/readiness information without trimming, stopping, pruning, or compacting. |

Docker startup suppression is temporary and exception-safe: the script restores the login Run value, Docker's `AutoStart` preference, and the `com.docker.service` startup mode in `finally`. `-NoRestartDocker` controls whether a previously running Docker Desktop process is relaunched; it does not leave those startup settings disabled.

The script exits `1` after a fatal dependency, shutdown, compaction, or restoration failure. List-only checks, user cancellation, missing shutdown authorization, and safety blocks are intentional no-ops and can exit `0`; always read the displayed result instead of relying only on the exit code.

## Recommended workflow

1. Inspect host allocation and live Linux usage:

   ```powershell
   .\wsl-analyse.ps1 -Quick
   ```

2. Check runner activity:

   ```powershell
   .\wsl-runner-status.ps1
   ```

3. Preview compaction targets:

   ```powershell
   .\wsl-compact.ps1 -ListOnly
   ```

4. Allow configured runner reapers to delete unused Docker/build/workspace data while runners are idle.

5. Run safe compaction from an elevated PowerShell terminal:

   ```powershell
   .\wsl-compact.ps1 -AllowWslShutdown
   ```

6. Run `wsl-analyse.ps1 -Quick` again if a VHDX remains unexpectedly large.

Compaction cannot remove live data. If ext4 reports 30 GB used, the VHDX cannot reasonably shrink below that usage plus filesystem and VHDX overhead.

## Troubleshooting

### `The process cannot access the file because it is being used by another process`

The VHDX is still attached. A per-distribution `wsl --terminate` may be insufficient because the shared WSL 2 utility VM retains the handle. Use the runner-safe maintenance flow with `-AllowWslShutdown`, or explicit `-All` mode, so keepalives are paused before `wsl --shutdown` and DiskPart compaction.

Do not repeatedly invoke DiskPart against a VHDX that remains attached.

### `Wsl/Service/0x8007274c` or `fstrim failed`

WSL did not accept or complete the Linux trim command. The compactor records a warning and continues. DiskPart may still reclaim blocks discarded previously, but the affected VHDX may remain larger than expected. Retry during a quieter maintenance window.

### A VHDX remains large after successful compaction

Run:

```powershell
.\wsl-analyse.ps1 -DistroName <name> -Quick
```

Compare the Windows VHDX host-file size with ext4 `Used` bytes. Common real consumers are:

- `/var/lib/docker/overlay2`
- Docker images and BuildKit cache
- GitHub Actions `_work` checkouts and tool cache
- GitHub Actions `_diag` logs
- systemd journals and `/var/log`
- Deleted files still held open by a process

Deleting or pruning data inside WSL does not shrink the Windows file by itself. Run `fstrim` and host compaction afterward.

### Runner status is `UNKNOWN`

Check:

```powershell
gh auth status
wsl --list --verbose
.\wsl-runner-status.ps1 -DistroName <name> -LocalOnly
```

`UNKNOWN` is intentionally treated as unsafe in normal compaction mode.

### Analysis takes too long

Start with:

```powershell
.\wsl-analyse.ps1 -SummaryOnly -CommandTimeoutSeconds 20
```

Then use `-Quick` for known-folder measurements. A timeout is not proof of failure; Docker trees with many layers and active builds can exceed the per-command limit.

### VHDX files grow again immediately

Restored runners may immediately accept queued jobs and create images, build cache, workspaces, and logs. Each WSL distribution has an independent Docker store, so the same CI image can occupy space in multiple runner VHDXs.

## What compaction does not do

- It does not reduce the ext4 virtual capacity reported by `df`.
- It does not uninstall or recreate WSL distributions.
- It does not automatically delete runner Docker images, build cache, workspaces, or logs.
- It does not guarantee that host VHDX size will exactly equal ext4 used bytes.
- It does not make `-DockerPrune` affect Docker engines running inside custom WSL runners.
- It does not make forced interruption safe for workflows without retry or recovery behavior.
