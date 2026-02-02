# include project helper functions
. "${PWD}\functions.ps1"

# VARIABLES
$VARS=@{
	PYTHON_HOME = "$DEV_APPS_PATH\python\3.10.6";	
	GIT_HOME = "C:\Program Files\Git";
	#GIT_HOME = "$DEV_APPS_PATH\git";
	M2_HOME = "$DEV_APPS_PATH\apache-maven\3.8.6";
	JAVA_HOME = "$DEV_APPS_PATH\jdk\jdk-17.0.6";
	SUBLIME_HOME = "C:\Program Files\Sublime Text";
	#INTELLIJ_HOME = "$DEV_APPS_PATH\intellijc\2022.2";
#	VSCODE_HOME = "$DEV_APPS_PATH\vscode";
	ZIP_HOME = "$DEV_APPS_PATH\7-Zip";
	DIVE_HOME = "$DEV_APPS_PATH\dive";
#	GOROOT = "$DEV_APPS_PATH\go";
#	CONDA  = "$DEV_APPS_PATH\#dev\miniconda3";
#	PHP   = "$DEV_APPS_PATH\#dev\php";
}

$ENV_DESTINATION_SCOPE = "User"
$ENV_TARGET = [System.EnvironmentVariableTarget]::$ENV_DESTINATION_SCOPE

Write-Output "---------------------------"
Write-Output "-- UPDATE ENV VARIABLES  --"
Write-Output "---------------------------"

$VARS.keys | ForEach-Object {
	$VAL = [System.Environment]::GetEnvironmentVariable($_, $ENV_TARGET)
	$RVAL = $($VARS[$_])
	if (-not $VAL -eq $RVAL) {
		Write-Output "$_ = $($VARS[$_])"
		[System.Environment]::SetEnvironmentVariable($_, $($VARS[$_]), $ENV_TARGET)
	} else {
		Write-Output "$_ = $($VARS[$_])"
	}
}

Write-Output "---------------------------"
Write-Output "-- CHECK ENV VARIABLES   --"
Write-Output "---------------------------"

$VARS.keys | ForEach-Object {
	#$VAL = $(Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name $_).path

	$VAL = [System.Environment]::GetEnvironmentVariable($_, $ENV_TARGET)
	Write-Output "$_ = $VAL"
}



Write-Output "---------------------------"
Write-Output "-- UPDATE FILE ASSOC     --"
Write-Output "---------------------------"


$FILE_ASSOC=@{
	".ps1" = "$($VARS['SUBLIME_HOME'])\sublime_text.exe";
	".7z" = "$($VARS['ZIP_HOME'])\7zFM.exe"
}

if (Test-Administrator) {
	$FILE_ASSOC.keys | ForEach-Object {
		Write-Output "$_ = $($FILE_ASSOC[$_])"
		Create-Association  $_ $($FILE_ASSOC[$_])
	}
} else {
	Write-Output "Skipping file associations (requires administrator)."
}


Write-Output "---------------------------"
Write-Output "-- UPDATE PATH           --"
Write-Output "---------------------------"

$PATH_VARS=@{
	PYTHON_HOME = $($VARS['PYTHON_HOME']);
	PYTHON_SCRIPTS = "$($VARS['PYTHON_HOME'])\Scripts";
	GIT_HOME = "$($VARS['GIT_HOME'])\bin";
	GIT_HOME_USER = "$($VARS['GIT_HOME'])\usr\bin";
	M2_HOME = "$($VARS['M2_HOME'])\bin";
	JAVA_HOME = "$($VARS['JAVA_HOME'])\bin";
	SUBLIME_HOME = $($VARS['SUBLIME_HOME']);
#	VSCODE_HOME = "$($VARS['VSCODE_HOME'])\bin";
	ZIP_HOME = "$($VARS['ZIP_HOME'])";
	DIVE_HOME = "$($VARS['DIVE_HOME'])";
#	GOROOT = "$($VARS['GOROOT'])\bin";
#	CONDA = "$($VARS['CONDA'])";
#	PHP = "$($VARS['PHP'])";		
}

$PATH_VALUE = [System.Environment]::GetEnvironmentVariable("PATH", $ENV_TARGET)
if ([string]::IsNullOrWhiteSpace($PATH_VALUE)) {
	$PATH_VALUE = ""
}

$PATH_LIST = $PATH_VALUE -split ";"
$PATH_UPDATE = $False
$PATH_VARS.keys | ForEach-Object {
	if ($PATH_LIST -contains "$($PATH_VARS[$_])") { 
		Write-Output "Path already has: $($PATH_VARS[$_])"
	} else {
		Write-Output "Appending to path: $($PATH_VARS[$_])"
		if ([string]::IsNullOrWhiteSpace($PATH_VALUE)) {
			$PATH_VALUE = "$($PATH_VARS[$_])"
		} else {
			$PATH_VALUE="$PATH_VALUE;$($PATH_VARS[$_])"
		}
		$PATH_UPDATE = $True
	}
}
if ($PATH_UPDATE) {
	[System.Environment]::SetEnvironmentVariable("PATH", $PATH_VALUE, $ENV_TARGET)
}

Write-Output "---------------------------"
Write-Output "-- CHECK PATH            --"
Write-Output "---------------------------"
Write-Output "PATH = $([System.Environment]::GetEnvironmentVariable('PATH', $ENV_TARGET))"



Write-Output "---------------------------"
Write-Output "-- RUN SETUP              --"
Write-Output "---------------------------"

$SETUP_EXEC = @{
	"nvm set root" = "nvm root C:\data\apps\#dev\nvm\node; nvm root";
	"nvm install latest" = "nvm install latest";
	"nvm use latest" = "nvm use latest";
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

Write-Output "---------------------------"
Write-Output "-- FINISHED              --"
Write-Output "---------------------------"
