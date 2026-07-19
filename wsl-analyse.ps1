#Requires -Version 5.1

<#
.SYNOPSIS
    Produces a read-only report showing where a WSL 2 distribution uses disk space.

.DESCRIPTION
    Correlates registered WSL distributions with their VHDX files, then runs
    read-only Linux filesystem checks as root. No packages are installed and no
    files, caches, logs, distributions, or VHDX settings are changed.

.PARAMETER DistroName
    One or more registered distribution names. By default, analyzes all
    non-Docker WSL 2 distributions.

.PARAMETER Top
    Number of largest directories, files, and cache candidates to report.

.PARAMETER MinimumFileSizeMB
    Minimum size included in the largest-file scan.

.PARAMETER Quick
    Skips the exhaustive largest-file scan. Known-folder and Docker analysis
    still run.

.PARAMETER SummaryOnly
    Reports VHDX/filesystem totals, logs, and open deleted files without walking
    the directory tree. Useful for a fast first pass while CI jobs are active.

.PARAMETER IncludeDockerDesktop
    Includes Docker-managed WSL distributions in the default target list.

.PARAMETER CommandTimeoutSeconds
    Maximum time allowed for each potentially expensive Linux filesystem or
    Docker query. Timed-out checks are reported and analysis continues.

.PARAMETER OutputPath
    Report destination. Defaults to a timestamped text file in the current folder.

.EXAMPLE
    .\wsl-analyse.ps1

.EXAMPLE
    .\wsl-analyse.ps1 -DistroName Ubuntu -Top 40 -MinimumFileSizeMB 250

.EXAMPLE
    .\wsl-analyse.ps1 -DistroName Ubuntu -Quick

.EXAMPLE
    .\wsl-analyse.ps1 -DistroName Ubuntu -SummaryOnly -CommandTimeoutSeconds 20
#>

[CmdletBinding()]
param(
    [string[]]$DistroName,

    [ValidateRange(5, 100)]
    [int]$Top = 25,

    [ValidateRange(1, 1048576)]
    [int]$MinimumFileSizeMB = 512,

    [switch]$Quick,
    [switch]$SummaryOnly,
    [switch]$IncludeDockerDesktop,

    [ValidateRange(5, 600)]
    [int]$CommandTimeoutSeconds = 30,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reportLines = New-Object 'System.Collections.Generic.List[string]'

function Write-ReportLine {
    param(
        [AllowEmptyString()][string]$Text = "",
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $cleanText = $Text.Replace("`0", "")
    Write-Host $cleanText -ForegroundColor $Color
    [void]$script:reportLines.Add($cleanText)
}

function ConvertTo-NormalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalPath = $Path -replace '^\\\\\?\\', ''
    return [System.IO.Path]::GetFullPath($normalPath).TrimEnd('\')
}

function Format-Bytes {
    param([int64]$Bytes)

    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Get-WslDistributions {
    $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    $distributions = @()

    if (-not (Test-Path -LiteralPath $registryPath)) {
        return $distributions
    }

    foreach ($key in Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue) {
        try {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            $name = ([string]$properties.DistributionName).Replace("`0", "").Trim()
            $basePath = ConvertTo-NormalPath ([string]$properties.BasePath)
            $version = [int]$properties.Version

            if ([string]::IsNullOrWhiteSpace($name) -or -not (Test-Path -LiteralPath $basePath -PathType Container)) {
                continue
            }

            $vhdFiles = @(Get-ChildItem -LiteralPath $basePath -Filter "*.vhdx" -File -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending)
            $vhdPath = $null
            if ($vhdFiles.Count -gt 0) {
                $vhdPath = $vhdFiles[0].FullName
            }

            $distributions += [PSCustomObject]@{
                Name     = $name
                Version  = $version
                BasePath = $basePath
                VhdPath  = $vhdPath
            }
        } catch {
            Write-Warning "Could not read WSL registration '$($key.PSChildName)': $($_.Exception.Message)"
        }
    }

    return $distributions
}

if ($null -eq (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. Install or enable WSL before running this analyzer."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) ("wsl-analysis-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
} else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and
    -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$allDistributions = @(Get-WslDistributions | Where-Object { $_.Version -eq 2 })
if ($allDistributions.Count -eq 0) {
    throw "No registered WSL 2 distributions were found for the current Windows user."
}

if ($null -ne $DistroName -and $DistroName.Count -gt 0) {
    $targets = @($allDistributions | Where-Object { $DistroName -contains $_.Name })
    $missingNames = @($DistroName | Where-Object { $_ -notin $allDistributions.Name })
    if ($missingNames.Count -gt 0) {
        throw "Unknown or non-WSL-2 distribution name(s): $($missingNames -join ', ')"
    }
} else {
    $targets = @($allDistributions)
    if (-not $IncludeDockerDesktop) {
        $targets = @($targets | Where-Object { $_.Name -notlike "docker-*" })
    }
}

if ($targets.Count -eq 0) {
    throw "No distributions matched the requested filters."
}

$quickValue = "false"
if ($Quick) {
    $quickValue = "true"
}
$summaryOnlyValue = "false"
if ($SummaryOnly) {
    $summaryOnlyValue = "true"
}

$linuxAnalyzer = @'
set -uo pipefail
export LC_ALL=C

TOP="$1"
MINIMUM_MB="$2"
QUICK="$3"
SUMMARY_ONLY="$4"
COMMAND_TIMEOUT_SECONDS="$5"

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "${COMMAND_TIMEOUT_SECONDS}s" "$@"
    else
        "$@"
    fi
}

human_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$1"
    else
        printf '%s bytes' "$1"
    fi
}

print_sized_paths() {
    while IFS=$'\t' read -r bytes path; do
        [ -n "${bytes:-}" ] || continue
        printf '%10s  %s\n' "$(human_size "$bytes")" "$path"
    done
}

print_known_path() {
    path="$1"
    [ -e "$path" ] || return 0
    result="$(run_with_timeout du -x -s -B1 "$path" 2>/dev/null)"
    status=$?
    if [ "$status" -eq 124 ]; then
        printf 'Timed out after %ss while measuring %s\n' "$COMMAND_TIMEOUT_SECONDS" "$path" >&2
    fi
    [ -n "$result" ] || return 0
    printf '%s\n' "$result"
}

print_timed_path_size() {
    path="$1"
    [ -e "$path" ] || return 0
    result="$(run_with_timeout du -x -s -B1 "$path" 2>/dev/null)"
    status=$?
    if [ -n "$result" ]; then
        bytes="${result%%[[:space:]]*}"
        printf '%10s  %s\n' "$(human_size "$bytes")" "$path"
    elif [ "$status" -eq 124 ]; then
        printf '%10s  %s (measurement exceeded %ss; usually a large or high-churn tree)\n' 'TIMEOUT' "$path" "$COMMAND_TIMEOUT_SECONDS"
    else
        printf '%10s  %s (size unavailable)\n' 'UNKNOWN' "$path"
    fi
}

printf '%s\n' '--- Distribution and filesystem ---'
printf 'Distribution: '
if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-unknown}"
else
    printf '%s\n' 'unknown'
fi
printf 'Kernel: %s\n' "$(uname -r)"
printf '\nFilesystem capacity (virtual maximum, not Windows host allocation):\n'
df -hT /
printf '\nFilesystem bytes (virtual size, used, available, use%%, mount):\n'
df -B1 --output=size,used,avail,pcent,target / | tail -n 1
printf '\nInode usage:\n'
df -ih /

printf '\n%s\n' '--- Active workload snapshot ---'
printf 'High-CPU processes can explain growth or make a directory scan slower:\n'
ps -eo pid,etime,pcpu,pmem,comm,args --sort=-pcpu 2>/dev/null | head -n "$((TOP + 1))"

if [ "$SUMMARY_ONLY" = 'false' ]; then
    printf '\n%s\n' '--- Largest known directories on the WSL root filesystem ---'
    printf 'Measuring only fixed known paths; the WSL root is not traversed. Each path has a maximum of %ss.\n' "$COMMAND_TIMEOUT_SECONDS"
    {
        for path in \
            /var/lib/docker \
            /var/lib/containers \
            /var/lib/postgresql \
            /var/lib/mysql \
            /var/lib/snapd \
            /var/lib/apt/lists \
            /var/cache/apt \
            /var/cache \
            /var/log \
            /home \
            /root \
            /usr/local \
            /opt \
            /srv \
            /tmp \
            /actions-runner \
            /opt/actions-runner; do
            print_known_path "$path"
        done
    } | sort -nr | head -n "$TOP" | print_sized_paths
else
    printf '\nKnown-folder and large-file scans skipped because -SummaryOnly was selected.\n'
fi

printf '\n%s\n' '--- Docker and persistent runner container storage ---'
if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker CLI is not installed in this distribution.\n'
elif ! run_with_timeout docker info >/dev/null 2>&1; then
    printf 'Docker daemon is not reachable within %ss.\n' "$COMMAND_TIMEOUT_SECONDS"
else
    printf 'Outer Docker logical usage (time-limited):\n'
    docker_df="$(run_with_timeout docker system df 2>&1)"
    docker_df_status=$?
    [ -z "$docker_df" ] || printf '%s\n' "$docker_df"
    if [ "$docker_df_status" -eq 124 ]; then
        printf 'Outer Docker usage query timed out after %ss.\n' "$COMMAND_TIMEOUT_SECONDS"
    fi

    runner_names="$(run_with_timeout docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '(actions-runner|wsl-runner|runner-wsl)' || true)"
    if [ -z "$runner_names" ]; then
        printf 'No persistent runner containers were discovered.\n'
    else
        while IFS= read -r runner_name; do
            [ -n "$runner_name" ] || continue
            printf '\nRunner container: %s\n' "$runner_name"
            runner_state="$(run_with_timeout docker inspect --format '{{.State.Status}}' "$runner_name" 2>/dev/null || true)"
            printf '  Outer state: %s\n' "${runner_state:-unknown}"
            printf '  Outer log configuration: '
            run_with_timeout docker inspect --format '{{json .HostConfig.LogConfig}}' "$runner_name" 2>/dev/null || printf 'unavailable\n'

            printf '  Resource-control environment:\n'
            runner_env="$(run_with_timeout docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$runner_name" 2>/dev/null |
                grep -E '^(RUNNER_DOCKER_|ACTIONS_RUNNER_HOOK_|RUNNER_JOB_ACTIVE_MARKER|RUNNER_MAINTENANCE_LOCK)' || true)"
            if [ -n "$runner_env" ]; then
                printf '%s\n' "$runner_env" | sed 's/^/    /'
            else
                printf '    none detected\n'
            fi

            mount_source="$(run_with_timeout docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{println .Source}}{{end}}{{end}}' "$runner_name" 2>/dev/null |
                head -n 1 || true)"
            if [ -n "$mount_source" ]; then
                printf '  Persistent nested-Docker path: %s\n' "$mount_source"
                printf '  Allocated path size: '
                print_timed_path_size "$mount_source" | sed 's/^/  /'
                if [ -d "$mount_source/vfs/dir" ]; then
                    layer_marks="$(run_with_timeout find "$mount_source/vfs/dir" -mindepth 1 -maxdepth 1 -type d -printf . 2>/dev/null || true)"
                    printf '  VFS full-copy layer directories: %s\n' "${#layer_marks}"
                fi
            else
                printf '  Persistent nested-Docker path: not found\n'
            fi

            printf '  Nested Docker driver and logging: '
            nested_info="$(run_with_timeout docker exec "$runner_name" docker info --format 'driver={{.Driver}} logging={{.LoggingDriver}} images={{.Images}} containers={{.Containers}}' 2>/dev/null || true)"
            printf '%s\n' "${nested_info:-unavailable}"
            printf '  Nested Docker logical usage:\n'
            nested_df="$(run_with_timeout docker exec "$runner_name" docker system df 2>&1)"
            nested_df_status=$?
            if [ -n "$nested_df" ]; then
                printf '%s\n' "$nested_df" | sed 's/^/    /'
            fi
            if [ "$nested_df_status" -eq 124 ]; then
                printf '    query timed out after %ss\n' "$COMMAND_TIMEOUT_SECONDS"
            fi
        done <<< "$runner_names"
    fi
fi

printf '\n%s\n' '--- System log and package metadata ---'
if command -v journalctl >/dev/null 2>&1; then
    journalctl --disk-usage 2>/dev/null || true
else
    printf 'systemd journal: journalctl is not installed\n'
fi
if command -v apt-get >/dev/null 2>&1; then
    printf 'APT archive cache: '
    du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}' || printf 'unknown\n'
fi

printf '\n%s\n' '--- Deleted files still held open by running processes ---'
if command -v lsof >/dev/null 2>&1; then
    lsof -nP +L1 2>/dev/null | grep -v '/memfd:' | head -n "$((TOP + 1))" || true
else
    printf 'Not checked: optional command lsof is not installed.\n'
fi

if [ "$SUMMARY_ONLY" = 'true' ]; then
    printf '\nLargest-file scan skipped because -SummaryOnly was selected.\n'
elif [ "$QUICK" = 'false' ]; then
    printf '\n%s\n' "--- Largest files (minimum ${MINIMUM_MB} MB) ---"
    printf 'Scanning every file on the WSL root filesystem (maximum %ss)...\n' "$COMMAND_TIMEOUT_SECONDS"
    file_output="$(run_with_timeout find / -xdev -type f -size +"${MINIMUM_MB}M" -printf '%s\t%p\n' 2>/dev/null)"
    file_status=$?
    if [ -n "$file_output" ]; then
        printf '%s\n' "$file_output" | sort -nr | head -n "$TOP" | print_sized_paths
    fi
    if [ "$file_status" -eq 124 ]; then
        printf 'Largest-file scan timed out after %ss; partial results are shown.\n' "$COMMAND_TIMEOUT_SECONDS"
    fi
else
    printf '\nLargest-file scan skipped because -Quick was selected.\n'
fi

printf '\n%s\n' '--- Notes ---'
printf '%s\n' 'Directory and file sizes are allocated Linux filesystem usage, not apparent file size.'
printf '%s\n' 'Windows-mounted paths such as /mnt/c are excluded by the one-filesystem scans.'
printf '%s\n' 'The filesystem Size reported by df is the VHDX virtual ceiling, not space currently occupied on Windows.'
printf '%s\n' 'A VHDX can remain much larger than Linux used space until fstrim and host compaction run.'
printf '%s\n' 'Docker logical sizes can severely understate physical use when the nested storage driver is vfs.'
'@

# Encode the Bash program so Windows PowerShell and wsl.exe cannot reinterpret
# its quotes, variables, redirections, or pipeline operators.
$linuxAnalyzerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linuxAnalyzer))
$linuxBootstrap = "printf '%s' '$linuxAnalyzerBase64' | base64 --decode | bash -s -- $Top $MinimumFileSizeMB $quickValue $summaryOnlyValue $CommandTimeoutSeconds"

Write-ReportLine "WSL SPACE ANALYSIS" Cyan
Write-ReportLine ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
Write-ReportLine ("Computer: {0}" -f $env:COMPUTERNAME)
Write-ReportLine ("Targets: {0}" -f (($targets.Name) -join ", "))
Write-ReportLine ("Per-command timeout: {0} seconds" -f $CommandTimeoutSeconds)

$systemDriveName = $env:SystemDrive.TrimEnd(':')
$systemDrive = Get-PSDrive -Name $systemDriveName -ErrorAction SilentlyContinue
if ($null -ne $systemDrive) {
    Write-ReportLine ("Windows {0} free space: {1}; used space: {2}" -f $env:SystemDrive, (Format-Bytes $systemDrive.Free), (Format-Bytes $systemDrive.Used)) Yellow
    if ($systemDrive.Free -lt 25GB) {
        Write-ReportLine "WARNING: Windows system drive has less than 25 GB free. Avoid unbounded scans and new container builds until space is reclaimed." Red
    }
}

$hadFailures = $false
foreach ($target in $targets) {
    Write-ReportLine ""
    Write-ReportLine "============================================================" Cyan
    Write-ReportLine ("Distribution: {0}" -f $target.Name) Cyan
    Write-ReportLine "============================================================" Cyan
    Write-ReportLine ("Registered base path: {0}" -f $target.BasePath)

    if ($null -ne $target.VhdPath -and (Test-Path -LiteralPath $target.VhdPath -PathType Leaf)) {
        $vhd = Get-Item -LiteralPath $target.VhdPath -Force
        Write-ReportLine ("VHDX path: {0}" -f $vhd.FullName)
        Write-ReportLine ("VHDX host file size: {0} ({1:N0} bytes)" -f (Format-Bytes $vhd.Length), $vhd.Length) Yellow
        Write-ReportLine ("VHDX last modified: {0}" -f $vhd.LastWriteTime)
        Write-ReportLine ("VHDX attributes: {0}" -f $vhd.Attributes)
    } else {
        Write-ReportLine "VHDX file: not found below the registered base path" Red
    }

    Write-ReportLine ""
    Write-ReportLine "Starting read-only Linux scan..." Yellow
    if ($SummaryOnly) {
        Write-ReportLine "Summary-only mode skips directory and large-file tree walks but includes time-limited Docker and runner-container analysis." DarkGray
    } else {
        Write-ReportLine "Only fixed known folders are measured; no root-wide directory traversal is performed." DarkGray
    }

    & wsl.exe --distribution $target.Name --user root --exec sh -c $linuxBootstrap 2>&1 |
        ForEach-Object { Write-ReportLine ([string]$_) }
    $linuxExitCode = $LASTEXITCODE

    if ($linuxExitCode -ne 0) {
        $hadFailures = $true
        Write-ReportLine ("Linux analysis failed with exit code {0}." -f $linuxExitCode) Red
    }
}

$reportLines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ""
Write-Host ("Report saved to: {0}" -f $OutputPath) -ForegroundColor Green

if ($hadFailures) {
    exit 1
}
