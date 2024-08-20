
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
	JAVA_HOME = "C:\data\apps\#dev\jdk\jdk-11.0.15.1";
	SUBLIME_HOME = "C:\data\apps\#dev\sublime";
	INTELLIJ_HOME = "C:\data\apps\#dev\intellijc\2022.2";
	VSCODE_HOME = "C:\data\apps\#dev\vscode";
	ZIP_HOME = "C:\data\apps\#dev\7-Zip";
	DIVE_HOME = "C:\data\apps\#dev\dive";
	GOROOT = "C:\data\apps\#dev\go";
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
	#"install nvm" = "C:\data\apps\#dev\_install\nvm-setup.exe";

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

	"setup git" = "git config --global core.autocrlf false; git config --global core.eol lf; git config --global core.longpaths true; git config --global credential.helper !""C:/Data/apps/#dev/git/mingw64/bin/git-credential-manager-core.exe""; git config --global gpg.program ""C:/Data/apps/#dev/git/usr/bin/gpg.exe""; git config --global gpg.program ""C:/Data/apps/#dev/git/usr/bin/gpg.exe"";  git config --global credential.helperselector.selected manager-core;   ";	
	"setup gpg" = "gpg --import ./_secret/maxbarrass-gpg; gpg --list-secret-keys --keyid-format LONG";	
	"setup git creds" = "git config --global user.name wildone; git config --global user.email max.barrass@gmail.com; git config --global user.signingkey 4AB36884B8575217; git config --global commit.gpgsign true";	
	
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
		Write-Output "****************************************"
	}

}