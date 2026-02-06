# include project helper functions
. "${PWD}\functions.ps1"


Write-Output "---------------------------"
Write-Output "-- RUN SETUP USER        --"
Write-Output "---------------------------"

$SETUP_EXEC = @{
	"install icloud" = "winget install 9PKTQ5699M62 --source msstore --silent --accept-package-agreements --accept-source-agreements";

  	"install Powershell 7" = "winget install Microsoft.PowerShell  --silent --accept-package-agreements --accept-source-agreements";
   	"install Git For Windows" = "winget install Microsoft.Git  --silent --accept-package-agreements --accept-source-agreements";
   	"install onlykey" = "winget install CryptoTrust.OnlyKeyApp  --silent --accept-package-agreements --accept-source-agreements";

#	"install windows terminal" = "winget install 9N0DX20HK701 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install slack" = "winget install 9WZDNCRDK3WP --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install firefox" = "winget install 9NZVDKPMR9RD --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install firefox dev" = "winget install Mozilla.Firefox.DeveloperEdition --silent --accept-package-agreements --accept-source-agreements";	
	"install opera" = "winget install XP8CF6S8G2D5T6 --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install discord" = "winget install XPDC2RH70K22MN --source msstore --silent --accept-package-agreements --accept-source-agreements";	
	"install drawio" = "winget install 9MVVSZK43QQW --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install telegram" = "winget install 9NZTWSQNTD0S --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install whatsapp" = "winget install 9NKSQGP7F2NH --source msstore --silent --accept-package-agreements --accept-source-agreements";
	#"install skype" = "winget install 9WZDNCRFJ364 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	#"install vlc" = "winget install XPDM1ZW6815MQM --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install brave" = "winget install XP8C9QZMS2PC1T --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install vscode" = "winget install XP9KHM4BK9FZ7Q --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install office" = "winget install 9WZDNCRD29V9 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install teams" = "winget install XP8BT8DW290MPQ --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install Foxit.FoxitReader" = "winget install Foxit.FoxitReader --silent --accept-package-agreements --accept-source-agreements";

	"install Foxit.WiFimanDesktop" = "winget install UbiquitiInc.WiFimanDesktop  --silent --accept-package-agreements --accept-source-agreements";

	"install gpg" = "winget install GnuPG.Gpg4win --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"install 1password" = "winget install AgileBits.1Password --silent --accept-package-agreements --accept-source-agreements";

	"install NoMachine" = "winget install NoMachine.NoMachine --silent --accept-package-agreements --accept-source-agreements";

	"install Cursor" = "winget install Anysphere.Cursor --silent --accept-package-agreements --accept-source-agreements";

	"install Microsoft.WindowsApp" = "winget install Microsoft.WindowsApp --silent --accept-package-agreements --accept-source-agreements";

	"install docker" = "winget install Docker.DockerDesktop --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install postman" = "winget install Postman.Postman --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install chrome" = "winget install Google.Chrome --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install GoogleDrive" = "winget install Google.GoogleDrive --source winget --silent --accept-package-agreements --accept-source-agreements";
	
	"install Malwarebytes" = "winget install Malwarebytes.Malwarebytes --silent --accept-package-agreements --accept-source-agreements";
	"install Grammarly" = "winget install Grammarly.Grammarly --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install Obsidian" = "winget install Obsidian.Obsidian --source winget --silent --accept-package-agreements --accept-source-agreements";

#	"install Element Gitter" = "winget install Element.Element --source winget --silent --accept-package-agreements --accept-source-agreements";

	"install nvm" = "winget install CoreyButler.NVMforWindows --source winget --silent --accept-package-agreements --accept-source-agreements";
	"install GnuWin32.Zip" = "winget install GnuWin32.Zip --silent --accept-package-agreements --accept-source-agreements";
	
#	"install visual studio 2022" = "winget install XPDCFJDKLZJLP8 --source msstore --silent --accept-package-agreements --accept-source-agreements";
	
	"install Nvidia.GeForceExperience" = "winget install Nvidia.GeForceNow --source winget --silent --accept-package-agreements --accept-source-agreements";
#	"install Nvidia.CUDA" = "winget install Nvidia.CUDA --source winget --silent --accept-package-agreements --accept-source-agreements";

#	"install Microsoft.PowerToys" = "winget install Microsoft.PowerToys --source winget --silent --accept-package-agreements --accept-source-agreements";

#	"install Azure VPN Client" = "winget install 9NP355QT2SQB --source msstore --silent --accept-package-agreements --accept-source-agreements";

#	"install Anaconda.Miniconda3" = "winget install Anaconda.Miniconda3 --source winget --silent --accept-package-agreements --accept-source-agreements";	

#	"install MS Remote Desktop" = "winget install 9WZDNCRFJ3PS --source msstore --silent --accept-package-agreements --accept-source-agreements";

#	"install Company Portal" = "winget install 9WZDNCRFJ3PZ --source msstore --silent --accept-package-agreements --accept-source-agreements";

#	"install PHP XAMPP" = "winget install ApacheFriends.Xampp.8.2 --silent --accept-package-agreements --accept-source-agreements";

#	"install Windows Subsystem for Android" = "winget install 9P3395VX91NR --source msstore --silent --accept-package-agreements --accept-source-agreements";
 	

#    	"install Kubernetes.kompose" = "winget install Kubernetes.kompose  --silent --accept-package-agreements --accept-source-agreements";
#        "install Kubernetes.kubectl" = "winget install Kubernetes.kubectl --silent --accept-package-agreements --accept-source-agreements";
          	
	"install Visual Studio VSCode" = "winget install Microsoft.VisualStudioCode  --silent --accept-package-agreements --accept-source-agreements";

#       "install mitmproxy" = "winget install mitmproxy.mitmproxy --silent --accept-package-agreements --accept-source-agreements";

#        "install jq" = "winget install jqlang.jq --silent --accept-package-agreements --accept-source-agreements";

#	"install minikube" = "winget install Kubernetes.minikube --silent --accept-package-agreements --accept-source-agreements";

#	"install podman" = "winget install RedHat.Podman --silent --accept-package-agreements --accept-source-agreements";
#	"install podman desktop" = "winget install RedHat.Podman-Desktop --silent --accept-package-agreements --accept-source-agreements";

	"install sublime" = "winget install SublimeHQ.SublimeText.4 --silent --accept-package-agreements --accept-source-agreements";
#	"install python 3" = "winget install Python.Python.3.10 --silent --accept-package-agreements --accept-source-agreements";
	"install intellij community" = "winget install JetBrains.IntelliJIDEA.Community --silent --accept-package-agreements --accept-source-agreements";
	
#	"install jdk 8" = "winget install Oracle.JavaRuntimeEnvironment --silent --accept-package-agreements --accept-source-agreements";
#	"install jdk 11" = "winget install ojdkbuild.openjdk.11.jdk --silent --accept-package-agreements --accept-source-agreements";
#	"install jdk 17" = "winget install Oracle.JDK.17 --silent --accept-package-agreements --accept-source-agreements";

	#"install wsl2" = "C:\data\apps\#dev\_install\wsl_update_x64.msi";
#	"install wsl" = "wsl --install";
	"install wsl2" = "dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart";
	"set wsl2" = "wsl --set-default-version 2";	

	"install wsl Ubuntu 22.04 LTS" = "winget install 9PN20MSR04DW --source msstore --silent --accept-package-agreements --accept-source-agreements";
	"install ws Debian" = "winget install 9MSVKQC78PK6 --source msstore --silent --accept-package-agreements --accept-source-agreements";


#	"setup git config" = "git config --global core.autocrlf false; git config --global core.eol lf; git config --global core.longpaths true;  ";	
#	"setup git helper credentials" = "git config --global credential.helper !""$(Convert-Path("$DEV_APPS_PATH/git-credential-manager/git-credential-manager.exe"))""; git config --global credential.helperselector.selected manager;  ";	
#	"setup git helper gpg " = "git config --global gpg.program ""$(Convert-Path("$DEV_APPS_PATH/git/usr/bin/gpg.exe"))""; git config --global gpg.program ""$(Convert-Path("$DEV_APPS_PATH/git/usr/bin/gpg.exe"))"";  ";	
#	"setup gpg" = "gpg --import $GPG_KEY; gpg --list-secret-keys --keyid-format LONG";	
#	"setup git creds" = "git config --global user.name $GIT_USERNAME; git config --global user.email $GIT_EMAIL; git config --global user.signingkey $GIT_SIGNINGKEY; git config --global commit.gpgsign true";	
	
}

# $env:__COMPAT_LAYER = "RunAsInvoker"

$SETUP_EXEC.keys | ForEach-Object {
	Write-Output "$_ = $($SETUP_EXEC[$_])"
	Write-Output "****************************************"
	Invoke-Expression -Command $($SETUP_EXEC[$_])
	# Write-Debug "Invoke-Expression -Command $($SETUP_EXEC[$_])"
	Write-Output "****************************************"
}
