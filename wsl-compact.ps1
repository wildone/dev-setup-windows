# Requires -RunAsAdministrator

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script MUST be run as an Administrator. Please reopen PowerShell as Admin and try again."
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "     UNIVERSAL WSL & DOCKER CLEANUP       " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Fetch and sanitise all installed distributions
Write-Verbose "Querying WSL for installed distributions..." -Verbose
$wslOutput = wsl --list --quiet
$wslDistros = @()

foreach ($line in $wslOutput) {
    $cleanLine = $line.Replace("`0", "").Trim()
    if (-not [string]::IsNullOrWhiteSpace($cleanLine)) {
        # Skip background engine layers unless manually specified later
        if ($cleanLine -ne "docker-desktop-data") {
            $wslDistros += $cleanLine
        }
    }
}

if ($wslDistros.Count -eq 0) {
    Write-Error "No active WSL distributions detected on this system."
    Exit
}

# 2. Select Target
Write-Host "`nAvailable Targets:" -ForegroundColor Yellow
for ($i = 0; $i -lt $wslDistros.Count; $i++) {
    Write-Host " [$i] $($wslDistros[$i])"
}
# Manually inject the data layer for completeness if Docker is active
$dockerIndex = $wslDistros.Count
if (wsl --list --quiet | Select-String "docker-desktop-data") {
    Write-Host " [$dockerIndex] docker-desktop-data (Your 300GB+ Docker Storage File)"
}

$choice = -1
while ($choice -lt 0 -or $choice -gt $dockerIndex) {
    $input = Read-Host "`nSelect the number of the distribution to clean and compact"
    if ([int]::TryParse($input, [ref]$choice)) {
        if ($choice -lt 0 -or $choice -gt $dockerIndex) {
            Write-Host "Invalid choice. Pick a valid number from the list." -ForegroundColor Red
        }
    } else {
        Write-Host "Please enter a valid integer." -ForegroundColor Red
        $choice = -1
    }
}

# Assign the true target distribution name
if ($choice -eq $dockerIndex) {
    $targetDistro = "docker-desktop-data"
} else {
    $targetDistro = $wslDistros[$choice]
}
Write-Host "Selected Target: $targetDistro" -ForegroundColor Green

# 3. Step 1: Internal Cleanup Environment Aware
Write-Host "`nStep 1: Running deep internal cache purges..." -ForegroundColor Cyan
if ($targetDistro -like "*docker*") {
    Write-Warning "Target is Docker. Ensuring Docker daemon purges unused image assets and build layers..."
    # Attempt to use native docker CLI if daemon is online
    if (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
        docker system prune -a --volumes -f
    } else {
        Write-Host "Docker Desktop app is closed. Skipping live Docker pruning (will proceed straight to file shrinkage)." -ForegroundColor Yellow
    }
} else {
    Write-Host "Target is a Linux distro ($targetDistro). Purging package managers and system caches..." -ForegroundColor Gray
    wsl -d $targetDistro --user root apt-get clean 2>$null
    wsl -d $targetDistro --user root apt-get autoremove -y 2>$null
    wsl -d $targetDistro --user root rm -rf /root/.cache/* 2>$null
    wsl -d $targetDistro --user root fstrim -av 2>$null
}

# 4. Resolve exact file path using Registry lookup + fallback engines
Write-Verbose "Resolving physical path file markers..." -Verbose
$wslRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
$distroGuid = Get-ChildItem $wslRegPath | Where-Object { 
    (Get-ItemProperty $_.PsPath).DistributionName -eq $targetDistro 
}

$vhdxPath = ""
if ($distroGuid) {
    $rawBasePath = (Get-ItemProperty $distroGuid.PsPath).BasePath
    $cleanBasePath = $rawBasePath -replace '^\\\\\?\\', ''
    
    # Docker uses custom naming layouts inside its subdirectories
    if ($targetDistro -eq "docker-desktop-data") {
        if (Test-Path (Join-Path $cleanBasePath "disk\docker_data.vhdx")) {
            $vhdxPath = Join-Path $cleanBasePath "disk\docker_data.vhdx"
        } else {
            $vhdxPath = Join-Path $cleanBasePath "ext4.vhdx"
        }
    } else {
        $vhdxPath = Join-Path $cleanBasePath "ext4.vhdx"
    }
}

# Absolute emergency hardcoded fallback for maxbarrass environment profile
if (-not (Test-Path $vhdxPath) -and ($targetDistro -eq "docker-desktop-data")) {
    $vhdxPath = "C:\Users\maxbarrass\AppData\Local\Docker\wsl\disk\docker_data.vhdx"
}

if (-not (Test-Path $vhdxPath)) {
    Write-Error "Could not map physical file layout target path for: $vhdxPath"
    Exit
}

$initialSize = (Get-Item $vhdxPath).Length / 1GB
Write-Host ("Current disk file footprint: {0:N2} GB" -f $initialSize) -ForegroundColor Yellow

# 5. Lock and Terminate
Write-Host "`nStep 2: Shutting down WSL subsystems to drop storage handles..." -ForegroundColor Cyan
wsl --shutdown
Start-Sleep -Seconds 5

# 6. Unset Sparse temporarily to ensure Windows engine hooks execute correctly
Write-Host "`nStep 3: Temporarily releasing sparse lock blocks..." -ForegroundColor Cyan
wsl --manage $targetDistro --set-sparse false 2>$null

# 7. Compaction Phase
Write-Host "`nStep 4: Executing storage block compression..." -ForegroundColor Cyan
try {
    Optimize-VHD -Path $vhdxPath -Mode Full -ErrorAction Stop
} catch {
    Write-Host "Note: Optimize-VHD unavailable. Compacting using Windows Diskpart tool..." -ForegroundColor Yellow
    $diskpartScript = @"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    $diskpartScript | diskpart
}

# 8. Re-enable Dynamic Sparse Engine Management
Write-Host "`nStep 5: Enforcing sparse flags for continuous auto-reclamation..." -ForegroundColor Cyan
wsl --manage $targetDistro --set-sparse true 2>$null

# 9. Results Summary
$finalSize = (Get-Item $vhdxPath).Length / 1GB
$spaceSaved = $initialSize - $finalSize

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "Cleanup Operations Finished Successfully!" -ForegroundColor Green
Write-Host ("New structural file size: {0:N2} GB" -f $finalSize)
Write-Host ("Total storage space recovered: {0:N2} GB" -f $spaceSaved)
Write-Host "==========================================" -ForegroundColor Green
