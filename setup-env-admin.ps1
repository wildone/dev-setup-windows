$AS_ADMINISTRATOR = $True

# include project helper functions
. "${PWD}\functions.ps1"

Write-Output "---------------------------"
Write-Output "-- RUN SETUP ADMIN       --"
Write-Output "---------------------------"

$SETUP_EXEC = @{
	"wsl install" = "wsl --install";
	"enable remote desktop" = "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name ""fDenyTSConnections"" -value 0";
	"enable remote desktop firewall" = "Enable-NetFirewallRule -DisplayGroup ""Remote Desktop""";
	"enable network discovery" = "netsh advfirewall firewall set rule group=""Network Discovery"" new enable=Yes"
	"enabled windows long filenames filesystem" = "reg add ""HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem"" /v LongPathsEnabled /t REG_DWORD /d 0x1 /f"
	"enabled windows long filenames policy" = "reg add ""HKEY_LOCAL_MACHINE\System\CurrentControlSet\Policies"" /v LongPathsEnabled /t REG_DWORD /d 0x1 /f"
}

if(Test-Administrator)
{
	$SETUP_EXEC.keys | ForEach-Object {
		Write-Output "$_ = $($SETUP_EXEC[$_])"
		Write-Output "****************************************"
		Invoke-Expression -Command $($SETUP_EXEC[$_])
		Write-Output "****************************************"
	}
} 

