
Function Create-Association($ext, $exe) {
    $name = cmd /c "assoc $ext 2>NUL"
    if ($name) { # Association already exists: override it
        $name = $name.Split('=')[1]
    } else { # Name doesn't exist: create it
        $name = "$($ext.Replace('.',''))file" # ".log.1" becomes "log1file"
        cmd /c "assoc $ext=$name"
    }
    cmd /c "ftype $name=`"$exe`" `"%1`""
}

function Test-Administrator  
{  
    [OutputType([bool])]
    param()
    process {
        [Security.Principal.WindowsPrincipal]$user = [Security.Principal.WindowsIdentity]::GetCurrent();
        return $user.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator);
    }
}

# VARIABLES
$VARS=@{
	PYTHON_HOME = "C:\data\apps\#dev\python\3.10.6";
	GIT_HOME = "C:\data\apps\#dev\git";
	M2_HOME = "C:\data\apps\#dev\apache-maven\3.8.6";
	JAVA_HOME = "C:\data\apps\#dev\jdk\jdk-17.0.6";
	SUBLIME_HOME = "C:\data\apps\#dev\sublime";
	INTELLIJ_HOME = "C:\data\apps\#dev\intellijc\2022.2";
	VSCODE_HOME = "C:\data\apps\#dev\vscode";
	ZIP_HOME = "C:\data\apps\#dev\7-Zip";
	DIVE_HOME = "C:\data\apps\#dev\dive";
	GOROOT = "C:\data\apps\#dev\go";
	CONDA  = "C:\data\apps\#dev\miniconda3";
	PHP   = "C:\data\apps\#dev\php";
}


$PATH=[System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
Write-Output "---------------------------"
Write-Output "PATH = $PATH"
Write-Output "---------------------------"

if(-not (Test-Administrator))
{
    # TODO: define proper exit codes for the given errors 
    Write-Error "Run this script as admin to update Env Variables";
} else {


	Write-Output "---------------------------"
	Write-Output "-- UPDATE ENV VARIABLES  --"
	Write-Output "---------------------------"

	$VARS.keys | ForEach-Object {
		$VAL = [System.Environment]::GetEnvironmentVariable($_, "Machine")
		$RVAL = $($VARS[$_])
		if (-not $VAL -eq $RVAL) {
		    Write-Output "$_ = $($VARS[$_])"
		    [System.Environment]::SetEnvironmentVariable($_, $($VARS[$_]), [System.EnvironmentVariableTarget]::Machine)
	    } else {
	    	Write-Output "$_ = $($VARS[$_])"
	    }
	}

	Write-Output "---------------------------"
	Write-Output "-- CHECK ENV VARIABLES   --"
	Write-Output "---------------------------"

	$VARS.keys | ForEach-Object {
	    #$VAL = $(Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name $_).path

		$VAL = [System.Environment]::GetEnvironmentVariable($_, "Machine")
	    Write-Output "$_ = $VAL"
	}

}

if(-not (Test-Administrator))
{
    # TODO: define proper exit codes for the given errors 
    Write-Error "Run this script as admin to update File Associations";
} else {

	$FILE_ASSOC=@{
		".ps1" = "$($VARS['SUBLIME_HOME'])\sublime_text.exe";
		".7z" = "$($VARS['ZIP_HOME'])\7zFM.exe"
	}

	Write-Output "---------------------------"
	Write-Output "-- UPDATE FILE ASSOC     --"
	Write-Output "---------------------------"

	$FILE_ASSOC.keys | ForEach-Object {
	    Write-Output "$_ = $($FILE_ASSOC[$_])"
	    Create-Association  $_ $($FILE_ASSOC[$_])
	}

}

if(-not (Test-Administrator))
{
    # TODO: define proper exit codes for the given errors 
    Write-Error "Run this script as admin to update Path Environment variable";
} else {

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
		VSCODE_HOME = "$($VARS['VSCODE_HOME'])\bin";
		ZIP_HOME = "$($VARS['ZIP_HOME'])";
		DIVE_HOME = "$($VARS['DIVE_HOME'])";
		GOROOT = "$($VARS['GOROOT'])\bin";
		CONDA = "$($VARS['CONDA'])";
		PHP = "$($VARS['PHP'])";		
	}

	$PATH_LIST = $PATH -split ";"
	$PATH_UPDATE = $False
	$PATH_VARS.keys | ForEach-Object {
		if ($PATH_LIST -contains "$($PATH_VARS[$_])") { 
			Write-Output "Path already has: $($PATH_VARS[$_])"
		} else {
			Write-Output "Appending to path: $($PATH_VARS[$_])"
			$PATH="$PATH;$($PATH_VARS[$_])"
			$PATH_UPDATE = $True
		}
	}
	if ($PATH_UPDATE) {
		[System.Environment]::SetEnvironmentVariable("PATH", $PATH, [System.EnvironmentVariableTarget]::Machine)
	}

	Write-Output "---------------------------"
	Write-Output "-- CHECK PATH            --"
	Write-Output "---------------------------"
	Write-Output "PATH = $([System.Environment]::GetEnvironmentVariable('PATH', "Machine"))"

}


Write-Output "---------------------------"
Write-Output "-- RUN SETUP ADMIN       --"
Write-Output "---------------------------"

$SETUP_EXEC_ADMIN = @{
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
	$SETUP_EXEC_ADMIN.keys | ForEach-Object {
		Write-Output "$_ = $($SETUP_EXEC_ADMIN[$_])"
		Write-Output "****************************************"
		Invoke-Expression -Command $($SETUP_EXEC_ADMIN[$_])
		Write-Output "****************************************"
	}
} 

