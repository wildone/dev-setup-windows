# Requires -RunAsAdministrator

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " UNIVERSAL WSL & DOCKER MASTER CLEANUP " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. INSTALL/VERIFY DEPENDENCIES
Write-Host "Step 1: Verifying Windows features and dependencies..." -ForegroundColor Cyan

# Enable Hyper-V Platform and Management Tools
# This is required for the Optimize-VHD cmdlet
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperv.State -ne "Enabled") {
    Write-Host "Enabling Hyper-V platform and management tools..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
} else { Write-Host "[OK] Hyper-V is already enabled." -ForegroundColor Green }

# Enable Virtual Machine Platform
$vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmPlatform.State -ne "Enabled") {
    Write-Host "Enabling Virtual Machine Platform..." -ForegroundColor Yellow
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
} else { Write-Host "[OK] Virtual Machine Platform is already enabled." -ForegroundColor Green }

# Update WSL Kernel to support modern storage flags
Write-Host "Checking for WSL kernel updates..." -ForegroundColor Gray
wsl --update

# 2. SELECT TARGET DISTRIBUTION
$wslOutput = wsl --list --quiet
$wslDistros = @()
foreach ($line in $wslOutput) {
    # Strip null characters from UTF-16 output to prevent "distro not found" errors
    $cleanLine = $line.Replace("`0", "").Trim()
    if (-not [string]::IsNullOrWhiteSpace($cleanLine)) { $wslDistros += $cleanLine }
}

Write-Host "`nAvailable Targets:" -ForegroundColor Yellow
for ($i = 0; $i -lt $wslDistros.Count; $i++) { Write-Host " [$i] $($wslDistros[$i])" }
$dockerManualIndex = $wslDistros.Count
Write-Host " [$dockerManualIndex] DOCKER STORAGE FILE (Target: 300GB+ VHDX)"

$choice = Read-Host "`nSelect target number"
$targetDistro = if ($choice -eq $dockerManualIndex) { "docker-desktop-data" } else { $wslDistros[$choice] }

# 3. DEEP INTERNAL CLEANUP
Write-Host "`nStep 2: Performing deep internal cache purges..." -ForegroundColor Cyan
if ($targetDistro -like "*docker*") {
    if (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
        docker system prune -a --volumes -f
        docker builder prune --all -f
    }
} else {
    wsl -d $targetDistro --user root apt-get clean 2>$null
    wsl -d $targetDistro --user root fstrim -av 2>$null
}

# 4. BRUTE-FORCE UNLOCK (CRITICAL FOR FILE-IN-USE ERRORS)
Write-Host "`nStep 3: Dropping system handles to unlock VHDX file..." -ForegroundColor Cyan
wsl --shutdown
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "com.docker.service" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "LxssManager" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VmCompute" -Force -ErrorAction SilentlyContinue 
Start-Sleep -Seconds 5

# 5. RESOLVE PHYSICAL PATH
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

# 6. COMPACTION PHASE (WITH SAFETY BYPASS)
Write-Host "`nStep 4: Compacting storage at $vhdxPath..." -ForegroundColor Cyan
wsl --manage $targetDistro --set-sparse false --allow-unsafe 2>$null

$initialSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host ("Initial file size: {0:N2} GB" -f $initialSize) -ForegroundColor Yellow

try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Optimize-VHD failed. Falling back to native Diskpart routine..." -ForegroundColor Yellow
    $dp = "select vdisk file=""$vhdxPath""`nattach vdisk readonly`ncompact vdisk`ndetach vdisk`nexit"
    $dp | diskpart
}

# 7. RESTORE AUTOMATED SETTINGS
# Re-enable sparse mode so space is released automatically in the future
wsl --manage $targetDistro --set-sparse true --allow-unsafe 2>$null

# 8. FINAL REPORT
$finalSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host "`n==========================================" -ForegroundColor Green
Write-Host ("Reclamation complete! Saved: {0:N2} GB" -f ($initialSize - $finalSize))
Write-Host "New structural file size: {0:N2} GB" -f $finalSize
Write-Host "You may now restart Docker Desktop."
Write-Host "==========================================" -ForegroundColor Green
