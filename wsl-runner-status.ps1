#Requires -Version 5.1

<#
.SYNOPSIS
    Reports whether custom WSL GitHub Actions runners are idle.

.DESCRIPTION
    Performs read-only checks against WSL runner distributions. The script
    detects active Runner.Worker processes, job-active markers, maintenance
    locks, and Runner.Listener processes. By default it also asks GitHub for
    each configured runner's current online/busy state through the GitHub CLI.

    Stopped distributions are not started. By default, only WSL 2
    distributions registered below C:\WSL are checked.

    Exit codes:
      0 - Every selected runner is idle or its distribution is stopped.
      1 - At least one runner is busy or maintenance is active.
      2 - At least one running runner could not be verified safely.

.PARAMETER DistroName
    One or more registered WSL distribution names. When omitted, checks all
    WSL 2 distributions whose registered base path is below RunnerRoot.

.PARAMETER RunnerRoot
    Windows folder containing custom runner distributions. Default: C:\WSL.

.PARAMETER LocalOnly
    Skips GitHub CLI verification. Local Runner.Worker, marker, lock, and
    listener checks are still performed.

.PARAMETER AsJson
    Emits the result objects as JSON instead of a formatted table.

.EXAMPLE
    .\wsl-runner-status.ps1

.EXAMPLE
    .\wsl-runner-status.ps1 -LocalOnly

.EXAMPLE
    .\wsl-runner-status.ps1 -DistroName sales-pulse,ontograph

.EXAMPLE
    .\wsl-runner-status.ps1 -AsJson
#>

[CmdletBinding()]
param(
    [string[]]$DistroName,

    [string]$RunnerRoot = "C:\WSL",

    [switch]$LocalOnly,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-NormalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalPath = $Path -replace '^\\\\\?\\', ''
    return [System.IO.Path]::GetFullPath($normalPath).TrimEnd('\')
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalPath = ConvertTo-NormalPath $Path
    $normalRoot = ConvertTo-NormalPath $Root
    return $normalPath.Equals($normalRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $normalPath.StartsWith("$normalRoot\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-WslRegistrations {
    $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    $registrations = @()

    if (-not (Test-Path -LiteralPath $registryPath)) {
        return $registrations
    }

    foreach ($key in Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue) {
        try {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            $name = ([string]$properties.DistributionName).Replace("`0", "").Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $registrations += [pscustomobject]@{
                Name = $name
                BasePath = ConvertTo-NormalPath ([string]$properties.BasePath)
                Version = [int]$properties.Version
            }
        } catch {
            Write-Warning "Could not read WSL registration '$($key.PSChildName)': $($_.Exception.Message)"
        }
    }

    return $registrations
}

function Get-WslRunningNames {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $output = @(& wsl.exe --list --running --quiet 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe could not list running distributions (exit code $LASTEXITCODE)."
    }

    foreach ($line in $output) {
        $name = ([string]$line).Replace("`0", "").Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$names.Add($name)
        }
    }

    return $names
}

function ConvertFrom-Base64Utf8 {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)).TrimStart([char]0xFEFF)
}

function Invoke-RunnerProbe {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionName,
        [Parameter(Mandatory = $true)][string]$Bootstrap
    )

    $output = @(& wsl.exe --distribution $DistributionName --user root --exec sh -c $Bootstrap 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            Success = $false
            Error = (($output | ForEach-Object { ([string]$_).Replace("`0", "") }) -join " ").Trim()
        }
    }

    $line = [string]($output | Select-Object -Last 1)
    $parts = $line.Replace("`0", "").Trim().Split('|')
    if ($parts.Count -ne 7 -or $parts[0] -ne "runner-probe-v1") {
        return [pscustomobject]@{
            Success = $false
            Error = "The WSL runner probe returned an unexpected response."
        }
    }

    try {
        $runnerConfigJson = ConvertFrom-Base64Utf8 $parts[6]
        $runnerConfig = $null
        if (-not [string]::IsNullOrWhiteSpace($runnerConfigJson)) {
            $runnerConfig = $runnerConfigJson | ConvertFrom-Json
        }

        return [pscustomobject]@{
            Success = $true
            Configured = $parts[1] -eq "1"
            Listener = $parts[2] -eq "1"
            Worker = $parts[3] -eq "1"
            JobMarker = $parts[4] -eq "1"
            MaintenanceLock = $parts[5] -eq "1"
            RunnerConfig = $runnerConfig
            Error = ""
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = "Could not parse the runner probe response: $($_.Exception.Message)"
        }
    }
}

function Get-GitHubRunnerEndpoint {
    param([Parameter(Mandatory = $true)][string]$GitHubUrl)

    try {
        $uri = [Uri]$GitHubUrl
    } catch {
        return $null
    }

    if ($uri.Host -ne "github.com") {
        return $null
    }

    $segments = @($uri.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ })
    if ($segments.Count -eq 1) {
        return "/orgs/$($segments[0])/actions/runners?per_page=100"
    }
    if ($segments.Count -ge 2) {
        return "/repos/$($segments[0])/$($segments[1])/actions/runners?per_page=100"
    }

    return $null
}

function Get-GitHubRunnerList {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$GhPath
    )

    $output = @(& $GhPath api --paginate --slurp $Endpoint 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            Success = $false
            Runners = @()
            Error = (($output | ForEach-Object { [string]$_ }) -join " ").Trim()
        }
    }

    try {
        $pages = (($output -join "`n") | ConvertFrom-Json)
        $runners = @()
        foreach ($page in @($pages)) {
            if ($null -ne $page.runners) {
                $runners += @($page.runners)
            }
        }

        return [pscustomobject]@{
            Success = $true
            Runners = $runners
            Error = ""
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Runners = @()
            Error = "Could not parse GitHub runner data: $($_.Exception.Message)"
        }
    }
}

if ($null -eq (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found."
}

$allRegistrations = @(Get-WslRegistrations | Where-Object { $_.Version -eq 2 })
if ($null -ne $DistroName -and $DistroName.Count -gt 0) {
    $targets = @($allRegistrations | Where-Object { $_.Name -in $DistroName })
    $missing = @($DistroName | Where-Object { $_ -notin $allRegistrations.Name })
    if ($missing.Count -gt 0) {
        throw "Unknown or non-WSL-2 distribution name(s): $($missing -join ', ')"
    }
} else {
    $targets = @($allRegistrations | Where-Object { Test-PathWithinRoot $_.BasePath $RunnerRoot })
}

if ($targets.Count -eq 0) {
    throw "No WSL 2 runner distributions matched the requested filters."
}

$runningNames = Get-WslRunningNames
$probeScript = @'
set -u
export LC_ALL=C

runner_file="$(find /home -maxdepth 3 -type f -path '*/actions-runner/.runner' -print -quit 2>/dev/null)"
configured=0
listener=0
worker=0
job_marker=0
maintenance_lock=0
config_base64=""

if [ -n "${runner_file}" ]; then
    configured=1
    runner_user="$(stat -c '%U' "${runner_file}" 2>/dev/null || true)"
    if [ -n "${runner_user}" ]; then
        pgrep -u "${runner_user}" -f '[R]unner.Listener' >/dev/null 2>&1 && listener=1
        pgrep -u "${runner_user}" -f '[R]unner.Worker' >/dev/null 2>&1 && worker=1
    fi
    config_base64="$(base64 -w 0 "${runner_file}" 2>/dev/null || base64 "${runner_file}" | tr -d '\n')"
fi

marker_file="$(find /run -maxdepth 2 -type f -name job-active -print -quit 2>/dev/null)"
[ -n "${marker_file}" ] && job_marker=1

lock_file="$(find /run -maxdepth 2 -type f -name maintenance.lock -print -quit 2>/dev/null)"
if [ -n "${lock_file}" ]; then
    exec 8<>"${lock_file}"
    if flock -n 8; then
        flock -u 8
    else
        maintenance_lock=1
    fi
fi

printf 'runner-probe-v1|%s|%s|%s|%s|%s|%s\n' \
    "${configured}" "${listener}" "${worker}" "${job_marker}" \
    "${maintenance_lock}" "${config_base64}"
'@
$probeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probeScript))
$probeBootstrap = "printf '%s' '$probeBase64' | base64 --decode | bash"

$ghCommand = $null
if (-not $LocalOnly) {
    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
}
$githubCache = @{}
$results = @()

foreach ($target in $targets | Sort-Object Name) {
    if (-not $runningNames.Contains($target.Name)) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "OFFLINE"
            SafeToCompact = $true
            Local = "Stopped"
            GitHub = "Not checked"
            Listener = "Offline"
            Runner = ""
            Scope = ""
            Details = "The distribution is stopped and was not started."
        }
        continue
    }

    $probe = Invoke-RunnerProbe -DistributionName $target.Name -Bootstrap $probeBootstrap
    if (-not $probe.Success) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Probe failed"
            GitHub = "Not checked"
            Listener = "Unknown"
            Runner = ""
            Scope = ""
            Details = $probe.Error
        }
        continue
    }

    $runnerName = ""
    $githubUrl = ""
    $agentId = $null
    if ($null -ne $probe.RunnerConfig) {
        $runnerName = [string]$probe.RunnerConfig.agentName
        $githubUrl = [string]$probe.RunnerConfig.gitHubUrl
        $agentId = $probe.RunnerConfig.agentId
    }

    if (-not $probe.Configured) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Runner not configured"
            GitHub = "Not checked"
            Listener = "Not detected"
            Runner = ""
            Scope = ""
            Details = "No /home/*/actions-runner/.runner file was found."
        }
        continue
    }

    if ($probe.Worker -or $probe.JobMarker) {
        $signals = @()
        if ($probe.Worker) { $signals += "Runner.Worker" }
        if ($probe.JobMarker) { $signals += "job-active marker" }
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "BUSY"
            SafeToCompact = $false
            Local = "Busy"
            GitHub = "Not required"
            Listener = $(if ($probe.Listener) { "Online" } else { "Not detected" })
            Runner = $runnerName
            Scope = $githubUrl
            Details = "Active signal(s): $($signals -join ', ')."
        }
        continue
    }

    if ($probe.MaintenanceLock) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "MAINTENANCE"
            SafeToCompact = $false
            Local = "Maintenance"
            GitHub = "Not required"
            Listener = $(if ($probe.Listener) { "Online" } else { "Not detected" })
            Runner = $runnerName
            Scope = $githubUrl
            Details = "The runner maintenance lock is held."
        }
        continue
    }

    if (-not $probe.Listener) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "No active job"
            GitHub = "Not checked"
            Listener = "Not detected"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "The distribution is running, but Runner.Listener was not detected."
        }
        continue
    }

    if ($LocalOnly) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "IDLE"
            SafeToCompact = $true
            Local = "Idle"
            GitHub = "Skipped"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "Local checks found no active job or maintenance."
        }
        continue
    }

    if ($null -eq $ghCommand) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = "Unavailable"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "GitHub CLI was not found. Install/authenticate gh or use -LocalOnly."
        }
        continue
    }

    $endpoint = Get-GitHubRunnerEndpoint $githubUrl
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = "Unsupported scope"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "Could not derive a GitHub Actions runner API endpoint."
        }
        continue
    }

    if (-not $githubCache.ContainsKey($endpoint)) {
        $githubCache[$endpoint] = Get-GitHubRunnerList -Endpoint $endpoint -GhPath $ghCommand.Source
    }
    $githubList = $githubCache[$endpoint]
    if (-not $githubList.Success) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = "API error"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = $githubList.Error
        }
        continue
    }

    $githubRunner = $null
    if ($null -ne $agentId) {
        $githubRunner = @($githubList.Runners | Where-Object { "$($_.id)" -eq "$agentId" }) | Select-Object -First 1
    }
    if ($null -eq $githubRunner) {
        $githubRunner = @($githubList.Runners | Where-Object { $_.name -eq $runnerName }) | Select-Object -First 1
    }

    if ($null -eq $githubRunner) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = "Runner not found"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "GitHub did not return this configured runner."
        }
        continue
    }

    if ([bool]$githubRunner.busy) {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "BUSY"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = "Busy"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "GitHub reports that the runner is busy."
        }
    } elseif ([string]$githubRunner.status -eq "online") {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "IDLE"
            SafeToCompact = $true
            Local = "Idle"
            GitHub = "Idle"
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "Local and GitHub checks agree that the runner is idle."
        }
    } else {
        $results += [pscustomobject]@{
            Distro = $target.Name
            Decision = "UNKNOWN"
            SafeToCompact = $false
            Local = "Idle"
            GitHub = [string]$githubRunner.status
            Listener = "Online"
            Runner = $runnerName
            Scope = $githubUrl
            Details = "Local listener state and GitHub runner state do not agree."
        }
    }
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
} else {
    $results |
        Select-Object Distro, Decision, SafeToCompact, Local, GitHub, Listener, Runner |
        Format-Table -AutoSize |
        Out-Host

    Write-Host ""
    foreach ($result in $results | Where-Object { $_.Decision -notin @("IDLE", "OFFLINE") }) {
        Write-Host ("{0}: {1}" -f $result.Distro, $result.Details) -ForegroundColor Yellow
    }

    $idleCount = @($results | Where-Object { $_.Decision -eq "IDLE" }).Count
    $offlineCount = @($results | Where-Object { $_.Decision -eq "OFFLINE" }).Count
    $busyCount = @($results | Where-Object { $_.Decision -in @("BUSY", "MAINTENANCE") }).Count
    $unknownCount = @($results | Where-Object { $_.Decision -eq "UNKNOWN" }).Count
    Write-Host ("Summary: {0} idle, {1} offline, {2} busy/maintenance, {3} unknown." -f $idleCount, $offlineCount, $busyCount, $unknownCount)
}

if (@($results | Where-Object { $_.Decision -in @("BUSY", "MAINTENANCE") }).Count -gt 0) {
    exit 1
}
if (@($results | Where-Object { $_.Decision -eq "UNKNOWN" }).Count -gt 0) {
    exit 2
}
exit 0
