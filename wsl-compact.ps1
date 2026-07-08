# Requires -RunAsAdministrator

# Enforce Administrator privileges upfront
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script MUST be run as an Administrator. Please reopen PowerShell as Admin and try again."
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "     WSL DISK CLEANUP & COMPACT SCRIPT     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Fetch installed WSL distributions and thoroughly sanitise text strings
Write-Verbose "Querying WSL for installed distributions..." -Verbose
$wslOutput = wsl --list --quiet
$wslDistros = @()

foreach ($line in $wslOutput) {
    $cleanLine = $line.Replace("`0", "").Trim()
    if (-not [string]::IsNullOrWhiteSpace($cleanLine)) {
        $wslDistros += $cleanLine
    }
}

if ($wslDistros.Count -eq 0) {
    Write-Error "No WSL distributions detected on this system."
    Exit
}

# 2. Select the distribution to target
Write-Host "`nAvailable WSL Distributions:" -ForegroundColor Yellow
for ($i = 0; $i -lt $wslDistros.Count; $i++) {
    Write-Host " [$i] $($wslDistros[$i])"
}

$choice = -1
while ($choice -lt 0 -or $choice -ge $wslDistros.Count) {
    $input = Read-Host "`nSelect the number of the distribution to compact"
    if ([int]::TryParse($input, [ref]$choice)) {
        if ($choice -lt 0 -or $choice -ge $wslDistros.Count) {
            Write-Host "Invalid choice. Please pick a number from the list." -ForegroundColor Red
        }
    } else {
        Write-Host "Please enter a valid integer." -ForegroundColor Red
        $choice = -1
    }
}

$targetDistro = $wslDistros[$choice]
Write-Host "Selected Target: $targetDistro" -ForegroundColor Green

# 3. Locate the ext4.vhdx file
Write-Verbose "Searching registry for $targetDistro VHDX file path..." -Verbose
$wslRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
$distroGuid = Get-ChildItem $wslRegPath | Where-Object { 
    (Get-ItemProperty $_.PsPath).DistributionName -eq $targetDistro 
}

if (-not $distroGuid) {
    Write-Error "Could not resolve the registry configuration for $targetDistro."
    Exit
}

$rawBasePath = (Get-ItemProperty $distroGuid.PsPath).BasePath
# Strip Win32 namespace prefix device paths (like \\?\) that break PowerShell's Test-Path
$cleanBasePath = $rawBasePath -replace '^\\\\\?\\', ''
$vhdxPath = Join-Path $cleanBasePath "ext4.vhdx"
$vhdxPath = [System.Environment]::ExpandEnvironmentVariables($vhdxPath)

if (-not (Test-Path $vhdxPath)) {
    Write-Error "Could not find the VHDX file at expected path: $vhdxPath"
    Exit
}

Write-Host "Found VHDX at: $vhdxPath" -ForegroundColor Gray
$initialSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host ("Current disk file size: {0:N2} GB" -f $initialSize) -ForegroundColor Yellow

# 4. Trim and zero out free space within the Linux filesystem
Write-Host "`nStep 1: Trimming and mapping unallocated space inside Linux..." -ForegroundColor Cyan
Write-Warning "This step runs 'fstrim' via WSL and may take a moment."
wsl -d $targetDistro --user root fstrim -av

# 5. Safely shutdown WSL
Write-Host "`nStep 2: Shutting down all WSL instances to unlock the VHDX file..." -ForegroundColor Cyan
wsl --shutdown
Start-Sleep -Seconds 5

# 6. Deactivate sparse mode temporarily to allow external compaction tools to attach
Write-Host "`nStep 3: Preparing disk flags for compaction..." -ForegroundColor Cyan
wsl --manage $targetDistro --set-sparse false

# 7. Compact the VHDX using Hyper-V tools or Diskpart fallback
Write-Host "`nStep 4: Compacting the virtual hard disk file..." -ForegroundColor Cyan
Write-Verbose "Executing Optimize-VHD on $vhdxPath..." -Verbose

try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Note: Optimize-VHD cmdlet unavailable. Compacting using Windows Diskpart tool..." -ForegroundColor Yellow
    
    # Generate temporary diskpart script block
    $diskpartScript = @"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    $diskpartScript | diskpart
}

# 8. Re-enable sparse mode for automatic future space reclamation
Write-Host "`nStep 5: Enforcing sparse mode for automatic future shrinkage..." -ForegroundColor Cyan
wsl --manage $targetDistro --set-sparse true

# 9. Report real structural savings
$finalSize = (Get-Item $vhdxPath).Length / 1GB
$spaceSaved = $initialSize - $finalSize

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "Cleanup Complete!" -ForegroundColor Green
Write-Host ("New disk file size: {0:N2} GB" -f $finalSize)
Write-Host ("Total space reclaimed: {0:N2} GB" -f $spaceSaved)
Write-Host "==========================================" -ForegroundColor Green
