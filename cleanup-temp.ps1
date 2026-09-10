#Requires -Version 5.1

<#
.SYNOPSIS
    Removes old files from the current user's local temporary folder.

.DESCRIPTION
    Cleans %LOCALAPPDATA%\Temp without requiring elevation. By default, only
    files last modified more than seven days ago are removed. Locked files,
    recently modified files, and filesystem reparse points are skipped.

    After file cleanup, old empty directories are removed from deepest to
    shallowest. The Temp root itself is never removed. Use -ListOnly for a
    concise read-only preview or PowerShell's standard -WhatIf switch to see
    each proposed removal.

.PARAMETER OlderThanDays
    Minimum age, in days, based on LastWriteTime. Default: 7. Use 0 only when
    deliberately attempting to remove every file that is not actively locked.

.PARAMETER ListOnly
    Reports the cleanup candidates and estimated reclaimable bytes without
    deleting files or directories.

.EXAMPLE
    .\cleanup-temp.ps1 -ListOnly

.EXAMPLE
    .\cleanup-temp.ps1

.EXAMPLE
    .\cleanup-temp.ps1 -OlderThanDays 30

.EXAMPLE
    .\cleanup-temp.ps1 -OlderThanDays 1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [ValidateRange(0, 3650)]
    [int]$OlderThanDays = 7,

    [switch]$ListOnly,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [string[]]$LocationId,

    [switch]$Execute,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ConfiguredCleanupProcessSnapshot = $null
$script:ConfiguredCleanupProcessSnapshotLoaded = $false

function Format-ByteSize {
    param([Parameter(Mandatory = $true)][int64]$Bytes)

    if ($Bytes -ge 1GB) {
        return ("{0:N2} GB" -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ("{0:N2} MB" -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ("{0:N2} KB" -f ($Bytes / 1KB))
    }
    return ("{0} bytes" -f $Bytes)
}

function Test-PathWithinTempRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TempRoot
    )

    $normalPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $normalRoot = [System.IO.Path]::GetFullPath($TempRoot).TrimEnd('\')
    return $normalPath.StartsWith("$normalRoot\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TempInventory {
    param([Parameter(Mandatory = $true)][string]$TempRoot)

    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $enumerationFailures = New-Object 'System.Collections.Generic.List[string]'
    $reparsePoints = New-Object 'System.Collections.Generic.List[string]'
    $pending.Push((New-Object System.IO.DirectoryInfo($TempRoot)))

    while ($pending.Count -gt 0) {
        $currentDirectory = $pending.Pop()
        try {
            foreach ($child in $currentDirectory.EnumerateFileSystemInfos()) {
                $isReparsePoint = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
                if ($isReparsePoint) {
                    [void]$reparsePoints.Add($child.FullName)
                    continue
                }

                if ($child -is [System.IO.DirectoryInfo]) {
                    [void]$directories.Add($child)
                    $pending.Push($child)
                } else {
                    [void]$files.Add($child)
                }
            }
        } catch {
            [void]$enumerationFailures.Add("$($currentDirectory.FullName): $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        Files               = $files
        Directories         = $directories
        EnumerationFailures = $enumerationFailures
        ReparsePoints       = $reparsePoints
    }
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)

    return ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-DirectoryInventorySummary {
    param([Parameter(Mandatory = $true)][string]$Root)

    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push((New-Object System.IO.DirectoryInfo($Root)))
    $fileCount = [int64]0
    $directoryCount = [int64]0
    $bytes = [int64]0
    $reparsePoints = New-Object 'System.Collections.Generic.List[string]'
    $enumerationFailures = New-Object 'System.Collections.Generic.List[string]'
    $newestWriteTime = (Get-Item -LiteralPath $Root -Force).LastWriteTimeUtc

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            foreach ($child in $current.EnumerateFileSystemInfos()) {
                if (Test-ReparsePoint -Item $child) {
                    [void]$reparsePoints.Add($child.FullName)
                    continue
                }

                if ($child.LastWriteTimeUtc -gt $newestWriteTime) {
                    $newestWriteTime = $child.LastWriteTimeUtc
                }

                if ($child -is [System.IO.DirectoryInfo]) {
                    $directoryCount++
                    $pending.Push($child)
                } else {
                    $fileCount++
                    $bytes += [int64]$child.Length
                }
            }
        } catch {
            [void]$enumerationFailures.Add("$($current.FullName): $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        FileCount           = $fileCount
        DirectoryCount      = $directoryCount
        Bytes               = $bytes
        NewestWriteTimeUtc  = $newestWriteTime
        ReparsePoints       = $reparsePoints
        EnumerationFailures = $enumerationFailures
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\\')
}

function Test-ConfiguredCleanRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowShallowRoot
    )

    $normalized = Get-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        return "Path does not exist or is not a directory: $normalized"
    }

    $item = Get-Item -LiteralPath $normalized -Force
    if (Test-ReparsePoint -Item $item) {
        return "Configured root is a reparse point: $normalized"
    }

    if ([string]::Equals($normalized, [System.IO.Path]::GetPathRoot($normalized).TrimEnd('\\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return "Configured root must not be a drive root: $normalized"
    }

    if (-not $AllowShallowRoot -and ($normalized -split '[\\/]').Count -lt 4) {
        return "Configured root is too shallow to clean safely: $normalized"
    }

    $blockedRoots = @(
        [Environment]::GetFolderPath('Windows'),
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('UserProfile')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($blockedRoot in $blockedRoots) {
        $normalBlockedRoot = Get-NormalizedPath -Path $blockedRoot
        if ($normalized.StartsWith($normalBlockedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "Configured root is under a protected system or profile directory: $normalized"
        }
    }

    return $null
}

function Get-PathProcessMatches {
    param([Parameter(Mandatory = $true)][string]$Path)

    $matches = New-Object 'System.Collections.Generic.List[object]'
    try {
        if (-not $script:ConfiguredCleanupProcessSnapshotLoaded) {
            $script:ConfiguredCleanupProcessSnapshot = @(Get-CimInstance Win32_Process)
            $script:ConfiguredCleanupProcessSnapshotLoaded = $true
        }
        foreach ($process in $script:ConfiguredCleanupProcessSnapshot) {
            if ($null -ne $process.CommandLine -and $process.CommandLine.IndexOf($Path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$matches.Add($process)
            }
        }
    } catch {
        [void]$matches.Add([PSCustomObject]@{ ProcessId = '?'; Name = 'process-query-failed'; CommandLine = $_.Exception.Message })
    }
    return $matches
}

function Get-CargoProcessMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    if (-not $script:ConfiguredCleanupProcessSnapshotLoaded) {
        [void](Get-PathProcessMatches -Path $TargetDirectory)
    }
    return @($script:ConfiguredCleanupProcessSnapshot | Where-Object {
        $_.Name -match '^(cargo|cargo-clippy|rustc|rustup)(\.exe)?$' -and
        $null -ne $_.CommandLine -and (
            $_.CommandLine.IndexOf($Repository, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf($TargetDirectory, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    })
}

function Test-CargoTargetDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $cacheTagPath = Join-Path $Path 'CACHEDIR.TAG'
    if (Test-Path -LiteralPath $cacheTagPath -PathType Leaf) {
        try {
            $tagItem = Get-Item -LiteralPath $cacheTagPath -Force -ErrorAction Stop
            if (Test-ReparsePoint -Item $tagItem) { return $false }
            # Cargo requires this signature at byte zero; legacy build layout
            # alone is not enough to authorize cleaning a directory.
            $signature = [System.Text.Encoding]::ASCII.GetBytes('Signature: 8a477f597d28d172789f06886806bc55')
            $stream = [System.IO.File]::OpenRead($cacheTagPath)
            try {
                foreach ($expected in $signature) {
                    if ($stream.ReadByte() -ne $expected) { return $false }
                }
                return $true
            } finally {
                $stream.Dispose()
            }
        } catch {
            return $false
        }
    }

    return $false
}

function Get-ActiveWorktreeLeases {
    param([Parameter(Mandatory = $true)][string]$LeasePath)

    if (-not (Test-Path -LiteralPath $LeasePath -PathType Leaf)) {
        return @()
    }

    try {
        $document = Get-Content -LiteralPath $LeasePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($document.schemaVersion -ne 1 -or $null -eq $document.leases) {
            throw "Expected schemaVersion 1 and a leases array."
        }

        $now = [DateTime]::UtcNow
        return @($document.leases | Where-Object {
            $expiry = [DateTime]::MinValue
            if (-not [DateTime]::TryParse($_.expiresUtc, [ref]$expiry)) {
                throw "Lease for '$($_.worktree)' has an invalid expiresUtc value."
            }
            $expiry.ToUniversalTime() -gt $now
        })
    } catch {
        throw "Cannot safely read worktree lease file '$LeasePath': $($_.Exception.Message)"
    }
}

function Test-IgnoredUntrackedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Repository '.git'))) {
        return "Configured repository is not a Git worktree: $Repository"
    }

    $normalRepository = Get-NormalizedPath -Path $Repository
    $normalPath = Get-NormalizedPath -Path $Path
    if (-not $normalPath.StartsWith("$normalRepository\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "Configured artifact root is outside its repository: $Path"
    }
    $relativePath = $normalPath.Substring($normalRepository.Length + 1)

    & git -C $Repository check-ignore -q -- $relativePath
    if ($LASTEXITCODE -ne 0) {
        return "Configured artifact root is not ignored by its repository: $Path"
    }

    $tracked = @(& git -C $Repository ls-files -- $relativePath)
    if ($LASTEXITCODE -ne 0) {
        return "Unable to determine tracked files under: $Path"
    }
    if ($tracked.Count -gt 0) {
        return "Configured artifact root contains tracked files: $Path"
    }

    return $null
}

function Test-IgnoredUntrackedWorktreeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Worktree
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Worktree '.git'))) {
        return "Worktree Git metadata is unavailable: $Worktree"
    }
    $normalWorktree = Get-NormalizedPath -Path $Worktree
    $normalPath = Get-NormalizedPath -Path $Path
    if (-not $normalPath.StartsWith("$normalWorktree\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "Artifact directory is outside its worktree: $normalPath"
    }
    $relativePath = $normalPath.Substring($normalWorktree.Length + 1)
    & git -C $normalWorktree check-ignore -q -- $relativePath
    if ($LASTEXITCODE -ne 0) {
        return "Artifact directory is not ignored by its worktree: $normalPath"
    }
    $tracked = @(& git -C $normalWorktree ls-files -- $relativePath)
    if ($LASTEXITCODE -ne 0) {
        return "Unable to determine tracked files under: $normalPath"
    }
    if ($tracked.Count -gt 0) {
        return "Artifact directory contains tracked files: $normalPath"
    }
    return $null
}

function Get-RegisteredWorktreesUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    $lines = @(& git -C $Repository worktree list --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Git worktrees for '$Repository'."
    }

    $normalizedRoot = Get-NormalizedPath -Path $Root
    $normalizedRepository = Get-NormalizedPath -Path $Repository
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        if (-not $line.StartsWith('worktree ')) {
            continue
        }
        $worktreePath = Get-NormalizedPath -Path $line.Substring(9)
        if ([string]::Equals($worktreePath, $normalizedRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ([string]::Equals(([System.IO.Directory]::GetParent($worktreePath).FullName), $normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$result.Add($worktreePath)
        }
    }
    return $result
}

function Get-GitWorktreeState {
    param([Parameter(Mandatory = $true)][string]$Worktree)

    # "normal" still reports every untracked directory as dirty without walking
    # every file beneath it, which keeps large abandoned worktrees practical to scan.
    $status = @(& git -C $Worktree status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ DirtyCount = -1; LockPath = $null; Error = "Git status failed for $Worktree" }
    }

    $head = @(& git -C $Worktree rev-parse --verify HEAD)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1) {
        return [PSCustomObject]@{ DirtyCount = $status.Count; LockPath = $null; Error = "Unable to resolve HEAD for $Worktree" }
    }

    # A worktree is removable only when its exact HEAD is reachable from at
    # least one remote-tracking ref. This covers pushed feature branches,
    # merged branches, and detached worktrees whose commit is retained remotely.
    $remoteRefs = @(& git -C $Worktree for-each-ref '--format=%(refname)' --contains $head[0] refs/remotes)
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ DirtyCount = $status.Count; LockPath = $null; Error = "Unable to inspect remote refs for $Worktree" }
    }

    $lockPath = @(& git -C $Worktree rev-parse --git-path index.lock)[0]
    if ($LASTEXITCODE -ne 0) {
        $lockPath = $null
    }
    return [PSCustomObject]@{
        DirtyCount = $status.Count
        LockPath   = $lockPath
        Head       = $head[0]
        RemoteRefs = @($remoteRefs)
        Error      = $null
    }
}

function Invoke-ConfiguredArtifactRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $parent = [System.IO.Directory]::GetParent($Path).FullName
    $stagingPath = Join-Path $parent ('.codex-cleanup-staging-{0}-{1}' -f $Id, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))
    if (Test-Path -LiteralPath $stagingPath) {
        throw "Refusing to reuse an existing staging path: $stagingPath"
    }

    [System.IO.Directory]::Move($Path, $stagingPath)
    if (Test-Path -LiteralPath $Path) {
        throw "Original path reappeared while staging cleanup: $Path"
    }
    [System.IO.Directory]::Delete($stagingPath, $true)
}

function Remove-DirectoryTreeWithoutFollowingReparsePoints {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or (Test-ReparsePoint -Item $root)) {
        throw "Residual worktree root must be an ordinary directory: $Path"
    }

    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pending.Push([System.IO.DirectoryInfo]$root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        [void]$directories.Add($current)
        foreach ($child in $current.EnumerateFileSystemInfos()) {
            if (Test-ReparsePoint -Item $child) {
                if ($child -is [System.IO.DirectoryInfo]) {
                    [System.IO.Directory]::Delete($child.FullName, $false)
                } else {
                    [System.IO.File]::Delete($child.FullName)
                }
                continue
            }
            if ($child -is [System.IO.DirectoryInfo]) {
                $pending.Push($child)
                continue
            }
            if ($child.IsReadOnly) {
                $child.IsReadOnly = $false
            }
            $child.Delete()
        }
    }

    foreach ($directory in $directories | Sort-Object { $_.FullName.Length } -Descending) {
        [System.IO.Directory]::Delete($directory.FullName, $false)
    }
}

function Invoke-ResidualWorktreeRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $normalPath = Get-NormalizedPath -Path $Path
    $normalRoot = Get-NormalizedPath -Path $Root
    if (-not [string]::Equals([System.IO.Directory]::GetParent($normalPath).FullName, $normalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Residual worktree is not a direct child of its configured root: $normalPath"
    }
    if (@(Get-RegisteredWorktreesUnderRoot -Root $normalRoot -Repository $Repository) -contains $normalPath) {
        throw "Git still registers the worktree; refusing residual deletion: $normalPath"
    }
    $item = Get-Item -LiteralPath $normalPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (Test-ReparsePoint -Item $item)) {
        throw "Residual worktree path is not an ordinary directory: $normalPath"
    }
    if ((Test-Path -LiteralPath (Join-Path $normalPath '.cleanup-active.json') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $normalPath '.codex-active.json') -PathType Leaf)) {
        throw "An active marker appeared during worktree removal: $normalPath"
    }

    # Refresh the process snapshot immediately before the fallback deletion.
    $script:ConfiguredCleanupProcessSnapshot = $null
    $script:ConfiguredCleanupProcessSnapshotLoaded = $false
    if (@(Get-PathProcessMatches -Path $normalPath).Count -gt 0) {
        throw "A live process references the residual worktree: $normalPath"
    }

    $stagingPath = Join-Path $normalRoot ('.codex-cleanup-staging-{0}-{1}' -f $Id, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))
    if (Test-Path -LiteralPath $stagingPath) {
        throw "Refusing to reuse an existing staging path: $stagingPath"
    }
    [System.IO.Directory]::Move($normalPath, $stagingPath)
    if (Test-Path -LiteralPath $normalPath) {
        throw "Original residual worktree reappeared while staging cleanup: $normalPath"
    }
    Remove-DirectoryTreeWithoutFollowingReparsePoints -Path $stagingPath
}

function Get-PackageCachePath {
    param([Parameter(Mandatory = $true)][string]$Tool)

    $output = switch ($Tool) {
        'pnpm' {
            if ($null -eq (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw 'pnpm is not available.' }
            @(& pnpm store path --silent)
            break
        }
        'npm' {
            if ($null -eq (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm is not available.' }
            @(& npm config get cache)
            break
        }
        'pip' {
            if ($null -eq (Get-Command python -ErrorAction SilentlyContinue)) { throw 'python is not available.' }
            @(& python -m pip cache dir)
            break
        }
        default { throw "Unsupported package cache tool: $Tool" }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query the $Tool cache path."
    }
    $paths = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($paths.Count -ne 1 -or -not [System.IO.Path]::IsPathRooted([string]$paths[0])) {
        throw "$Tool returned an invalid cache path."
    }
    return Get-NormalizedPath -Path ([string]$paths[0])
}

function Get-PackageManagerProcessMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not $script:ConfiguredCleanupProcessSnapshotLoaded) {
        [void](Get-PathProcessMatches -Path $Path)
    }
    $pattern = switch ($Tool) {
        'pnpm' { '(?i)(pnpm(?:\.cjs|\.js|\.ps1|\.cmd)?|pnpm-store)' }
        'npm'  { '(?i)(npm-cli|npm(?:\.cmd|\.ps1)?\s)' }
        'pip'  { '(?i)(?:^|[\\/\s])pip(?:\.exe)?(?:\s|$)|python(?:\.exe)?[^\r\n]*\s-m\s+pip' }
        default { throw "Unsupported package cache tool: $Tool" }
    }
    return @($script:ConfiguredCleanupProcessSnapshot | Where-Object {
        $_.ProcessId -ne $PID -and $null -ne $_.CommandLine -and (
            $_.CommandLine.IndexOf($Path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine -match $pattern
        )
    })
}

function Invoke-PackageCachePrune {
    param([Parameter(Mandatory = $true)][string]$Tool)

    switch ($Tool) {
        'pnpm' { & pnpm store prune; break }
        'npm'  { & npm cache clean --force; break }
        'pip'  { & python -m pip cache purge; break }
        default { throw "Unsupported package cache tool: $Tool" }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool cache cleanup failed."
    }
}

function Invoke-ReparseSafeDirectoryRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $normalPath = Get-NormalizedPath -Path $Path
    $normalRoot = Get-NormalizedPath -Path $Root
    if (-not [string]::Equals([System.IO.Directory]::GetParent($normalPath).FullName, $normalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cleanup target is not a direct child of its configured root: $normalPath"
    }
    $item = Get-Item -LiteralPath $normalPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (Test-ReparsePoint -Item $item)) {
        throw "Cleanup target must be an ordinary directory: $normalPath"
    }
    $stagingPath = Join-Path $normalRoot ('.codex-cleanup-staging-{0}-{1}' -f $Id, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))
    if (Test-Path -LiteralPath $stagingPath) {
        throw "Refusing to reuse an existing staging path: $stagingPath"
    }
    [System.IO.Directory]::Move($normalPath, $stagingPath)
    if (Test-Path -LiteralPath $normalPath) {
        throw "Original path reappeared while staging cleanup: $normalPath"
    }
    Remove-DirectoryTreeWithoutFollowingReparsePoints -Path $stagingPath
}

function Invoke-ConfiguredCargoClean {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    Push-Location -LiteralPath $Repository
    try {
        & cargo clean --target-dir $TargetDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Cargo failed to clean target directory: $TargetDirectory"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-ConfiguredCleanup {
    param([Parameter(Mandatory = $true)][string]$ConfigFile)

    if ($ListOnly -and $Execute) {
        throw 'Use either -ListOnly or -Execute, not both. Config cleanup is list-only unless -Execute is supplied.'
    }
    if ($Execute -and -not $Force) {
        throw 'Configured cleanup requires -Execute -Force. Run with -ListOnly first.'
    }
    try {
        $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot parse cleanup configuration '$ConfigFile': $($_.Exception.Message)"
    }
    if ($config.schemaVersion -ne 1 -or $null -eq $config.locations) {
        throw "Cleanup configuration '$ConfigFile' must contain schemaVersion 1 and a locations array."
    }

    $configDirectory = [System.IO.Directory]::GetParent((Get-NormalizedPath -Path $ConfigFile)).FullName
    $leaseFileName = if ([string]::IsNullOrWhiteSpace($config.worktreeLeaseFile)) { 'cleanup-worktree-leases.json' } else { [string]$config.worktreeLeaseFile }
    if ([System.IO.Path]::IsPathRooted($leaseFileName)) {
        throw 'worktreeLeaseFile must be relative to the configuration file.'
    }
    $leasePath = Join-Path $configDirectory $leaseFileName
    $activeLeases = @(Get-ActiveWorktreeLeases -LeasePath $leasePath)
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $enabledLocations = @($config.locations | Where-Object { $_.enabled -ne $false })
    $selectedLocations = $enabledLocations
    $hasLocationFilter = $null -ne $LocationId -and $LocationId.Count -gt 0
    if ($hasLocationFilter) {
        $requestedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $LocationId) {
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'LocationId cannot contain an empty value.' }
            [void]$requestedIds.Add($id)
        }
        $availableIds = @($enabledLocations | ForEach-Object { [string]$_.id })
        $missingIds = @($requestedIds | Where-Object { $_ -notin $availableIds })
        if ($missingIds.Count -gt 0) { throw "Configured cleanup location id was not found or is disabled: $($missingIds -join ', ')" }
        $selectedLocations = @($enabledLocations | Where-Object { $requestedIds.Contains([string]$_.id) })
    }

    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host ' CONFIGURED CLEANUP PREFLIGHT' -ForegroundColor Cyan
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host (" Config:              {0}" -f $ConfigFile)
    Write-Host (" Active agent leases: {0}" -f $activeLeases.Count)
    Write-Host (" Locations:           {0}" -f $(if ($hasLocationFilter) { $LocationId -join ', ' } else { 'all enabled locations' }))
    Write-Host (" Mode:                {0}" -f $(if ($Execute) { 'EXECUTE (force required)' } else { 'LIST ONLY' }))

    $plans = New-Object 'System.Collections.Generic.List[object]'
    foreach ($location in $selectedLocations) {
        if ([string]::IsNullOrWhiteSpace($location.id) -or -not $seenIds.Add([string]$location.id)) {
            throw 'Every enabled cleanup location must have a unique non-empty id.'
        }
        if ([string]::IsNullOrWhiteSpace($location.path) -or -not [System.IO.Path]::IsPathRooted([string]$location.path)) {
            throw "Cleanup location '$($location.id)' must use an absolute path."
        }
        if ($location.kind -notin @('git-worktree-root', 'git-worktree-artifacts', 'ignored-artifact-tree', 'ignored-artifact-root', 'cargo-target', 'cargo-target-root', 'package-cache', 'package-cache-child-root', 'pnpm-store-root')) {
            throw "Cleanup location '$($location.id)' has an unsupported kind: $($location.kind)"
        }
        $minimumInactiveProperty = $location.PSObject.Properties['minimumInactiveMinutes']
        $minimumInactiveMinutes = if ($null -eq $minimumInactiveProperty) { 60 } else { [int]$minimumInactiveProperty.Value }
        if ($minimumInactiveMinutes -lt 0 -or $minimumInactiveMinutes -gt 10080) {
            throw "Cleanup location '$($location.id)' has an invalid minimumInactiveMinutes value."
        }
        $inactiveCutoff = [DateTime]::UtcNow.AddMinutes(-$minimumInactiveMinutes)

        $path = Get-NormalizedPath -Path $location.path
        $repositoryProperty = $location.PSObject.Properties['repository']
        $repository = if ($null -eq $repositoryProperty -or [string]::IsNullOrWhiteSpace([string]$repositoryProperty.Value)) { $null } else { Get-NormalizedPath -Path ([string]$repositoryProperty.Value) }
        $blockers = New-Object 'System.Collections.Generic.List[string]'
        if ($location.kind -in @('package-cache', 'package-cache-child-root', 'pnpm-store-root')) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                [void]$blockers.Add("Package cache path does not exist or is not a directory: $path")
            } elseif (Test-ReparsePoint -Item (Get-Item -LiteralPath $path -Force)) {
                [void]$blockers.Add("Package cache root is a reparse point: $path")
            }
        } else {
            $rootError = Test-ConfiguredCleanRoot -Path $path -AllowShallowRoot:($location.kind -in @('cargo-target-root', 'git-worktree-root'))
            if ($null -ne $rootError) {
                [void]$blockers.Add($rootError)
            }
        }
        if ($location.kind -notin @('package-cache', 'package-cache-child-root', 'pnpm-store-root') -and $null -eq $repository) {
            [void]$blockers.Add('A repository path is required for every configured location.')
        }

        $plan = [PSCustomObject]@{
            Id = [string]$location.id; Kind = [string]$location.kind; Path = $path; Repository = $repository
            Blockers = $blockers; Inventory = $null; Worktrees = @(); EligibleWorktrees = @(); DirtyWorktreeCount = 0
            RecentWorktreeCount = 0; UnpushedWorktreeCount = 0; MinimumInactiveMinutes = $minimumInactiveMinutes
            CanCleanRegisteredWorktrees = $false; ArtifactChildCount = 0; EligibleArtifactChildren = @()
            RecentArtifactCount = 0; ReparseArtifactCount = 0; FailedArtifactCount = 0; ProcessArtifactCount = 0
            ExcludedArtifactCount = 0; EligibleArtifactBytes = [int64]0; CanCleanArtifactChildren = $false
            CacheTool = if ($null -eq $location.PSObject.Properties['tool']) { $null } else { [string]$location.PSObject.Properties['tool'].Value }; CacheInventory = $null
            CanPrunePackageCache = $false; ActivePackageStore = $null; EligibleObsoleteStores = @()
            RecentObsoleteStoreCount = 0; FailedObsoleteStoreCount = 0; EligibleObsoleteStoreBytes = [int64]0
            WorktreeArtifactCount = 0; EligibleWorktreeArtifacts = @(); EligibleWorktreeArtifactBytes = [int64]0
            ProtectedArtifactWorktreeCount = 0; RecentWorktreeArtifactCount = 0; GitProtectedArtifactCount = 0
            ReparseProtectedArtifactCount = 0; FailedWorktreeArtifactCount = 0; ProcessProtectedArtifactCount = 0
            CanCleanWorktreeArtifacts = $false; InvalidCargoTargetCount = 0
        }
        if ($blockers.Count -eq 0 -and $location.kind -in @('ignored-artifact-tree', 'cargo-target')) {
            $gitError = Test-IgnoredUntrackedDirectory -Path $path -Repository $repository
            if ($null -ne $gitError) { [void]$blockers.Add($gitError) }
            $plan.Inventory = Get-DirectoryInventorySummary -Root $path
            if ($plan.Inventory.ReparsePoints.Count -gt 0) { [void]$blockers.Add('Contains one or more reparse points.') }
            if ($plan.Inventory.EnumerationFailures.Count -gt 0) { [void]$blockers.Add('Could not enumerate the complete directory tree.') }
            if ($plan.Inventory.NewestWriteTimeUtc -gt $inactiveCutoff) { [void]$blockers.Add("Directory has changed within the required $minimumInactiveMinutes-minute inactive period.") }
            if (@(Get-PathProcessMatches -Path $path).Count -gt 0) { [void]$blockers.Add('A live process command line references this path.') }
            if ($location.kind -eq 'cargo-target' -and @(Get-CargoProcessMatches -Repository $repository -TargetDirectory $path).Count -gt 0) { [void]$blockers.Add('A live Cargo or Rust process references this repository or target directory.') }
        }
        if ($blockers.Count -eq 0 -and $location.kind -in @('ignored-artifact-root', 'package-cache-child-root')) {
            [object[]]$includeNamePatterns = @($location.includeNamePatterns)
            if ($includeNamePatterns.Count -eq 0 -or @($includeNamePatterns | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) -or [string]$_ -match '[\\/]' }).Count -gt 0) {
                [void]$blockers.Add("$($location.kind) requires non-empty includeNamePatterns without path separators.")
            } else {
                if ($location.kind -eq 'package-cache-child-root') {
                    if ($plan.CacheTool -notin @('pnpm', 'npm', 'pip')) {
                        [void]$blockers.Add('package-cache-child-root tool must be pnpm, npm, or pip.')
                    } else {
                        try {
                            $reportedCachePath = Get-PackageCachePath -Tool $plan.CacheTool
                            $configuredParent = Get-NormalizedPath -Path ([System.IO.Directory]::GetParent($path).FullName)
                            if (-not [string]::Equals($reportedCachePath, $configuredParent, [System.StringComparison]::OrdinalIgnoreCase)) {
                                [void]$blockers.Add("Configured child root is not a direct child of the path reported by $($plan.CacheTool): $reportedCachePath")
                            } elseif (@(Get-PackageManagerProcessMatches -Tool $plan.CacheTool -Path $path).Count -gt 0) {
                                [void]$blockers.Add("A live $($plan.CacheTool) process or cache-path reference was detected.")
                            }
                        } catch {
                            [void]$blockers.Add($_.Exception.Message)
                        }
                    }
                } else {
                    $gitError = Test-IgnoredUntrackedDirectory -Path $path -Repository $repository
                    if ($null -ne $gitError) {
                        [void]$blockers.Add($gitError)
                    }
                }
                if ($blockers.Count -eq 0) {
                    $plan.CanCleanArtifactChildren = $true
                    $eligibleArtifactChildren = New-Object 'System.Collections.Generic.List[object]'
                    $allArtifactChildren = @(Get-ChildItem -LiteralPath $path -Directory -Force)
                    $artifactChildren = @($allArtifactChildren | Where-Object {
                        $childName = $_.Name
                        @($includeNamePatterns | Where-Object { $childName -like [string]$_ }).Count -gt 0
                    })
                    $plan.ArtifactChildCount = $artifactChildren.Count
                    $plan.ExcludedArtifactCount = $allArtifactChildren.Count - $artifactChildren.Count
                    foreach ($artifactChild in $artifactChildren) {
                        if (Test-ReparsePoint -Item $artifactChild) {
                            $plan.ReparseArtifactCount++
                            continue
                        }
                        $inventory = Get-DirectoryInventorySummary -Root $artifactChild.FullName
                        if ($inventory.ReparsePoints.Count -gt 0) {
                            $plan.ReparseArtifactCount++
                            continue
                        }
                        if ($inventory.EnumerationFailures.Count -gt 0) {
                            $plan.FailedArtifactCount++
                            continue
                        }
                        if ($inventory.NewestWriteTimeUtc -gt $inactiveCutoff) {
                            $plan.RecentArtifactCount++
                            continue
                        }
                        if (@(Get-PathProcessMatches -Path $artifactChild.FullName).Count -gt 0) {
                            $plan.ProcessArtifactCount++
                            continue
                        }
                        $artifactPlan = [PSCustomObject]@{ Path = $artifactChild.FullName; Inventory = $inventory }
                        [void]$eligibleArtifactChildren.Add($artifactPlan)
                        $plan.EligibleArtifactBytes += [int64]$inventory.Bytes
                    }
                    $plan.EligibleArtifactChildren = $eligibleArtifactChildren.ToArray()
                }
            }
        }
        if ($blockers.Count -eq 0 -and $location.kind -eq 'cargo-target-root') {
            [object[]]$includeNamePatterns = @($location.includeNamePatterns)
            if ($includeNamePatterns.Count -eq 0 -or @($includeNamePatterns | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) -or [string]$_ -match '[\\/]' }).Count -gt 0) {
                [void]$blockers.Add('cargo-target-root requires non-empty includeNamePatterns without path separators.')
            } elseif (-not (Test-Path -LiteralPath (Join-Path $repository 'Cargo.toml') -PathType Leaf)) {
                [void]$blockers.Add("Configured repository does not contain Cargo.toml: $repository")
            } else {
                $plan.CanCleanArtifactChildren = $true
                $eligibleCargoTargets = New-Object 'System.Collections.Generic.List[object]'
                $allCargoChildren = @(Get-ChildItem -LiteralPath $path -Directory -Force)
                $cargoTargets = @($allCargoChildren | Where-Object {
                    $childName = $_.Name
                    @($includeNamePatterns | Where-Object { $childName -like [string]$_ }).Count -gt 0
                })
                $plan.ArtifactChildCount = $cargoTargets.Count
                $plan.ExcludedArtifactCount = $allCargoChildren.Count - $cargoTargets.Count
                foreach ($cargoTarget in $cargoTargets) {
                    if (Test-ReparsePoint -Item $cargoTarget) {
                        $plan.ReparseArtifactCount++
                        continue
                    }
                    if (-not (Test-CargoTargetDirectory -Path $cargoTarget.FullName)) {
                        Write-Warning "Cargo target retained: missing, invalid, or unreadable CACHEDIR.TAG: $($cargoTarget.FullName)"
                        $plan.InvalidCargoTargetCount++
                        continue
                    }
                    $inventory = Get-DirectoryInventorySummary -Root $cargoTarget.FullName
                    if ($inventory.ReparsePoints.Count -gt 0) {
                        $plan.ReparseArtifactCount++
                        continue
                    }
                    if ($inventory.EnumerationFailures.Count -gt 0) {
                        $plan.FailedArtifactCount++
                        continue
                    }
                    if ($inventory.NewestWriteTimeUtc -gt $inactiveCutoff) {
                        $plan.RecentArtifactCount++
                        continue
                    }
                    if (@(Get-PathProcessMatches -Path $cargoTarget.FullName).Count -gt 0 -or
                        @(Get-CargoProcessMatches -Repository $repository -TargetDirectory $cargoTarget.FullName).Count -gt 0) {
                        $plan.ProcessArtifactCount++
                        continue
                    }
                    [void]$eligibleCargoTargets.Add([PSCustomObject]@{ Path = $cargoTarget.FullName; Inventory = $inventory })
                    $plan.EligibleArtifactBytes += [int64]$inventory.Bytes
                }
                $plan.EligibleArtifactChildren = $eligibleCargoTargets.ToArray()
            }
        }
        if ($blockers.Count -eq 0 -and $location.kind -eq 'package-cache') {
            if ($plan.CacheTool -notin @('pnpm', 'npm', 'pip')) {
                [void]$blockers.Add('package-cache tool must be pnpm, npm, or pip.')
            } else {
                try {
                    $reportedCachePath = Get-PackageCachePath -Tool $plan.CacheTool
                    if (-not [string]::Equals($reportedCachePath, $path, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [void]$blockers.Add("Configured cache path does not match the path reported by $($plan.CacheTool): $reportedCachePath")
                    } else {
                        $plan.CacheInventory = Get-DirectoryInventorySummary -Root $path
                        if ($plan.CacheInventory.EnumerationFailures.Count -gt 0) {
                            [void]$blockers.Add('Could not enumerate the complete package cache.')
                        }
                        if (@(Get-PackageManagerProcessMatches -Tool $plan.CacheTool -Path $path).Count -gt 0) {
                            [void]$blockers.Add("A live $($plan.CacheTool) process or cache-path reference was detected.")
                        }
                        if ($blockers.Count -eq 0) {
                            $plan.CanPrunePackageCache = $true
                        }
                    }
                } catch {
                    [void]$blockers.Add($_.Exception.Message)
                }
            }
        }
        if ($blockers.Count -eq 0 -and $location.kind -eq 'pnpm-store-root') {
            if ($plan.CacheTool -ne 'pnpm') {
                [void]$blockers.Add('pnpm-store-root requires tool pnpm.')
            } else {
                try {
                    $activeStore = Get-PackageCachePath -Tool 'pnpm'
                    if (-not [string]::Equals([System.IO.Directory]::GetParent($activeStore).FullName, $path, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [void]$blockers.Add("The active pnpm store is not a direct child of the configured root: $activeStore")
                    } elseif (@(Get-PackageManagerProcessMatches -Tool 'pnpm' -Path $path).Count -gt 0) {
                        [void]$blockers.Add('A live pnpm process or store-path reference was detected.')
                    } else {
                        $plan.ActivePackageStore = $activeStore
                        $eligibleStores = New-Object 'System.Collections.Generic.List[object]'
                        foreach ($store in Get-ChildItem -LiteralPath $path -Directory -Force) {
                            $normalStore = Get-NormalizedPath -Path $store.FullName
                            if ([string]::Equals($normalStore, $activeStore, [System.StringComparison]::OrdinalIgnoreCase)) {
                                continue
                            }
                            if (Test-ReparsePoint -Item $store) {
                                $plan.FailedObsoleteStoreCount++
                                continue
                            }
                            $inventory = Get-DirectoryInventorySummary -Root $normalStore
                            if ($inventory.EnumerationFailures.Count -gt 0) {
                                $plan.FailedObsoleteStoreCount++
                                continue
                            }
                            if ($inventory.NewestWriteTimeUtc -gt $inactiveCutoff) {
                                $plan.RecentObsoleteStoreCount++
                                continue
                            }
                            [void]$eligibleStores.Add([PSCustomObject]@{ Path = $normalStore; Inventory = $inventory })
                            $plan.EligibleObsoleteStoreBytes += [int64]$inventory.Bytes
                        }
                        $plan.EligibleObsoleteStores = $eligibleStores.ToArray()
                    }
                } catch {
                    [void]$blockers.Add($_.Exception.Message)
                }
            }
        }
        if ($blockers.Count -eq 0 -and $location.kind -eq 'git-worktree-artifacts') {
            $relativePathsProperty = $location.PSObject.Properties['artifactRelativePaths']
            [object[]]$relativePaths = if ($null -eq $relativePathsProperty) { @() } else { @($relativePathsProperty.Value) }
            if ($relativePaths.Count -eq 0 -or @($relativePaths | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_) -or [System.IO.Path]::IsPathRooted([string]$_) -or [string]$_ -match '[*?\[\]]'
            }).Count -gt 0) {
                [void]$blockers.Add('git-worktree-artifacts requires explicit non-wildcard relative artifact paths.')
            } else {
                try {
                    $registered = @(Get-RegisteredWorktreesUnderRoot -Root $path -Repository $repository)
                    if ($registered.Count -eq 0) {
                        [void]$blockers.Add('Contains no registered direct-child Git worktrees for artifact cleanup.')
                    } else {
                        $plan.CanCleanWorktreeArtifacts = $true
                        $eligibleArtifacts = New-Object 'System.Collections.Generic.List[object]'
                        foreach ($worktree in $registered) {
                            $worktreeItem = Get-Item -LiteralPath $worktree -Force
                            $worktreeActivityTimeUtc = if ($worktreeItem.CreationTimeUtc -gt $worktreeItem.LastWriteTimeUtc) { $worktreeItem.CreationTimeUtc } else { $worktreeItem.LastWriteTimeUtc }
                            $lockPath = @(& git -C $worktree rev-parse --git-path index.lock)[0]
                            $worktreeBlocked = $LASTEXITCODE -ne 0 -or
                                $worktreeActivityTimeUtc -gt $inactiveCutoff -or
                                ($null -ne $lockPath -and (Test-Path -LiteralPath $lockPath)) -or
                                @(Get-PathProcessMatches -Path $worktree).Count -gt 0 -or
                                (Test-Path -LiteralPath (Join-Path $worktree '.cleanup-active.json') -PathType Leaf) -or
                                (Test-Path -LiteralPath (Join-Path $worktree '.codex-active.json') -PathType Leaf) -or
                                @($activeLeases | Where-Object { [string]::Equals((Get-NormalizedPath -Path $_.worktree), $worktree, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                            if ($worktreeBlocked) {
                                $plan.ProtectedArtifactWorktreeCount++
                                continue
                            }
                            foreach ($relativePathValue in $relativePaths) {
                                $relativePath = [string]$relativePathValue
                                $artifactPath = Get-NormalizedPath -Path (Join-Path $worktree $relativePath)
                                if (-not $artifactPath.StartsWith("$worktree\", [System.StringComparison]::OrdinalIgnoreCase)) {
                                    $plan.GitProtectedArtifactCount++
                                    continue
                                }
                                if (-not (Test-Path -LiteralPath $artifactPath -PathType Container)) {
                                    continue
                                }
                                $plan.WorktreeArtifactCount++
                                $artifactItem = Get-Item -LiteralPath $artifactPath -Force
                                if (Test-ReparsePoint -Item $artifactItem) {
                                    $plan.ReparseProtectedArtifactCount++
                                    continue
                                }
                                $gitError = Test-IgnoredUntrackedWorktreeDirectory -Path $artifactPath -Worktree $worktree
                                if ($null -ne $gitError) {
                                    $plan.GitProtectedArtifactCount++
                                    continue
                                }
                                $inventory = Get-DirectoryInventorySummary -Root $artifactPath
                                if ($inventory.EnumerationFailures.Count -gt 0) {
                                    $plan.FailedWorktreeArtifactCount++
                                    continue
                                }
                                if ($inventory.NewestWriteTimeUtc -gt $inactiveCutoff) {
                                    $plan.RecentWorktreeArtifactCount++
                                    continue
                                }
                                if (@(Get-PathProcessMatches -Path $artifactPath).Count -gt 0) {
                                    $plan.ProcessProtectedArtifactCount++
                                    continue
                                }
                                [void]$eligibleArtifacts.Add([PSCustomObject]@{
                                    Path = $artifactPath; Worktree = $worktree; RelativePath = $relativePath; Inventory = $inventory
                                })
                                $plan.EligibleWorktreeArtifactBytes += [int64]$inventory.Bytes
                            }
                        }
                        $plan.EligibleWorktreeArtifacts = $eligibleArtifacts.ToArray()
                    }
                } catch {
                    [void]$blockers.Add($_.Exception.Message)
                }
            }
        }
        if ($blockers.Count -eq 0 -and $location.kind -eq 'git-worktree-root') {
            try {
                $plan.CanCleanRegisteredWorktrees = $true
                $registered = @(Get-RegisteredWorktreesUnderRoot -Root $path -Repository $repository)
                $children = @(Get-ChildItem -LiteralPath $path -Force)
                $unexpected = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
                foreach ($child in $children) {
                    if (-not $child.PSIsContainer -or $registered -notcontains (Get-NormalizedPath -Path $child.FullName)) {
                        [void]$unexpected.Add($child)
                    }
                }
                if ($unexpected.Count -gt 0) { [void]$blockers.Add('Contains files or unregistered worktree directories.') }
                if ($registered.Count -eq 0) { [void]$blockers.Add('Contains no registered direct-child Git worktrees.') }
                $eligibleWorktrees = New-Object 'System.Collections.Generic.List[string]'
                foreach ($worktree in $registered) {
                    $state = Get-GitWorktreeState -Worktree $worktree
                    if ($null -ne $state.Error) { [void]$blockers.Add($state.Error); continue }
                    $worktreeItem = Get-Item -LiteralPath $worktree -Force
                    $worktreeActivityTimeUtc = if ($worktreeItem.CreationTimeUtc -gt $worktreeItem.LastWriteTimeUtc) {
                        $worktreeItem.CreationTimeUtc
                    } else {
                        $worktreeItem.LastWriteTimeUtc
                    }
                    if ($worktreeActivityTimeUtc -gt $inactiveCutoff) {
                        $plan.RecentWorktreeCount++
                        continue
                    }
                    if ($state.DirtyCount -gt 0) {
                        $plan.DirtyWorktreeCount++
                        continue
                    }
                    if ($state.RemoteRefs.Count -eq 0) {
                        $plan.UnpushedWorktreeCount++
                        continue
                    }
                    $worktreeBlocked = $false
                    if ($null -ne $state.LockPath -and (Test-Path -LiteralPath $state.LockPath)) { [void]$blockers.Add("Git index lock exists: $worktree"); $worktreeBlocked = $true }
                    if (@(Get-PathProcessMatches -Path $worktree).Count -gt 0) { [void]$blockers.Add("A live process command line references: $worktree"); $worktreeBlocked = $true }
                    if (Test-Path -LiteralPath (Join-Path $worktree '.cleanup-active.json') -PathType Leaf) { [void]$blockers.Add("Active-worktree marker exists: $worktree"); $worktreeBlocked = $true }
                    if (Test-Path -LiteralPath (Join-Path $worktree '.codex-active.json') -PathType Leaf) { [void]$blockers.Add("Codex active-worktree marker exists: $worktree"); $worktreeBlocked = $true }
                    if (@($activeLeases | Where-Object { [string]::Equals((Get-NormalizedPath -Path $_.worktree), $worktree, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { [void]$blockers.Add("Active agent lease exists: $worktree"); $worktreeBlocked = $true }
                    if (-not $worktreeBlocked) { [void]$eligibleWorktrees.Add($worktree) }
                }
                $plan.Worktrees = $registered
                $plan.EligibleWorktrees = @($eligibleWorktrees)
            } catch {
                [void]$blockers.Add($_.Exception.Message)
            }
        }
        [void]$plans.Add($plan)
    }

    foreach ($plan in $plans) {
        Write-Host "`n[$($plan.Id)] $($plan.Kind)" -ForegroundColor Cyan
        Write-Host (" Path: {0}" -f $plan.Path)
        if ($plan.Kind -in @('ignored-artifact-tree', 'cargo-target') -and $null -ne $plan.Inventory) {
            Write-Host (" Inventory: {0} files, {1} directories, {2}; newest write {3:u}" -f $plan.Inventory.FileCount, $plan.Inventory.DirectoryCount, (Format-ByteSize $plan.Inventory.Bytes), $plan.Inventory.NewestWriteTimeUtc)
        }
        if ($plan.Kind -eq 'git-worktree-root') {
            Write-Host (" Worktrees: {0}; changed within {1} min: {2}; dirty protected: {3}; not remote-reachable: {4}; eligible: {5}" -f $plan.Worktrees.Count, $plan.MinimumInactiveMinutes, $plan.RecentWorktreeCount, $plan.DirtyWorktreeCount, $plan.UnpushedWorktreeCount, $plan.EligibleWorktrees.Count)
            if ($plan.EligibleWorktrees.Count -gt 0) {
                Write-Host ' Eligible worktrees:'
                foreach ($eligibleWorktree in $plan.EligibleWorktrees) {
                    Write-Host ("  - {0}" -f $eligibleWorktree)
                }
            }
        }
        if ($plan.Kind -eq 'git-worktree-artifacts') {
            Write-Host (" Artifact directories found: {0}; worktrees protected: {1}; recent artifacts: {2}; Git protected: {3}; root reparse protected: {4}; scan failures: {5}; process protected: {6}; eligible: {7} ({8})" -f $plan.WorktreeArtifactCount, $plan.ProtectedArtifactWorktreeCount, $plan.RecentWorktreeArtifactCount, $plan.GitProtectedArtifactCount, $plan.ReparseProtectedArtifactCount, $plan.FailedWorktreeArtifactCount, $plan.ProcessProtectedArtifactCount, $plan.EligibleWorktreeArtifacts.Count, (Format-ByteSize $plan.EligibleWorktreeArtifactBytes))
            foreach ($artifact in $plan.EligibleWorktreeArtifacts) {
                Write-Host ("  - {0} ({1})" -f $artifact.Path, (Format-ByteSize $artifact.Inventory.Bytes))
            }
        }
        if ($plan.Kind -in @('ignored-artifact-root', 'package-cache-child-root')) {
            Write-Host (" Selected directories: {0}; outside allow patterns: {1}; changed within {2} min: {3}; reparse protected: {4}; scan failures: {5}; process protected: {6}; eligible: {7} ({8})" -f $plan.ArtifactChildCount, $plan.ExcludedArtifactCount, $plan.MinimumInactiveMinutes, $plan.RecentArtifactCount, $plan.ReparseArtifactCount, $plan.FailedArtifactCount, $plan.ProcessArtifactCount, $plan.EligibleArtifactChildren.Count, (Format-ByteSize $plan.EligibleArtifactBytes))
            if ($plan.EligibleArtifactChildren.Count -gt 0) {
                Write-Host ' Eligible artifact directories:'
                foreach ($artifactChild in $plan.EligibleArtifactChildren) {
                    Write-Host ("  - {0} ({1})" -f $artifactChild.Path, (Format-ByteSize $artifactChild.Inventory.Bytes))
                }
            }
        }
        if ($plan.Kind -eq 'cargo-target-root') {
            Write-Host (" Selected Cargo targets: {0}; outside allow patterns: {1}; changed within {2} min: {3}; invalid Cargo layout: {4}; reparse protected: {5}; scan failures: {6}; process protected: {7}; eligible: {8} ({9})" -f $plan.ArtifactChildCount, $plan.ExcludedArtifactCount, $plan.MinimumInactiveMinutes, $plan.RecentArtifactCount, $plan.InvalidCargoTargetCount, $plan.ReparseArtifactCount, $plan.FailedArtifactCount, $plan.ProcessArtifactCount, $plan.EligibleArtifactChildren.Count, (Format-ByteSize $plan.EligibleArtifactBytes))
            if ($plan.EligibleArtifactChildren.Count -gt 0) {
                Write-Host ' Eligible Cargo target directories:'
                foreach ($cargoTarget in $plan.EligibleArtifactChildren) {
                    Write-Host ("  - {0} ({1})" -f $cargoTarget.Path, (Format-ByteSize $cargoTarget.Inventory.Bytes))
                }
            }
        }
        if ($plan.Kind -eq 'package-cache' -and $null -ne $plan.CacheInventory) {
            Write-Host (" Tool: {0}; cache inventory: {1} files, {2} directories, {3}; native prune ready: {4}" -f $plan.CacheTool, $plan.CacheInventory.FileCount, $plan.CacheInventory.DirectoryCount, (Format-ByteSize $plan.CacheInventory.Bytes), $plan.CanPrunePackageCache)
        }
        if ($plan.Kind -eq 'pnpm-store-root') {
            Write-Host (" Active store protected: {0}; obsolete recent: {1}; obsolete scan failures: {2}; eligible obsolete stores: {3} ({4})" -f $plan.ActivePackageStore, $plan.RecentObsoleteStoreCount, $plan.FailedObsoleteStoreCount, $plan.EligibleObsoleteStores.Count, (Format-ByteSize $plan.EligibleObsoleteStoreBytes))
            foreach ($store in $plan.EligibleObsoleteStores) {
                Write-Host ("  - {0} ({1})" -f $store.Path, (Format-ByteSize $store.Inventory.Bytes))
            }
        }
        if ($plan.Blockers.Count -gt 0) {
            if ($plan.Kind -eq 'git-worktree-root' -and $plan.CanCleanRegisteredWorktrees) {
                Write-Warning ("Root retained: {0}" -f ($plan.Blockers -join ' | '))
            } else {
                Write-Warning ("Skipped: {0}" -f ($plan.Blockers -join ' | '))
            }
        }
    }

    if (-not $Execute) {
        Write-Host "`nConfigured cleanup list-only check completed; no changes were made." -ForegroundColor Green
        return
    }

    # Do not rely on the preflight process snapshot during deletion.
    $script:ConfiguredCleanupProcessSnapshot = $null
    $script:ConfiguredCleanupProcessSnapshotLoaded = $false

    foreach ($plan in $plans | Where-Object { $_.Blockers.Count -eq 0 -or ($_.Kind -eq 'git-worktree-root' -and $_.CanCleanRegisteredWorktrees) }) {
        if ($plan.Kind -eq 'cargo-target') {
            if ($PSCmdlet.ShouldProcess($plan.Path, 'Run Cargo clean for configured target directory')) {
                Invoke-ConfiguredCargoClean -Repository $plan.Repository -TargetDirectory $plan.Path
                Write-Host "Cargo cleaned target directory: $($plan.Path)" -ForegroundColor Green
            }
        } elseif ($plan.Kind -eq 'git-worktree-artifacts') {
            $inactiveCutoff = [DateTime]::UtcNow.AddMinutes(-$plan.MinimumInactiveMinutes)
            $registeredNow = @(Get-RegisteredWorktreesUnderRoot -Root $plan.Path -Repository $plan.Repository)
            foreach ($artifact in $plan.EligibleWorktreeArtifacts) {
                if ($registeredNow -notcontains $artifact.Worktree -or -not (Test-Path -LiteralPath $artifact.Path -PathType Container)) {
                    Write-Warning "Worktree or artifact registration changed after preflight and was retained: $($artifact.Path)"
                    continue
                }
                $worktreeItem = Get-Item -LiteralPath $artifact.Worktree -Force
                $worktreeActivityTimeUtc = if ($worktreeItem.CreationTimeUtc -gt $worktreeItem.LastWriteTimeUtc) { $worktreeItem.CreationTimeUtc } else { $worktreeItem.LastWriteTimeUtc }
                $lockPath = @(& git -C $artifact.Worktree rev-parse --git-path index.lock)[0]
                $worktreeUnsafe = $LASTEXITCODE -ne 0 -or
                    $worktreeActivityTimeUtc -gt $inactiveCutoff -or
                    ($null -ne $lockPath -and (Test-Path -LiteralPath $lockPath)) -or
                    @(Get-PathProcessMatches -Path $artifact.Worktree).Count -gt 0 -or
                    (Test-Path -LiteralPath (Join-Path $artifact.Worktree '.cleanup-active.json') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $artifact.Worktree '.codex-active.json') -PathType Leaf) -or
                    @($activeLeases | Where-Object { [string]::Equals((Get-NormalizedPath -Path $_.worktree), $artifact.Worktree, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                $artifactItem = Get-Item -LiteralPath $artifact.Path -Force
                $gitError = Test-IgnoredUntrackedWorktreeDirectory -Path $artifact.Path -Worktree $artifact.Worktree
                $currentInventory = if (Test-ReparsePoint -Item $artifactItem) { $null } else { Get-DirectoryInventorySummary -Root $artifact.Path }
                if ($worktreeUnsafe -or (Test-ReparsePoint -Item $artifactItem) -or $null -ne $gitError -or
                    $null -eq $currentInventory -or $currentInventory.EnumerationFailures.Count -gt 0 -or
                    $currentInventory.NewestWriteTimeUtc -gt $inactiveCutoff -or @(Get-PathProcessMatches -Path $artifact.Path).Count -gt 0) {
                    Write-Warning "Worktree artifact changed or became unsafe after preflight and was retained: $($artifact.Path)"
                    continue
                }
                if ($PSCmdlet.ShouldProcess($artifact.Path, 'Stage and permanently delete ignored worktree artifact directory')) {
                    Invoke-ReparseSafeDirectoryRemoval -Path $artifact.Path -Root ([System.IO.Directory]::GetParent($artifact.Path).FullName) -Id $plan.Id
                    Write-Host "Removed worktree artifact: $($artifact.Path)" -ForegroundColor Green
                }
            }
        } elseif ($plan.Kind -eq 'ignored-artifact-tree') {
            if ($PSCmdlet.ShouldProcess($plan.Path, 'Stage and permanently delete configured artifact tree')) {
                Invoke-ConfiguredArtifactRemoval -Path $plan.Path -Id $plan.Id
                Write-Host "Removed artifact tree: $($plan.Path)" -ForegroundColor Green
            }
        } elseif ($plan.Kind -eq 'cargo-target-root') {
            $inactiveCutoff = [DateTime]::UtcNow.AddMinutes(-$plan.MinimumInactiveMinutes)
            foreach ($cargoTarget in $plan.EligibleArtifactChildren) {
                if (-not (Test-Path -LiteralPath $cargoTarget.Path -PathType Container)) {
                    Write-Warning "Cargo target disappeared after preflight and was skipped: $($cargoTarget.Path)"
                    continue
                }
                $targetParent = Get-NormalizedPath -Path ([System.IO.Directory]::GetParent($cargoTarget.Path).FullName)
                $currentItem = Get-Item -LiteralPath $cargoTarget.Path -Force
                if (-not [string]::Equals($targetParent, $plan.Path, [System.StringComparison]::OrdinalIgnoreCase) -or
                    (Test-ReparsePoint -Item $currentItem) -or -not (Test-CargoTargetDirectory -Path $cargoTarget.Path)) {
                    Write-Warning "Cargo target identity changed after preflight and was retained: $($cargoTarget.Path)"
                    continue
                }
                $currentInventory = Get-DirectoryInventorySummary -Root $cargoTarget.Path
                if ($currentInventory.ReparsePoints.Count -gt 0 -or $currentInventory.EnumerationFailures.Count -gt 0 -or
                    $currentInventory.NewestWriteTimeUtc -gt $inactiveCutoff -or @(Get-PathProcessMatches -Path $cargoTarget.Path).Count -gt 0 -or
                    @(Get-CargoProcessMatches -Repository $plan.Repository -TargetDirectory $cargoTarget.Path).Count -gt 0) {
                    Write-Warning "Cargo target changed or became unsafe after preflight and was retained: $($cargoTarget.Path)"
                    continue
                }
                if ($PSCmdlet.ShouldProcess($cargoTarget.Path, 'Run cargo clean for configured target directory')) {
                    Invoke-ConfiguredCargoClean -Repository $plan.Repository -TargetDirectory $cargoTarget.Path
                    Write-Host "Cleaned Cargo target directory: $($cargoTarget.Path)" -ForegroundColor Green
                }
            }
        } elseif ($plan.Kind -in @('ignored-artifact-root', 'package-cache-child-root')) {
            if ($plan.Kind -eq 'package-cache-child-root') {
                $reportedCachePath = Get-PackageCachePath -Tool $plan.CacheTool
                $configuredParent = Get-NormalizedPath -Path ([System.IO.Directory]::GetParent($plan.Path).FullName)
                if (-not [string]::Equals($reportedCachePath, $configuredParent, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "The $($plan.CacheTool) cache path changed after preflight: $reportedCachePath"
                }
                if (@(Get-PackageManagerProcessMatches -Tool $plan.CacheTool -Path $plan.Path).Count -gt 0) {
                    throw "A live $($plan.CacheTool) process or cache-path reference appeared after preflight."
                }
            }
            $inactiveCutoff = [DateTime]::UtcNow.AddMinutes(-$plan.MinimumInactiveMinutes)
            foreach ($artifactChild in $plan.EligibleArtifactChildren) {
                $currentItem = Get-Item -LiteralPath $artifactChild.Path -Force -ErrorAction Stop
                if (Test-ReparsePoint -Item $currentItem) {
                    Write-Warning "Artifact directory became a reparse point and was retained: $($artifactChild.Path)"
                    continue
                }
                $currentInventory = Get-DirectoryInventorySummary -Root $artifactChild.Path
                if ($currentInventory.ReparsePoints.Count -gt 0 -or $currentInventory.EnumerationFailures.Count -gt 0 -or
                    $currentInventory.NewestWriteTimeUtc -gt $inactiveCutoff -or @(Get-PathProcessMatches -Path $artifactChild.Path).Count -gt 0) {
                    Write-Warning "Artifact directory changed or became unsafe after preflight and was retained: $($artifactChild.Path)"
                    continue
                }
                if ($PSCmdlet.ShouldProcess($artifactChild.Path, 'Stage and permanently delete configured artifact directory')) {
                    Invoke-ConfiguredArtifactRemoval -Path $artifactChild.Path -Id $plan.Id
                    Write-Host "Removed artifact directory: $($artifactChild.Path)" -ForegroundColor Green
                }
            }
        } elseif ($plan.Kind -eq 'package-cache') {
            $reportedCachePath = Get-PackageCachePath -Tool $plan.CacheTool
            if (-not [string]::Equals($reportedCachePath, $plan.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "The $($plan.CacheTool) cache path changed after preflight: $reportedCachePath"
            }
            if (@(Get-PackageManagerProcessMatches -Tool $plan.CacheTool -Path $plan.Path).Count -gt 0) {
                throw "A live $($plan.CacheTool) process or cache-path reference appeared after preflight."
            }
            if ($PSCmdlet.ShouldProcess($plan.Path, "Run native $($plan.CacheTool) cache cleanup")) {
                $beforeBytes = [int64]$plan.CacheInventory.Bytes
                Invoke-PackageCachePrune -Tool $plan.CacheTool
                $afterBytes = if (Test-Path -LiteralPath $plan.Path -PathType Container) {
                    [int64](Get-DirectoryInventorySummary -Root $plan.Path).Bytes
                } else {
                    [int64]0
                }
                Write-Host ("Pruned {0} cache: {1} reclaimed" -f $plan.CacheTool, (Format-ByteSize ([Math]::Max([int64]0, $beforeBytes - $afterBytes)))) -ForegroundColor Green
            }
        } elseif ($plan.Kind -eq 'pnpm-store-root') {
            $activeStore = Get-PackageCachePath -Tool 'pnpm'
            if (-not [string]::Equals([System.IO.Directory]::GetParent($activeStore).FullName, $plan.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "The active pnpm store moved outside the configured root after preflight: $activeStore"
            }
            if (@(Get-PackageManagerProcessMatches -Tool 'pnpm' -Path $plan.Path).Count -gt 0) {
                throw 'A live pnpm process or store-path reference appeared after preflight.'
            }
            $inactiveCutoff = [DateTime]::UtcNow.AddMinutes(-$plan.MinimumInactiveMinutes)
            foreach ($store in $plan.EligibleObsoleteStores) {
                if ([string]::Equals($store.Path, $activeStore, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Refusing to remove the active pnpm store: $activeStore"
                }
                $currentInventory = Get-DirectoryInventorySummary -Root $store.Path
                if ($currentInventory.EnumerationFailures.Count -gt 0 -or $currentInventory.NewestWriteTimeUtc -gt $inactiveCutoff -or
                    @(Get-PackageManagerProcessMatches -Tool 'pnpm' -Path $store.Path).Count -gt 0) {
                    Write-Warning "Obsolete pnpm store changed or became unsafe after preflight and was retained: $($store.Path)"
                    continue
                }
                if ($PSCmdlet.ShouldProcess($store.Path, 'Stage and permanently delete obsolete pnpm store version')) {
                    Invoke-ReparseSafeDirectoryRemoval -Path $store.Path -Root $plan.Path -Id $plan.Id
                    Write-Host "Removed obsolete pnpm store: $($store.Path)" -ForegroundColor Green
                }
            }
        } else {
            foreach ($worktree in $plan.EligibleWorktrees) {
                if ($PSCmdlet.ShouldProcess($worktree, 'Force-remove registered Git worktree')) {
                    & git -C $plan.Repository worktree remove --force -- $worktree
                    if ($LASTEXITCODE -ne 0) {
                        if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
                            throw "Git failed to remove worktree and its filesystem state is ambiguous: $worktree"
                        }
                        Write-Warning "Git unregistered the worktree but left filesystem residue; applying guarded reparse-safe cleanup: $worktree"
                        Invoke-ResidualWorktreeRemoval -Path $worktree -Root $plan.Path -Repository $plan.Repository -Id $plan.Id
                    }
                    Write-Host "Removed Git worktree: $worktree" -ForegroundColor Green
                }
            }
            if ($PSCmdlet.ShouldProcess($plan.Repository, 'Prune stale Git worktree metadata')) {
                & git -C $plan.Repository worktree prune
                if ($LASTEXITCODE -ne 0) { throw "Git failed to prune worktree metadata for: $($plan.Repository)" }
            }
            if ((Test-Path -LiteralPath $plan.Path) -and @(Get-ChildItem -LiteralPath $plan.Path -Force).Count -eq 0 -and $PSCmdlet.ShouldProcess($plan.Path, 'Remove now-empty worktree root')) {
                Remove-Item -LiteralPath $plan.Path -Force
                Write-Host "Removed empty worktree root: $($plan.Path)" -ForegroundColor Green
            }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    # Resolve relative paths through PowerShell's current location. The .NET
    # process directory can differ from $PWD after Set-Location.
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    Invoke-ConfiguredCleanup $resolvedConfigPath
    exit 0
}

$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw "Windows did not return the current user's LocalApplicationData folder."
}

$localAppDataRoot = [System.IO.Path]::GetFullPath($localAppData).TrimEnd('\')
$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $localAppDataRoot "Temp")).TrimEnd('\')
if (-not $tempRoot.StartsWith("$localAppDataRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a Temp path outside the current user's LocalApplicationData folder: $tempRoot"
}
if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    Write-Host "Temp folder does not exist; no changes were made: $tempRoot" -ForegroundColor Yellow
    exit 0
}

$tempRootItem = Get-Item -LiteralPath $tempRoot -Force
if (($tempRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to traverse the Temp root because it is a filesystem reparse point: $tempRoot"
}

$cutoff = (Get-Date).AddDays(-$OlderThanDays)
$inventory = Get-TempInventory -TempRoot $tempRoot
$candidateFiles = @($inventory.Files | Where-Object { $_.LastWriteTime -lt $cutoff })
$candidateBytes = [int64]0
foreach ($file in $candidateFiles) {
    $candidateBytes += [int64]$file.Length
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " CURRENT USER TEMP CLEANUP" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host (" Temp root:          {0}" -f $tempRoot)
Write-Host (" Modified before:    {0}" -f $cutoff.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host (" Files scanned:      {0}" -f $inventory.Files.Count)
Write-Host (" Candidate files:    {0}" -f $candidateFiles.Count)
Write-Host (" Candidate bytes:    {0}" -f (Format-ByteSize $candidateBytes))
Write-Host (" Reparse points:     {0} skipped" -f $inventory.ReparsePoints.Count)
Write-Host (" Unreadable folders: {0}" -f $inventory.EnumerationFailures.Count)

if ($inventory.EnumerationFailures.Count -gt 0) {
    Write-Warning "$($inventory.EnumerationFailures.Count) folder(s) could not be inspected and will be left unchanged. Use -Verbose for details."
    foreach ($failure in $inventory.EnumerationFailures) {
        Write-Verbose $failure
    }
}

if ($ListOnly) {
    Write-Host "`nList-only check completed; no changes were made." -ForegroundColor Green
    exit 0
}

$removedFileCount = 0
$removedDirectoryCount = 0
$removedBytes = [int64]0
$changedFileCount = 0
$failedRemovals = New-Object 'System.Collections.Generic.List[string]'

foreach ($candidate in $candidateFiles) {
    if (-not (Test-PathWithinTempRoot -Path $candidate.FullName -TempRoot $tempRoot)) {
        [void]$failedRemovals.Add("Refused path outside Temp root: $($candidate.FullName)")
        continue
    }

    try {
        $current = Get-Item -LiteralPath $candidate.FullName -Force -ErrorAction Stop
        $isReparsePoint = ($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($current.PSIsContainer -or $isReparsePoint -or $current.LastWriteTime -ge $cutoff) {
            $changedFileCount++
            continue
        }

        if ($PSCmdlet.ShouldProcess($current.FullName, "Delete old temp file")) {
            $length = [int64]$current.Length
            Remove-Item -LiteralPath $current.FullName -Force -ErrorAction Stop
            $removedFileCount++
            $removedBytes += $length
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        $changedFileCount++
    } catch {
        [void]$failedRemovals.Add("$($candidate.FullName): $($_.Exception.Message)")
        Write-Verbose $failedRemovals[$failedRemovals.Count - 1]
    }
}

$oldDirectories = @($inventory.Directories |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Sort-Object { $_.FullName.Length } -Descending)

foreach ($candidateDirectory in $oldDirectories) {
    if (-not (Test-PathWithinTempRoot -Path $candidateDirectory.FullName -TempRoot $tempRoot)) {
        [void]$failedRemovals.Add("Refused directory outside Temp root: $($candidateDirectory.FullName)")
        continue
    }

    try {
        $currentDirectory = Get-Item -LiteralPath $candidateDirectory.FullName -Force -ErrorAction Stop
        $isReparsePoint = ($currentDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if (-not $currentDirectory.PSIsContainer -or $isReparsePoint) {
            continue
        }

        $hasChildren = $null -ne (Get-ChildItem -LiteralPath $currentDirectory.FullName -Force -ErrorAction Stop | Select-Object -First 1)
        if ($hasChildren) {
            continue
        }

        if ($PSCmdlet.ShouldProcess($currentDirectory.FullName, "Delete old empty temp directory")) {
            Remove-Item -LiteralPath $currentDirectory.FullName -Force -ErrorAction Stop
            $removedDirectoryCount++
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        continue
    } catch {
        [void]$failedRemovals.Add("$($candidateDirectory.FullName): $($_.Exception.Message)")
        Write-Verbose $failedRemovals[$failedRemovals.Count - 1]
    }
}

Write-Host "`nCleanup summary:" -ForegroundColor Cyan
Write-Host (" Files removed:       {0}" -f $removedFileCount)
Write-Host (" Empty dirs removed:  {0}" -f $removedDirectoryCount)
Write-Host (" Approx. reclaimed:   {0}" -f (Format-ByteSize $removedBytes)) -ForegroundColor Green
Write-Host (" Changed/vanished:    {0} skipped" -f $changedFileCount)
Write-Host (" Removal failures:    {0}" -f $failedRemovals.Count)

if ($failedRemovals.Count -gt 0) {
    Write-Warning "$($failedRemovals.Count) item(s) could not be removed, usually because they are currently in use. Use -Verbose for details."
}

Write-Host "Temp cleanup completed." -ForegroundColor Green
