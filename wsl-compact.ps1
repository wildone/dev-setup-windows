# Requires -RunAsAdministrator

# 1. ENFORCE ADMIN PRIVILEGES
$isAdmin = ([SecurityPrincipalWindowsPrincipal][SecurityPrincipalWindowsIdentity]::GetCurrent()).IsInRole([SecurityPrincipalWindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script MUST be run as an Administrator to manage system features and disk handles."
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " UNIVERSAL WSL & DOCKER MASTER CLEANUP " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 2. INSTALL/VERIFY DEPENDENCIES (AS REQUESTED)
Write-Host "Step 1: Verifying Windows features and dependencies..." -ForegroundColor Cyan

# Check and Enable Hyper-V (Required for Optimize-VHD)
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperv.State -ne "Enabled") {
    Write-Host "Enabling Hyper-V platform and management tools..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
} else { Write-Host "[OK] Hyper-V is already enabled." -ForegroundColor Green }

# Check and Enable Virtual Machine Platform (Required for WSL2)
$vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmPlatform.State -ne "Enabled") {
    Write-Host "Enabling Virtual Machine Platform..." -ForegroundColor Yellow
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
} else { Write-Host "[OK] Virtual Machine Platform is already enabled." -ForegroundColor Green }

# Update WSL Kernel
Write-Host "Checking for WSL kernel updates..." -ForegroundColor Gray
wsl --update

# 3. SELECT TARGET DISTRIBUTION
$wslOutput = wsl --list --quiet
$wslDistros = @()
foreach ($line in $wslOutput) {
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
    # Aggressively clear containers, images, volumes, and build caches
    docker system prune -a --volumes -f
    docker builder prune --all -f
} else {
    wsl -d $targetDistro --user root apt-get clean
    wsl -d $targetDistro --user root fstrim -av
}

# 5. BRUTE-FORCE UNLOCK (CRITICAL FOR YOUR 300GB FILE)
Write-Host "`nStep 3: Dropping system handles to unlock VHDX file..." -ForegroundColor Cyan
wsl --shutdown
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "com.docker.service" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "LxssManager" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VmCompute" -Force -ErrorAction SilentlyContinue # Critical for 'File in Use' errors
Start-Sleep -Seconds 5

# 6. RESOLVE PHYSICAL PATH
$vhdxPath = if ($choice -eq $dockerManualIndex) { 
    "C:\Users\maxbarrass\AppData\Local\Docker\wsl\disk\docker_data.vhdx" 
} else {
    $reg = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" | 
           Where-Object { (Get-ItemProperty $_.PsPath).DistributionName -eq $targetDistro }
    ((Get-ItemProperty $reg.PsPath).BasePath -replace '^\\\\\?\\', '') + "\ext4.vhdx"
}

# 7. COMPACTION PHASE (WITH SAFETY BYPASS)
Write-Host "`nStep 4: Compacting storage at $vhdxPath..." -ForegroundColor Cyan
# Toggle sparse to clear metadata locks, using required --allow-unsafe flag for modern builds
wsl --manage $targetDistro --set-sparse false --allow-unsafe 2>$null

$initialSize = (Get-Item $vhdxPath).Length / 1GB

try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Falling back to native Diskpart routine..." -ForegroundColor Yellow
    $dp = "select vdisk file=""$vhdxPath""`nattach vdisk readonly`ncompact vdisk`ndetach vdisk`nexit"
    $dp | diskpart
}

# 8. RESTORE AUTOMATED SETTINGS
wsl --manage $targetDistro --set-sparse true --allow-unsafe 2>$null

# 9. FINAL REPORT
$finalSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host "`n==========================================" -ForegroundColor Green
Write-Host ("Reclamation complete! Saved: {0:N2} GB" -f ($initialSize - $finalSize))
Write-Host "You may now restart Docker Desktop."
Write-Host "==========================================" -ForegroundColor Green
