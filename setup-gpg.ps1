# include project helper functions
. "${PWD}\functions.ps1"


Write-Output "---------------------------"
Write-Output "-- RUN SETUP USER        --"
Write-Output "---------------------------"

function Refresh-ProcessPath {
	$machinePath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
	$userPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
	$env:Path = (@($machinePath, $userPath) -ne $null) -join ";"
}

function Resolve-GpgPath {
	$cmd = Get-Command gpg -ErrorAction SilentlyContinue
	if ($cmd) {
		return $cmd.Path
	}

	$candidates = @(
		"$env:ProgramFiles\GnuPG\bin\gpg.exe",
		"$env:ProgramFiles(x86)\GnuPG\bin\gpg.exe"
	)

	foreach ($candidate in $candidates) {
		if (Test-Path $candidate) {
			return $candidate
		}
	}

	return $null
}

$SETUP_EXEC = @{
	"install Git For Windows" = "winget install Microsoft.Git  --silent --accept-package-agreements --accept-source-agreements";
	"install gpg" = "winget install GnuPG.Gpg4win --source msstore --silent --accept-package-agreements --accept-source-agreements";

	"setup git config" = "git config --global core.autocrlf false; git config --global core.eol lf; git config --global core.longpaths true;  ";	
	"setup git helper credentials" = "git config --global credential.helper !""$(Convert-Path("$DEV_APPS_PATH/git-credential-manager/git-credential-manager.exe"))""; git config --global credential.helperselector.selected manager;  ";	
	"setup git creds" = "git config --global user.name $GIT_USERNAME; git config --global user.email $GIT_EMAIL; git config --global user.signingkey $GIT_SIGNINGKEY; git config --global commit.gpgsign true";	
	"setup git symlink support" = "git config --global core.symlinks true";
}

# $env:__COMPAT_LAYER = "RunAsInvoker"

$SETUP_EXEC.keys | ForEach-Object {
	Write-Output "$_ = $($SETUP_EXEC[$_])"
	Write-Output "****************************************"
	Invoke-Expression -Command $($SETUP_EXEC[$_])
	# Write-Debug "Invoke-Expression -Command $($SETUP_EXEC[$_])"
	Write-Output "****************************************"
}

Refresh-ProcessPath
$GPG_PATH = Resolve-GpgPath
if (-not $GPG_PATH) {
    Write-Output "GPG not found on PATH. Please ensure Gpg4win is installed and re-run."
    exit 1
}

Write-Output "GPG path = $GPG_PATH"
git config --global gpg.program "$(Convert-Path($GPG_PATH))"

if (-not (Test-Path $GPG_KEY)) {
    Write-Output "GPG key not found at: $GPG_KEY"
    Write-Output "Copy the key, then re-run setup-gpg.ps1."
    exit 1
}

gpg --import $GPG_KEY
gpg --list-secret-keys --keyid-format LONG
