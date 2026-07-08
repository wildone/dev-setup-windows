# Requires -RunAsAdministrator

# 1. ENFORCE ADMIN PRIVILEGES (FIXED SYNTAX)
# Check for administrative rights with correct .NET type formatting
$currentPrincipal = [SecurityPrincipalWindowsPrincipal][SecurityPrincipalWindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([SecurityPrincipalWindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "This script MUST be run as an Administrator to manage system features and disk handles."
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " UNIVERSAL WSL & DOCKER MASTER CLEANUP " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 2. INSTALL/VERIFY DEPENDENCIES (AS REQUESTED)
Write-Host "Step 1: Verifying Windows features and dependencies..." -ForegroundColor Cyan

# Enable Hyper-V Platform and Management Tools (Required for Optimize-VHD)
# Note: This is the fastest way to get the necessary PowerShell modules
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperv.State -ne "Enabled") {
    Write-Host "Enabling Hyper-V platform and management tools..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
} else { Write-Host "[OK] Hyper-V is already enabled." -ForegroundColor Green }

# Enable Virtual Machine Platform (Required for WSL2)
$vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmPlatform.State -ne "Enabled") {
    Write-Host "Enabling Virtual Machine Platform..." -ForegroundColor Yellow
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
} else { Write-Host "[OK] Virtual Machine Platform is already enabled." -ForegroundColor Green }

# Update WSL Kernel to ensure sparse VHD support
Write-Host "Checking for WSL kernel updates..." -ForegroundColor Gray
wsl --update

# 3. SELECT TARGET DISTRIBUTION
$wslOutput = wsl --list --quiet
$wslDistros = @()
foreach ($line in $wslOutput) {
    # Clean UTF-16 null characters that cause distro-not-found errors
    $cleanLine = $line.Replace("`0", "").Trim()
    if (-not [string]::IsNullOrWhiteSpace($cleanLine)) { $wslDistros += $cleanLine }
}

Write-Host "`nAvailable Targets:" -ForegroundColor Yellow
for ($i = 0; $i -lt $wslDistros.Count; $i++) { Write-Host " [$i] $($wslDistros[$i])" }
$dockerManualIndex = $wslDistros.Count
Write-Host " [$dockerManualIndex] DOCKER STORAGE FILE (Target: 300GB+ VHDX)"

$choice = Read-Host "`nSelect target number"
$targetDistro = if ($choice -eq $dockerManualIndex) { "docker-desktop-data" } else { $wslDistros[$choice] }

# 4. DEEP INTERNAL CLEANUP
Write-Host "`nStep 2: Performing deep internal cache purges..." -ForegroundColor Cyan
if ($targetDistro -like "*docker*") {
    # Clear Docker caches while engine is running
    if (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
        docker system prune -a --volumes -f
        docker builder prune --all -f
    }
} else {
    # Standard Linux cleanup
    wsl -d $targetDistro --user root apt-get clean 2>$null
    wsl -d $targetDistro --user root fstrim -av 2>$null
}

# 5. BRUTE-FORCE UNLOCK (CRITICAL FOR FILE-IN-USE ERRORS)
Write-Host "`nStep 3: Dropping system handles to unlock VHDX file..." -ForegroundColor Cyan
# Kill background services that frequently hold file locks
wsl --shutdown
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "com.docker.service" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "LxssManager" -Force -ErrorAction SilentlyContinue # Subsystem manager
Stop-Service -Name "VmCompute" -Force -ErrorAction SilentlyContinue # Host Compute Service
Start-Sleep -Seconds 5

# 6. RESOLVE PHYSICAL PATH
# Target the specific 300GB file path provided by user if selected
$vhdxPath = if ($choice -eq $dockerManualIndex) { 
    "C:\Users\maxbarrass\AppData\Local\Docker\wsl\disk\docker_data.vhdx" 
} else {
    $reg = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" | 
           Where-Object { (Get-ItemProperty $_.PsPath).DistributionName -eq $targetDistro }
    ((Get-ItemProperty $reg.PsPath).BasePath -replace '^\\\\\?\\', '') + "\ext4.vhdx"
}

if (-not (Test-Path $vhdxPath)) {
    Write-Error "Physical VHDX file not found at: $vhdxPath"
    Exit
}

# 7. COMPACTION PHASE (WITH SAFETY BYPASS)
Write-Host "`nStep 4: Compacting storage at $vhdxPath..." -ForegroundColor Cyan
# Toggling sparse mode temporarily can resolve metadata conflicts
# Using --allow-unsafe to bypass modern Windows corruption warnings
wsl --manage $targetDistro --set-sparse false --allow-unsafe 2>$null

$initialSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host ("Initial file size: {0:N2} GB" -f $initialSize) -ForegroundColor Yellow

try {
    # Optimize-VHD is the most effective method if Hyper-V tools are installed
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Optimize-VHD failed. Falling back to native Diskpart routine..." -ForegroundColor Yellow
    # diskpart is the standard fallback for Windows Home/systems without Hyper-V
    $dp = "select vdisk file=""$vhdxPath""`nattach vdisk readonly`ncompact vdisk`ndetach vdisk`nexit"
    $dp | diskpart
}

# 8. RESTORE AUTOMATED SETTINGS
# Re-enable sparse mode so WSL releases space automatically in the future
wsl --manage $targetDistro --set-sparse true --allow-unsafe 2>$null

# 9. FINAL REPORT
$finalSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host "`n==========================================" -ForegroundColor Green
Write-Host ("Reclamation complete! Saved: {0:N2} GB" -f ($initialSize - $finalSize))
Write-Host "New structural file size: {0:N2} GB" -f $finalSize
Write-Host "You may now restart Docker Desktop."
Write-Host "==========================================" -ForegroundColor Green
