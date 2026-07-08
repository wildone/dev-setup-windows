# Requires -RunAsAdministrator

# 1. ENFORCE ADMIN PRIVILEGES
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $currentPrincipal.IsInRole($adminRole)) {
    Write-Error "This script MUST be run as an Administrator to manage system disk handles."
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " UNIVERSAL WSL & DOCKER MASTER CLEANUP " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 2. DYNAMIC DEEP-SCAN (FIXED SYNTAX)
Write-Host "`nScanning system registry and base folders for all VHDX files..." -ForegroundColor Yellow
$targetList = @()
$wslRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"

if (Test-Path $wslRegPath) {
    $distroKeys = Get-ChildItem $wslRegPath
    foreach ($key in $distroKeys) {
        $props = Get-ItemProperty $key.PsPath
        $distroName = $props.DistributionName.Replace("`0", "").Trim()
        $rawBasePath = $props.BasePath -replace '^\\\\\?\\', ''
        
        if (Test-Path $rawBasePath) {
            # CORRECTION: Changed -Recurrusive to -Recurse
            $foundVhdxFiles = Get-ChildItem -Path $rawBasePath -Filter "*.vhdx" -Recurse -File -ErrorAction SilentlyContinue
            
            foreach ($file in $foundVhdxFiles) {
                $sizeGB = [math]::Round($file.Length / 1GB, 2)
                
                # Make the menu readable by showing the subfolder layout cleanly
                $relativeLabel = $file.FullName.Replace($rawBasePath, "").TrimStart("\")
                $cleanLabel = "$distroName [$relativeLabel]"
                
                Write-Host " Found: [$($targetList.Count)] $cleanLabel ($sizeGB GB)"
                
                $targetList += [PSCustomObject]@{ 
                    Name  = $distroName; 
                    Label = $cleanLabel; 
                    Path  = $file.FullName; 
                    Size  = $sizeGB 
                }
            }
        }
    }
}

if ($targetList.Count -eq 0) {
    Write-Error "No virtual disks found on your system."
    Exit
}

# 3. SELECT TARGET VIA THE DYNAMICALLY GENERATED LIST
$choice = -1
while ($choice -lt 0 -or $choice -ge $targetList.Count) {
    $input = Read-Host "`nSelect the number of the distribution file to clean and compact"
    if (![int]::TryParse($input, [ref]$choice) -or $choice -lt 0 -or $choice -ge $targetList.Count) {
        Write-Host "Invalid choice. Please pick a number from the list above." -ForegroundColor Red
    }
}

$selected = $targetList[$choice]
Write-Host "`nStarting cleanup for: $($selected.Label)" -ForegroundColor Green

# 4. INTERNAL CLEANUP (WHILE RUNNING)
Write-Host "`nStep 1: Running internal file pruning..." -ForegroundColor Cyan
if ($selected.Name -like "*docker*") {
    if (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
        Write-Host "Pruning active Docker system and builder caches..." -ForegroundColor Gray
        docker system prune -a --volumes -f
        docker builder prune --all -f
    } else {
        Write-Host "Docker Desktop application is offline. Skipping CLI container pruning." -ForegroundColor Yellow
    }
} else {
    Write-Host "Trimming Linux filesystem for $($selected.Name)..." -ForegroundColor Gray
    wsl -d $selected.Name --user root fstrim -av 2>$null
}

# 5. BRUTE-FORCE UNLOCK (RELEASES HANDLES)
Write-Host "`nStep 2: Shutting down WSL and Docker services to unlock files..." -ForegroundColor Cyan
wsl --shutdown
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "com.docker.service", "LxssManager", "VmCompute" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# 6. COMPACTION AND AUTO-MANAGEMENT
Write-Host "`nStep 3: Compacting storage and ensuring Sparse mode is active..." -ForegroundColor Cyan
# Uses --allow-unsafe to bypass modern Windows corruption warnings for sparse mode
wsl --manage $selected.Name --set-sparse true --allow-unsafe 2>$null

try {
    Optimize-VHD -Path $selected.Path -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Optimize-VHD failed. Falling back to native Diskpart routine..." -ForegroundColor Yellow
    $dp = "select vdisk file=""$($selected.Path)""`nattach vdisk readonly`ncompact vdisk`ndetach vdisk`nexit"
    $dp | diskpart
}

# 7. FINAL RESULTS STATEMENT
$finalSize = [math]::Round((Get-Item $selected.Path).Length / 1GB, 2)
Write-Host "`n==========================================" -ForegroundColor Green
Write-Host ("Reclamation complete! Saved: {0:N2} GB" -f ($selected.Size - $finalSize))
Write-Host ("New structural file size: {0:N2} GB" -f $finalSize) -ForegroundColor Green
Write-Host "You may now restart Docker Desktop and WSL."
Write-Host "==========================================" -ForegroundColor Green
