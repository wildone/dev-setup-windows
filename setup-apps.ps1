
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

# Read .env file
$ENV_DESTINATION_SCOPE="script" # local, user, machine, process
Get-Content .env | ForEach-Object {
	# if line is empty or starts with #, skip it
	$line = $_.Trim()
	if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
		# skip comments and empty lines
		return
	}

	$name, $value = $_.split('=')

	if ([string]::IsNullOrWhiteSpace($name) -or $name.Trim() -match '^\s*#') {
		return
	}
	
	# remove comments from value
	# find index of fist # in value but not if its surrounded by double quotes
	$matches = [regex]::Matches($value, '(?<!")#(?!")')

	# Filter out matches that are actually within double quotes
	$filteredMatches = $matches | Where-Object {
		$beforeMatch = $value.Substring(0, $_.Index)
		$afterMatch = $value.Substring($_.Index + 1)
		
		# Ensure the match is not within double quotes
		($beforeMatch -split '"').Count % 2 -eq 1 -and ($afterMatch -split '"').Count % 2 -eq 1
	}

	# If matches are found, get the first match index
	if ($filteredMatches.Count -gt 0) {
		$firstMatch = $filteredMatches[0]
		$firstIndex = $firstMatch.Index
		$value = $value.Substring(0, $firstIndex)
	}

	# trim and remove double quotes from value
	$value = $value.Trim().Trim('"')
	
	if($ENV_DESTINATION_SCOPE -eq "machine")
	{
		if (Test-Administrator == $False) {
			Write-Error "Please run script as administrator to set environment variables for machine."
			exit 1
		}
	}

	# choose where to store the environment variable
	switch ($ENV_DESTINATION) {
		"process" {
			[Environment]::SetEnvironmentVariable($name, $value, 0) # 0 = [System.EnvironmentVariableTarget]::Process
		}
		"user" {
			[Environment]::SetEnvironmentVariable($name, $value, 1) # 1 = [System.EnvironmentVariableTarget]::User
		}
		"machine" {
			[Environment]::SetEnvironmentVariable($name, $value, 2) # 2 = [System.EnvironmentVariableTarget]::Machine
		}
		# default to script
		default {
			Set-Variable -Name $name -Value $value
		}
	}
}

function Convert-Path($path) {
	$path = $path -replace '\\', '\/'
	return $path
}

# VARIABLES
$VARS=@{
	PYTHON_HOME = "$DEV_APPS_PATH\python\3.10.6";
	GIT_HOME = "$DEV_APPS_PATH\git";
	M2_HOME = "$DEV_APPS_PATH\apache-maven\3.8.6";
	JAVA_HOME = "$DEV_APPS_PATH\jdk\jdk-11.0.15.1";
	SUBLIME_HOME = "$DEV_APPS_PATH\sublime";
	INTELLIJ_HOME = "$DEV_APPS_PATH\intellijc\2022.2";
	VSCODE_HOME = "$DEV_APPS_PATH\vscode";
	ZIP_HOME = "$DEV_APPS_PATH\7-Zip";
	DIVE_HOME = "$DEV_APPS_PATH\dive";
	GOROOT = "$DEV_APPS_PATH\go";
}

$PATH=[System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
Write-Output "---------------------------"
Write-Output "PATH = $PATH"
Write-Output "---------------------------"


Write-Output "---------------------------"
Write-Output "-- RUN SETUP USER        --"
Write-Output "---------------------------"

$SETUP_EXEC = @{
	"install icloud" = "winget install 9PKTQ5699M62 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install windows terminal" = "winget install 9N0DX20HK701 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install slack" = "winget install 9WZDNCRDK3WP --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install firefox" = "winget install 9NZVDKPMR9RD --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install opera" = "winget install XP8CF6S8G2D5T6 --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install discord" = "winget install XPDC2RH70K22MN --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install drawio" = "winget install 9MVVSZK43QQW --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install telegram" = "winget install 9NZTWSQNTD0S --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install whatsapp" = "winget install 9NKSQGP7F2NH --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install skype" = "winget install 9WZDNCRFJ364 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install vlc" = "winget install XPDM1ZW6815MQM --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install brave" = "winget install XP8C9QZMS2PC1T --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install vscode" = "winget install XP9KHM4BK9FZ7Q --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install wsl Ubuntu 22.04 LTS" = "winget install 9PN20MSR04DW --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install ws Debian" = "winget install 9MSVKQC78PK6 --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install office" = "winget install 9WZDNCRD29V9 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install teams" = "winget install XP8BT8DW290MPQ --source msstore --silent --accept-package-agreements --accept-source-agreements";
	
	
	"install docker" = "winget install Docker.DockerDesktop --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install postman" = "winget install Postman.Postman --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install chrome" = "winget install Google.Chrome --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install GoogleDrive" = "winget install Google.GoogleDrive --source winget --silent --accept-package-agreements --accept-source-agreements";
	
	"install Malwarebytes" = "winget install Malwarebytes.Malwarebytes --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install Grammarly" = "winget install Grammarly.Grammarly --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install Obsidian" = "winget install Obsidian.Obsidian --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install Element Gitter" = "winget install Element.Element --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install nvm" = "winget install CoreyButler.NVMforWindows --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install visual studio 2022" = "winget install XPDCFJDKLZJLP8 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	
	"install Nvidia.GeForceExperience" = "winget install Nvidia.GeForceExperience --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install Nvidia.CUDA" = "winget install Nvidia.CUDA --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install Microsoft.PowerToys" = "winget install Microsoft.PowerToys --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install Azure VPN Client" = "winget install 9NP355QT2SQB --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install Anaconda.Miniconda3" = "winget install Anaconda.Miniconda3 --source winget --silent --accept-package-agreements --accept-source-agreements";	

	"install MS Remote Desktop" = "winget install 9WZDNCRFJ3PS --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install Company Portal" = "winget install 9WZDNCRFJ3PZ --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install PHP XAMPP" = "winget install -e --id ApacheFriends.Xampp.8.2";
	

	#"install wsl2" = "C:\data\apps\#dev\_install\wsl_update_x64.msi";
	"install wsl" = "wsl --install";
	"install wsl2" = "dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart";
	"set wsl2" = "wsl --set-default-version 2";	

	"setup git config" = "git config --global core.autocrlf false; git config --global core.eol lf; git config --global core.longpaths true;  ";	
	"setup git helper credentials" = "git config --global credential.helper !""$(Convert-Path("$DEV_APPS_PATH/git-credential-manager/git-credential-manager.exe"))""; git config --global credential.helperselector.selected manager;  ";	
	"setup git helper gpg " = "git config --global gpg.program ""$(Convert-Path("$DEV_APPS_PATH/git/usr/bin/gpg.exe"))""; git config --global gpg.program ""$(Convert-Path("$DEV_APPS_PATH/git/usr/bin/gpg.exe"))"";  ";	
	"setup gpg" = "gpg --import $GPG_KEY; gpg --list-secret-keys --keyid-format LONG";	
	"setup git creds" = "git config --global user.name $GIT_USERNAME; git config --global user.email $GIT_EMAIL; git config --global user.signingkey $GIT_SIGNINGKEY; git config --global commit.gpgsign true";	
	
}

if(Test-Administrator)
{
    Write-Error "To run setup steps run as normal user."
    exit 1
} else {

	$SETUP_EXEC.keys | ForEach-Object {
		Write-Output "$_ = $($SETUP_EXEC[$_])"
		Write-Output "****************************************"
		Invoke-Expression -Command $($SETUP_EXEC[$_])
		# Write-Debug "Invoke-Expression -Command $($SETUP_EXEC[$_])"
		Write-Output "****************************************"
	}

}