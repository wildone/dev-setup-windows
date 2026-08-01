#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Safely compacts idle custom WSL runner VHDX files.

.DESCRIPTION
    By default, uses wsl-runner-status.ps1 to find idle GitHub Actions runners
    registered below C:\WSL. If any runner is busy, under maintenance, or
    unknown, no compaction is attempted. When the complete fleet is idle and
    -AllowWslShutdown is supplied, runner filesystems are trimmed, keepalives are
    paused, the shared WSL 2 utility VM is shut down, runner VHDX files are
    compacted, and previously running keepalives are restored. Pairing
    -AllowWslShutdown with -Force deliberately overrides runner-state blockers
    and terminates active jobs.

    Use -All to request the original disruptive behavior: prune Docker Desktop
    as requested, stop Docker Desktop and every WSL distribution, and compact all
    VHDX files below the Docker, WSL, and RunnerRoot folders.

    Uses Windows' built-in WSL and DiskPart tools, so Optimize-VHD and the Hyper-V
    PowerShell module are not required. Run from an elevated Windows PowerShell
    or PowerShell terminal.

.PARAMETER DockerPrune
    Ask (default), None, Standard, or Volumes. Standard removes unused Docker
    objects but preserves volumes. Volumes also removes unused Docker volumes.
    This option is used only with -All.

.PARAMETER All
    Uses the original full-compaction mode, which stops Docker Desktop and every
    WSL distribution. Without this switch, runner VHDX compaction proceeds only
    when every custom runner is verified idle or offline.

.PARAMETER RunnerRoot
    Windows folder containing custom runner WSL distributions. Default: C:\WSL.

.PARAMETER LocalOnly
    Uses only local runner activity checks. By default, local state must also be
    verified against GitHub through gh.

.PARAMETER AllowWslShutdown
    Allows safe runner mode to stop Docker Desktop, every WSL distribution, and
    the shared WSL 2 utility VM after every custom runner is verified idle, or
    when runner-state blockers are explicitly overridden with -Force. Required
    because DiskPart cannot compact a VHDX still attached to that VM.

.PARAMETER Force
    Skips confirmation prompts. In runner mode, only the combination of -Force
    and -AllowWslShutdown also overrides BUSY, MAINTENANCE, or UNKNOWN runner
    states and bypasses runner activity probes. Active GitHub Actions job
    attempts will be interrupted; configured retry automation can reschedule them.

.PARAMETER NoRestartRunners
    Does not restart idle runner distributions or their Windows keepalive tasks
    after compaction. Scheduled tasks remain enabled for a future trigger.

.EXAMPLE
    .\wsl-compact.ps1 -ListOnly

.EXAMPLE
    .\wsl-compact.ps1 -AllowWslShutdown -Force

.EXAMPLE
    .\wsl-compact.ps1 -All -DockerPrune Standard

.EXAMPLE
    .\wsl-compact.ps1 -All -DockerPrune Volumes -Force
#>

[CmdletBinding()]
param(
    [ValidateSet("Ask", "None", "Standard", "Volumes")]
    [string]$DockerPrune = "Ask",

    [switch]$All,
    [string]$RunnerRoot = "C:\WSL",
    [switch]$LocalOnly,
    [switch]$AllowWslShutdown,
    [switch]$Force,
    [switch]$NoRestartDocker,
    [switch]$NoRestartRunners,
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dockerRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Docker"
$wslRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "wsl"
$runnerRootNormal = [System.IO.Path]::GetFullPath(($RunnerRoot -replace '^\\\\\?\\', '')).TrimEnd('\')
$targetRoots = @($dockerRoot, $wslRoot, $runnerRootNormal) | Select-Object -Unique
$script:DockerExe = $null
$script:HadFailures = $false
$script:HadWarnings = $false

function Write-Step {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Cyan
}

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
    return $normalPath.Equals($normalRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalPath.StartsWith("$normalRoot\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FolderLogicalBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [int64]0
    }

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return [int64]0
    }

    $measurement = $files | Measure-Object -Property Length -Sum
    if ($null -eq $measurement -or $null -eq $measurement.Sum) {
        return [int64]0
    }

    return [int64]$measurement.Sum
}

function Format-GB {
    param([int64]$Bytes)
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Find-DockerExecutable {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $knownPath = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
    if (Test-Path -LiteralPath $knownPath -PathType Leaf) {
        return $knownPath
    }

    return $null
}

function Invoke-DockerCommandWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    if ($null -eq $script:DockerExe) {
        throw "Docker CLI is unavailable."
    }

    $id = [guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $env:TEMP "wsl-compact-docker-$id.out"
    $stderrPath = Join-Path $env:TEMP "wsl-compact-docker-$id.err"
    $process = $null

    try {
        $process = Start-Process -FilePath $script:DockerExe -ArgumentList $Arguments -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit()
            return [PSCustomObject]@{
                TimedOut = $true
                ExitCode = $null
                Output   = ""
                Error    = "Docker command timed out after $TimeoutSeconds seconds."
            }
        }

        $stdout = ""
        $stderr = ""
        if (Test-Path -LiteralPath $stdoutPath) {
            $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrPath) {
            $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        }

        return [PSCustomObject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            Output   = $stdout
            Error    = $stderr
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-DockerEngine {
    $result = Invoke-DockerCommandWithTimeout -Arguments @("info", "--format", "{{.ServerVersion}}") -TimeoutSeconds 15
    if ($result.TimedOut) {
        Write-Warning "Docker Engine health check timed out. Restart Docker Desktop before retrying Docker pruning."
        return $false
    }

    return ($result.ExitCode -eq 0)
}

function Assert-Dependencies {
    Write-Step "Checking required Windows tools..."

    foreach ($commandName in @("wsl.exe", "diskpart.exe")) {
        if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "Required Windows tool '$commandName' was not found. Install/enable WSL and retry."
        }
        Write-Host " Found: $commandName" -ForegroundColor DarkGray
    }

    if ($All) {
        $script:DockerExe = Find-DockerExecutable
        if ($null -ne $script:DockerExe) {
            Write-Host " Found: Docker CLI ($script:DockerExe)" -ForegroundColor DarkGray
        } else {
            Write-Warning "Docker CLI was not found. Docker pruning and graceful Docker Desktop restart will be unavailable."
        }
    } else {
        $statusScript = Join-Path $PSScriptRoot "wsl-runner-status.ps1"
        if (-not (Test-Path -LiteralPath $statusScript -PathType Leaf)) {
            throw "Required runner status script was not found: $statusScript"
        }
        Write-Host " Found: wsl-runner-status.ps1" -ForegroundColor DarkGray

        foreach ($commandName in @("Get-ScheduledTask", "Stop-ScheduledTask", "Start-ScheduledTask")) {
            if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "Required ScheduledTasks command '$commandName' was not found."
            }
        }
        Write-Host " Found: ScheduledTasks management commands" -ForegroundColor DarkGray

        $script:DockerExe = Find-DockerExecutable
        if ($null -ne $script:DockerExe) {
            Write-Host " Found: Docker CLI ($script:DockerExe)" -ForegroundColor DarkGray
        } elseif ($null -ne (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
            throw "Docker Desktop is running but docker.exe was not found, so it cannot be stopped and restarted safely."
        }
    }
}

function Get-WslRegistrations {
    $registrations = @()
    $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"

    if (-not (Test-Path -LiteralPath $registryPath)) {
        return $registrations
    }

    foreach ($key in Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue) {
        try {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            if ([string]::IsNullOrWhiteSpace([string]$properties.DistributionName) -or
                [string]::IsNullOrWhiteSpace([string]$properties.BasePath)) {
                continue
            }

            $registrations += [PSCustomObject]@{
                Name     = ([string]$properties.DistributionName).Replace("`0", "").Trim()
                BasePath = ConvertTo-NormalPath ([string]$properties.BasePath)
                Version  = [int]$properties.Version
            }
        } catch {
            Write-Warning "Could not read WSL registration '$($key.PSChildName)': $($_.Exception.Message)"
        }
    }

    return $registrations
}

function Get-VhdTargets {
    param([array]$Registrations)

    $targets = @()
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $targetRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-Warning "Target folder does not exist: $root"
            continue
        }

        foreach ($file in Get-ChildItem -LiteralPath $root -Filter "*.vhdx" -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $fullPath = ConvertTo-NormalPath $file.FullName
            if (-not $seenPaths.Add($fullPath)) {
                continue
            }

            $registration = $null
            foreach ($candidate in $Registrations) {
                if (Test-PathWithinRoot -Path $fullPath -Root $candidate.BasePath) {
                    $registration = $candidate
                    break
                }
            }

            $kind = "WSL"
            if (Test-PathWithinRoot -Path $fullPath -Root $dockerRoot) {
                $kind = "Docker"
            }

            $distroName = $null
            if ($null -ne $registration) {
                $distroName = $registration.Name
            }

            $targets += [PSCustomObject]@{
                Kind       = $kind
                DistroName = $distroName
                Path       = $fullPath
                Before     = [int64]$file.Length
                Sparse     = (($file.Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0)
            }
        }
    }

    return @($targets | Sort-Object Kind, Path)
}

function Invoke-WslTrim {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    Write-Host " Trimming: $DistroName" -ForegroundColor Gray
    $id = [guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $env:TEMP "wsl-trim-$id.out"
    $stderrPath = Join-Path $env:TEMP "wsl-trim-$id.err"
    $process = $null

    try {
        # Direct WSL --exec does not always include /sbin in PATH, even for root.
        $process = Start-Process -FilePath "wsl.exe" -ArgumentList @(
            "--distribution", $DistroName,
            "--user", "root",
            "--exec", "/sbin/fstrim", "-av"
        ) -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        if (-not $process.WaitForExit(45000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $script:HadWarnings = $true
            Write-Warning "fstrim timed out for '$DistroName' after 45 seconds. Compaction will continue, but its VHD may reclaim less space."
            return
        }
        $process.WaitForExit()

        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
        } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            [string](Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
        } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr -ForegroundColor DarkGray
        }

        if ($process.ExitCode -eq 0) {
            return
        }

        $script:HadWarnings = $true
        Write-Warning "fstrim failed for '$DistroName' (exit code $($process.ExitCode)). Its VHD may reclaim less space."
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-DockerPruneChoice {
    if ($DockerPrune -ne "Ask") {
        return $DockerPrune
    }

    Write-Host "`nDocker cleanup options:" -ForegroundColor Yellow
    Write-Host " [N] None      - compact space that Docker has already freed"
    Write-Host " [S] Standard  - remove stopped containers, unused images/networks, and build cache"
    Write-Host " [V] Volumes   - Standard cleanup plus unused volumes (persistent data may be deleted)" -ForegroundColor Red
    $answer = (Read-Host "Choose N, S, or V [N]").Trim().ToUpperInvariant()

    switch ($answer) {
        "S" { return "Standard" }
        "V" {
            $confirmation = Read-Host "Type DELETE UNUSED VOLUMES to confirm"
            if ($confirmation -ceq "DELETE UNUSED VOLUMES") {
                return "Volumes"
            }
            Write-Warning "Volume deletion was not confirmed; using Standard cleanup."
            return "Standard"
        }
        default { return "None" }
    }
}

function Invoke-DockerPrune {
    param([Parameter(Mandatory = $true)][string]$Mode)

    if ($Mode -eq "None") {
        Write-Host " Docker object pruning skipped." -ForegroundColor Yellow
        return
    }

    if ($null -eq $script:DockerExe) {
        throw "Docker pruning was requested, but docker.exe could not be found."
    }

    if (-not (Test-DockerEngine)) {
        throw "Docker Engine is not available. Start Docker Desktop, then run this script again."
    }

    $arguments = @("system", "prune", "--all", "--force")
    if ($Mode -eq "Volumes") {
        $arguments += "--volumes"
    }

    Write-Host " Running: docker $($arguments -join ' ')" -ForegroundColor Gray
    & $script:DockerExe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker prune failed with exit code $LASTEXITCODE. Compaction has been stopped."
    }
}

function Stop-DockerDesktopForCompaction {
    Write-Step "Stopping Docker Desktop..."
    if ($null -ne $script:DockerExe) {
        $stopResult = Invoke-DockerCommandWithTimeout -Arguments @("desktop", "stop") -TimeoutSeconds 60
        if ($stopResult.TimedOut -or $stopResult.ExitCode -ne 0) {
            Write-Warning "Docker Desktop CLI stop failed; WSL shutdown will still stop its WSL VM."
        }
    }
}

function Stop-WslForCompaction {
    Write-Step "Stopping the shared WSL 2 utility VM to release VHDX handles..."
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed with exit code $LASTEXITCODE. No disks were compacted."
    }

    Start-Sleep -Seconds 3
}

function Stop-DockerAndWsl {
    Write-Step "Stopping Docker Desktop and WSL to release VHDX handles..."
    Stop-DockerDesktopForCompaction
    Stop-WslForCompaction
}

function Compact-VhdWithDiskPart {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "VHDX disappeared before compaction: $Path"
    }

    $file = Get-Item -LiteralPath $Path -Force
    if (($file.Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0) {
        throw "VHDX is marked as an NTFS sparse file and was skipped to avoid unsafe conversion: $Path"
    }

    $escapedPath = $Path.Replace('"', '""')
    $lastFailure = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $diskPartScript = Join-Path $env:TEMP ("wsl-compact-{0}.txt" -f ([guid]::NewGuid().ToString("N")))

        try {
            @(
                "select vdisk file=`"$escapedPath`""
                "compact vdisk"
                "exit"
            ) | Set-Content -LiteralPath $diskPartScript -Encoding ASCII

            $output = & diskpart.exe /s $diskPartScript 2>&1
            $exitCode = $LASTEXITCODE
            $outputText = ($output | Out-String).Trim()

            $hasError = $exitCode -ne 0 -or
                $outputText -match '(?im)DiskPart has encountered an error|Virtual Disk Service error|The system cannot find|is not valid|failed'
            $hasSuccess = $outputText -match '(?im)successfully compacted'

            if (-not $hasError -and $hasSuccess) {
                return
            }

            $lastFailure = "DiskPart failed for '$Path' on attempt $attempt.`n$outputText"
        } finally {
            Remove-Item -LiteralPath $diskPartScript -Force -ErrorAction SilentlyContinue
        }

        if ($attempt -lt 3) {
            Write-Host "  DiskPart did not complete; retrying in 2 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }

    throw $lastFailure
}

function Start-DockerDesktop {
    if ($null -eq $script:DockerExe) {
        Write-Warning "Docker CLI is unavailable, so Docker Desktop could not be restarted automatically."
        return
    }

    Write-Step "Restarting Docker Desktop..."
    $startResult = Invoke-DockerCommandWithTimeout -Arguments @("desktop", "start") -TimeoutSeconds 60
    if ($startResult.TimedOut -or $startResult.ExitCode -ne 0) {
        $script:HadFailures = $true
        Write-Warning "Docker Desktop did not restart successfully. Start it manually."
    }
}

function Invoke-RunnerStatusCheck {
    param([string]$DistributionName)

    $statusScript = Join-Path $PSScriptRoot "wsl-runner-status.ps1"
    $arguments = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", $statusScript
        "-RunnerRoot", $runnerRootNormal
        "-AsJson"
    )
    if ($LocalOnly) {
        $arguments += "-LocalOnly"
    }
    if (-not [string]::IsNullOrWhiteSpace($DistributionName)) {
        $arguments += @("-DistroName", $DistributionName)
    }

    $id = [guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $env:TEMP "wsl-runner-status-$id.out"
    $stderrPath = Join-Path $env:TEMP "wsl-runner-status-$id.err"
    $process = $null

    try {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
            -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $statusExitCode = $process.ExitCode
        $json = if (Test-Path -LiteralPath $stdoutPath) {
            Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        } else {
            ""
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        } else {
            ""
        }

        try {
            $parsed = $json | ConvertFrom-Json
        } catch {
            $details = @($json.Trim(), $stderr.Trim()) | Where-Object { $_ }
            throw "Runner status check failed with exit code $statusExitCode and did not return valid JSON.`n$($details -join "`n")"
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Verbose ("Runner status stderr: {0}" -f $stderr.Trim())
        }

        return @($parsed)
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ForcedRunnerStatuses {
    param([Parameter(Mandatory = $true)][array]$Registrations)

    $runnerRegistrations = @($Registrations | Where-Object {
        $_.Version -eq 2 -and (Test-PathWithinRoot -Path $_.BasePath -Root $runnerRootNormal)
    })
    if ($runnerRegistrations.Count -eq 0) {
        throw "No WSL 2 runner distributions were found below '$runnerRootNormal'."
    }

    return @($runnerRegistrations | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Distro       = [string]$_.Name
            Decision     = "FORCED"
            SafeToCompact = $false
            Details      = "Runner activity was deliberately not checked."
        }
    })
}

function Get-IdleRunnerVhdTargets {
    param(
        [Parameter(Mandatory = $true)][array]$Statuses,
        [Parameter(Mandatory = $true)][array]$Registrations,
        [switch]$IncludeUnsafe
    )

    $targets = @()
    $eligibleStatuses = if ($IncludeUnsafe) {
        @($Statuses)
    } else {
        @($Statuses | Where-Object { [bool]$_.SafeToCompact })
    }

    foreach ($status in $eligibleStatuses) {
        $registration = $Registrations |
            Where-Object { $_.Name -eq [string]$status.Distro } |
            Select-Object -First 1
        if ($null -eq $registration) {
            Write-Warning "No WSL registration was found for '$($status.Distro)'; it will be skipped."
            continue
        }

        $files = @(Get-ChildItem -LiteralPath $registration.BasePath -Filter "*.vhdx" -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            Write-Warning "No VHDX file was found for '$($status.Distro)' below '$($registration.BasePath)'."
            continue
        }

        foreach ($file in $files) {
            $targets += [PSCustomObject]@{
                Kind       = "Runner"
                DistroName = [string]$status.Distro
                Decision   = [string]$status.Decision
                Path       = ConvertTo-NormalPath $file.FullName
                Before     = [int64]$file.Length
                Sparse     = (($file.Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0)
            }
        }
    }

    return @($targets | Sort-Object DistroName, Path)
}

function Start-WslDistribution {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    Write-Host " Restarting runner distro: $DistroName" -ForegroundColor Gray
    & wsl.exe --distribution $DistroName --user root --exec /bin/true 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        $script:HadFailures = $true
        Write-Warning "Could not restart '$DistroName' (exit code $LASTEXITCODE)."
        return
    }

    Start-Sleep -Seconds 2
}

function Suspend-RunnerKeepalive {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $taskName = "WSL Runner Autostart - $DistroName"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [PSCustomObject]@{
            TaskName = $taskName
            Found = $false
            WasRunning = $false
            Suspended = $true
            Error = ""
        }
    }

    $wasRunning = [string]$task.State -eq "Running"
    if (-not $wasRunning) {
        return [PSCustomObject]@{
            TaskName = $taskName
            Found = $true
            WasRunning = $false
            Suspended = $true
            Error = ""
        }
    }

    Write-Host " Pausing Windows keepalive task: $taskName" -ForegroundColor Gray
    try {
        Stop-ScheduledTask -InputObject $task -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            TaskName = $taskName
            Found = $true
            WasRunning = $true
            Suspended = $false
            Error = $_.Exception.Message
        }
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $current = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -eq $current -or [string]$current.State -ne "Running") {
            return [PSCustomObject]@{
                TaskName = $taskName
                Found = $true
                WasRunning = $true
                Suspended = $true
                Error = ""
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [PSCustomObject]@{
        TaskName = $taskName
        Found = $true
        WasRunning = $true
        Suspended = $false
        Error = "The scheduled task remained in the Running state for more than 15 seconds."
    }
}

function Restore-RunnerKeepalive {
    param([Parameter(Mandatory = $true)]$KeepaliveState)

    if (-not [bool]$KeepaliveState.Found -or -not [bool]$KeepaliveState.WasRunning) {
        return $false
    }

    Write-Host " Restarting Windows keepalive task: $($KeepaliveState.TaskName)" -ForegroundColor Gray
    try {
        Start-ScheduledTask -TaskName ([string]$KeepaliveState.TaskName) -ErrorAction Stop
        Start-Sleep -Seconds 2
        return $true
    } catch {
        $script:HadFailures = $true
        Write-Warning "Could not restart '$($KeepaliveState.TaskName)': $($_.Exception.Message)"
        return $false
    }
}

function Invoke-IdleRunnerCompaction {
    param([Parameter(Mandatory = $true)][array]$Registrations)

    $forceFleetShutdown = $Force -and $AllowWslShutdown

    if ($DockerPrune -ne "Ask") {
        Write-Warning "-DockerPrune is ignored in idle-runner mode. Use -All to prune Docker Desktop."
    }

    Write-Step "Checking custom runner activity..."
    $statuses = if ($forceFleetShutdown) {
        Write-Warning "FORCE override: runner activity probes are bypassed so every registered runner below '$runnerRootNormal' is included."
        @(Get-ForcedRunnerStatuses -Registrations $Registrations)
    } else {
        @(Invoke-RunnerStatusCheck)
    }
    $initialStatuses = @($statuses)
    foreach ($status in $statuses) {
        $color = if ([bool]$status.SafeToCompact) { "Green" } else { "Yellow" }
        Write-Host (" {0,-24} {1,-12} {2}" -f $status.Distro, $status.Decision, $status.Details) -ForegroundColor $color
    }

    $targets = @(Get-IdleRunnerVhdTargets `
        -Statuses $statuses `
        -Registrations $Registrations `
        -IncludeUnsafe:$forceFleetShutdown)
    $skipped = @($statuses | Where-Object { -not [bool]$_.SafeToCompact })

    Write-Step "Runner VHDX readiness:"
    if ($targets.Count -eq 0) {
        Write-Host " No idle runner VHDX files are currently available." -ForegroundColor Yellow
        Write-Host " No changes were made." -ForegroundColor Green
        exit 0
    }

    foreach ($target in $targets) {
        Write-Host (" [{0}] {1} ({2}; {3})" -f
            $target.Decision, $target.Path, (Format-GB $target.Before), $target.DistroName)
    }

    if ($skipped.Count -gt 0) {
        Write-Host "`nBlocking runners:" -ForegroundColor Yellow
        foreach ($status in $skipped) {
            Write-Host (" {0}: {1}" -f $status.Distro, $status.Decision)
        }
        if ($forceFleetShutdown) {
            Write-Warning "FORCE override enabled: active job attempts will be interrupted when the shared WSL 2 utility VM is shut down; configured retry automation can reschedule them."
        } else {
            Write-Warning "No VHDX files will be compacted. DiskPart requires the shared WSL 2 utility VM to be shut down, so every custom runner must be idle or offline in the same maintenance window. Use -AllowWslShutdown -Force only to deliberately terminate active jobs and override this block."
            exit 0
        }
    }

    if ($ListOnly) {
        if ($forceFleetShutdown -and $skipped.Count -gt 0) {
            Write-Host "`nForce preview: the blocking runners shown above would be terminated." -ForegroundColor Yellow
        } else {
            Write-Host "`nAll custom runners are ready. Actual compaction requires -AllowWslShutdown." -ForegroundColor Green
        }
        Write-Host "List-only check completed; no changes were made." -ForegroundColor Green
        exit 0
    }

    if (-not $AllowWslShutdown) {
        Write-Warning "No changes were made. Rerun with -AllowWslShutdown to permit stopping Docker Desktop, every WSL distribution, and the shared WSL 2 utility VM."
        exit 0
    }

    if (-not $Force) {
        $confirmation = Read-Host "`nEvery runner is idle. This will stop Docker Desktop and all WSL distributions, compact runner VHDX files, then restore runner keepalives. Type COMPACT FLEET to continue"
        if ($confirmation -cne "COMPACT FLEET") {
            Write-Host "Cancelled; no changes were made." -ForegroundColor Yellow
            exit 0
        }
    }

    $runnerRootBefore = Get-FolderLogicalBytes $runnerRootNormal
    $compactedCount = 0
    $keepaliveStates = New-Object 'System.Collections.Generic.List[object]'
    $dockerWasRunning = $null -ne (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)
    $shouldRestartDocker = $dockerWasRunning -and (-not $NoRestartDocker)
    $dockerStopAttempted = $false
    $wslWasShutdown = $false
    $abortMessage = ""

    try {
        Write-Step $(if ($forceFleetShutdown) { "Trimming available runner filesystems..." } else { "Trimming idle runner filesystems..." })
        $trimStatuses = if ($forceFleetShutdown) {
            @($statuses | Where-Object { $_.Decision -in @("IDLE", "BUSY", "FORCED") })
        } else {
            @($statuses | Where-Object { $_.Decision -eq "IDLE" })
        }
        foreach ($status in $trimStatuses) {
            Invoke-WslTrim -DistroName ([string]$status.Distro)
        }

        Write-Step "Rechecking the complete runner fleet..."
        if ($forceFleetShutdown) {
            Write-Warning "FORCE override remains active; runner activity recheck was skipped."
        } else {
            $statuses = @(Invoke-RunnerStatusCheck)
            $runtimeBlocked = @($statuses | Where-Object { -not [bool]$_.SafeToCompact })
            if ($runtimeBlocked.Count -gt 0) {
                $blockedSummary = (($runtimeBlocked | ForEach-Object { "$($_.Distro)=$($_.Decision)" }) -join ", ")
                $abortMessage = "Runner state changed before maintenance: $blockedSummary"
            }
        }

        if ([string]::IsNullOrWhiteSpace($abortMessage)) {
            Write-Step "Pausing runner keepalive tasks..."
            foreach ($status in $statuses) {
                $keepaliveState = Suspend-RunnerKeepalive -DistroName ([string]$status.Distro)
                [void]$keepaliveStates.Add($keepaliveState)
                if (-not [bool]$keepaliveState.Suspended) {
                    $script:HadFailures = $true
                    $abortMessage = "Could not pause '$($keepaliveState.TaskName)': $($keepaliveState.Error)"
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($abortMessage)) {
            if ($dockerWasRunning) {
                Stop-DockerDesktopForCompaction
                $dockerStopAttempted = $true
            }

            Write-Step "Final runner check before shared WSL shutdown..."
            if ($forceFleetShutdown) {
                Write-Warning "FORCE override will terminate every selected runner now; final activity check was skipped."
            } else {
                $statuses = @(Invoke-RunnerStatusCheck)
                $runtimeBlocked = @($statuses | Where-Object { -not [bool]$_.SafeToCompact })
                if ($runtimeBlocked.Count -gt 0) {
                    $blockedSummary = (($runtimeBlocked | ForEach-Object { "$($_.Distro)=$($_.Decision)" }) -join ", ")
                    $abortMessage = "Runner state changed after pausing keepalives: $blockedSummary"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($abortMessage)) {
            Stop-WslForCompaction
            $wslWasShutdown = $true

            Write-Step "Compacting runner VHDX files with the shared WSL VM stopped..."
            foreach ($target in $targets) {
                Write-Host " Compacting: $($target.Path)" -ForegroundColor Gray
                try {
                    $before = [int64](Get-Item -LiteralPath $target.Path -Force).Length
                    Compact-VhdWithDiskPart -Path $target.Path
                    $after = [int64](Get-Item -LiteralPath $target.Path -Force).Length
                    $saved = [math]::Max([int64]0, ($before - $after))
                    $compactedCount++
                    Write-Host ("  Before: {0}; after: {1}; reclaimed: {2}" -f
                        (Format-GB $before), (Format-GB $after), (Format-GB $saved)) -ForegroundColor Green
                } catch {
                    $script:HadFailures = $true
                    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        } else {
            Write-Warning "$abortMessage. No WSL shutdown or VHDX compaction was performed."
        }
    } finally {
        if (-not $NoRestartRunners) {
            Write-Step "Restoring runner keepalive tasks..."
            foreach ($keepaliveState in $keepaliveStates) {
                [void](Restore-RunnerKeepalive -KeepaliveState $keepaliveState)
            }

            # Restore a runner that was initially online even if it had no
            # running Windows keepalive task to restart.
            $initiallyOnlineStatuses = if ($forceFleetShutdown) {
                @($initialStatuses | Where-Object { $_.Decision -in @("IDLE", "BUSY", "FORCED") })
            } else {
                @($initialStatuses | Where-Object { $_.Decision -eq "IDLE" })
            }
            foreach ($status in $initiallyOnlineStatuses) {
                $state = $keepaliveStates |
                    Where-Object { $_.TaskName -eq "WSL Runner Autostart - $($status.Distro)" } |
                    Select-Object -First 1
                if ($wslWasShutdown -and ($null -eq $state -or -not [bool]$state.WasRunning)) {
                    Start-WslDistribution -DistroName ([string]$status.Distro)
                }
            }
        }

        if ($shouldRestartDocker -and ($dockerStopAttempted -or $wslWasShutdown)) {
            Start-DockerDesktop
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($abortMessage)) {
        if ($script:HadFailures) {
            exit 1
        }
        exit 0
    }

    if (-not $wslWasShutdown) {
        Write-Warning "The shared WSL VM was not shut down, so no VHDX compaction was attempted."
        exit 1
    }

    # Confirm that all runner keepalive tasks which were previously running
    # were restored before reporting success.
    if (-not $NoRestartRunners) {
        foreach ($state in $keepaliveStates | Where-Object { [bool]$_.WasRunning }) {
            $task = Get-ScheduledTask -TaskName ([string]$state.TaskName) -ErrorAction SilentlyContinue
            if ($null -eq $task -or [string]$task.State -ne "Running") {
                $script:HadFailures = $true
                Write-Warning "Keepalive task '$($state.TaskName)' is not running after restoration."
            }
        }
    }

    $runnerRootAfter = Get-FolderLogicalBytes $runnerRootNormal
    $totalSaved = [math]::Max([int64]0, ([int64]$runnerRootBefore - [int64]$runnerRootAfter))
    Write-Step "Runner fleet compaction summary:"
    Write-Host (" Compacted VHDX files: {0}" -f $compactedCount)
    Write-Host (" {0}: {1} (reclaimed {2})" -f
        $runnerRootNormal, (Format-GB $runnerRootAfter), (Format-GB $totalSaved)) -ForegroundColor Green

    if ($script:HadFailures) {
        Write-Warning "Runner fleet compaction completed with one or more errors."
        exit 1
    }
    if ($script:HadWarnings) {
        Write-Warning "Runner fleet compaction completed with one or more nonfatal warnings."
    }

    Write-Host "`nRunner fleet compaction completed successfully." -ForegroundColor Green
    exit 0
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " WSL + DOCKER VHDX CLEANUP AND COMPACTION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

Assert-Dependencies
$registrations = @(Get-WslRegistrations)

if (-not $All) {
    Invoke-IdleRunnerCompaction -Registrations $registrations
}

# Full mode also includes registered distributions stored outside the standard
# Docker, LocalAppData WSL, and custom runner roots.
foreach ($registration in $registrations) {
    $alreadyCovered = @($targetRoots | Where-Object {
        Test-PathWithinRoot -Path $registration.BasePath -Root $_
    }).Count -gt 0
    if (-not $alreadyCovered) {
        $targetRoots += $registration.BasePath
    }
}

$targets = @(Get-VhdTargets -Registrations $registrations)

if ($targets.Count -eq 0) {
    throw "No VHDX files were found below '$dockerRoot' or '$wslRoot'."
}

$rootBefore = @{}
foreach ($root in $targetRoots) {
    $rootBefore[$root] = Get-FolderLogicalBytes $root
}

Write-Step "The following VHDX files will be compacted:"
foreach ($target in $targets) {
    $association = "unregistered/raw VHDX"
    if (-not [string]::IsNullOrWhiteSpace([string]$target.DistroName)) {
        $association = "distro: $($target.DistroName)"
    }
    Write-Host (" [{0}] {1} ({2}; {3})" -f $target.Kind, $target.Path, (Format-GB $target.Before), $association)
}

Write-Host "`nFolder totals before compaction:" -ForegroundColor Yellow
foreach ($root in $targetRoots) {
    Write-Host (" {0}: {1}" -f $root, (Format-GB $rootBefore[$root]))
}

if ($ListOnly) {
    Write-Host "`nList-only check completed; no changes were made." -ForegroundColor Green
    exit 0
}

if (-not $Force) {
    $confirmation = Read-Host "`nThis will stop Docker Desktop and every WSL distro. Type COMPACT to continue"
    if ($confirmation -cne "COMPACT") {
        Write-Host "Cancelled; no changes were made." -ForegroundColor Yellow
        exit 0
    }
}

$dockerWasRunning = ($null -ne (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue))

$shouldRestartDocker = $dockerWasRunning -and (-not $NoRestartDocker)

try {
    Write-Step "Cleaning filesystems before compaction..."
    $pruneChoice = Get-DockerPruneChoice
    Invoke-DockerPrune -Mode $pruneChoice

    $trimmedDistros = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($target in $targets) {
        if (-not [string]::IsNullOrWhiteSpace([string]$target.DistroName) -and $trimmedDistros.Add($target.DistroName)) {
            Invoke-WslTrim -DistroName $target.DistroName
        }
    }

    # Docker's data VHDX is not a registered WSL distro. fstrim -av inside
    # docker-desktop also trims its mounted data disk.
    $dockerDistro = $registrations | Where-Object { $_.Name -eq "docker-desktop" } | Select-Object -First 1
    if ($null -ne $dockerDistro -and $trimmedDistros.Add($dockerDistro.Name)) {
        Invoke-WslTrim -DistroName $dockerDistro.Name
    }

    Stop-DockerAndWsl

    Write-Step "Compacting all discovered VHDX files..."
    foreach ($target in $targets) {
        Write-Host " Compacting: $($target.Path)" -ForegroundColor Gray
        try {
            Compact-VhdWithDiskPart -Path $target.Path
            $after = [int64](Get-Item -LiteralPath $target.Path -Force).Length
            $saved = [math]::Max([int64]0, ($target.Before - $after))
            Write-Host ("  Before: {0}; after: {1}; reclaimed: {2}" -f
                (Format-GB $target.Before), (Format-GB $after), (Format-GB $saved)) -ForegroundColor Green
        } catch {
            $script:HadFailures = $true
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} finally {
    if ($shouldRestartDocker) {
        Start-DockerDesktop
    }
}

Write-Step "Final folder totals:"
foreach ($root in $targetRoots) {
    $after = Get-FolderLogicalBytes $root
    $saved = [math]::Max([int64]0, ([int64]$rootBefore[$root] - $after))
    Write-Host (" {0}: {1} (reclaimed {2})" -f $root, (Format-GB $after), (Format-GB $saved)) -ForegroundColor Green
}

if ($script:HadFailures) {
    Write-Warning "Compaction completed with one or more errors. Review the messages above."
    exit 1
}

if ($script:HadWarnings) {
    Write-Warning "Compaction succeeded with one or more nonfatal warnings. Review the messages above."
}

Write-Host "`nWSL and Docker compaction completed successfully." -ForegroundColor Green
