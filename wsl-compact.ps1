#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Trims and compacts every VHDX below the current user's Docker and WSL folders.

.DESCRIPTION
    Targets %LOCALAPPDATA%\Docker and %LOCALAPPDATA%\wsl. Uses Windows' built-in
    WSL and DiskPart tools, so Optimize-VHD and the Hyper-V PowerShell module are
    not required. Run from an elevated Windows PowerShell or PowerShell terminal.

.PARAMETER DockerPrune
    Ask (default), None, Standard, or Volumes. Standard removes unused Docker
    objects but preserves volumes. Volumes also removes unused Docker volumes.

.EXAMPLE
    .\wsl-compact.ps1 -ListOnly

.EXAMPLE
    .\wsl-compact.ps1 -DockerPrune Standard

.EXAMPLE
    .\wsl-compact.ps1 -DockerPrune Volumes -Force
#>

[CmdletBinding()]
param(
    [ValidateSet("Ask", "None", "Standard", "Volumes")]
    [string]$DockerPrune = "Ask",

    [switch]$Force,
    [switch]$NoRestartDocker,
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dockerRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Docker"
$wslRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "wsl"
$targetRoots = @($dockerRoot, $wslRoot)
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

    $measurement = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum

    if ($null -eq $measurement.Sum) {
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

    $script:DockerExe = Find-DockerExecutable
    if ($null -ne $script:DockerExe) {
        Write-Host " Found: Docker CLI ($script:DockerExe)" -ForegroundColor DarkGray
    } else {
        Write-Warning "Docker CLI was not found. Docker pruning and graceful Docker Desktop restart will be unavailable."
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
    # Direct WSL --exec does not always include /sbin in PATH, even for root.
    & wsl.exe --distribution $DistroName --user root --exec /sbin/fstrim -av
    if ($LASTEXITCODE -ne 0) {
        $script:HadWarnings = $true
        Write-Warning "fstrim failed for '$DistroName' (exit code $LASTEXITCODE). Its VHD may reclaim less space."
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

function Stop-DockerAndWsl {
    Write-Step "Stopping Docker Desktop and WSL to release VHDX handles..."

    if ($null -ne $script:DockerExe) {
        $stopResult = Invoke-DockerCommandWithTimeout -Arguments @("desktop", "stop") -TimeoutSeconds 60
        if ($stopResult.TimedOut -or $stopResult.ExitCode -ne 0) {
            Write-Warning "Docker Desktop CLI stop failed; WSL shutdown will still stop its WSL VM."
        }
    }

    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed with exit code $LASTEXITCODE. No disks were compacted."
    }

    Start-Sleep -Seconds 3
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

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " WSL + DOCKER VHDX CLEANUP AND COMPACTION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

Assert-Dependencies
$registrations = @(Get-WslRegistrations)
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
