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

    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
