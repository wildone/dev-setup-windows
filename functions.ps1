
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

if ($AS_ADMINISTRATOR) {
    if (!Test-Administrator) {
        Write-Error "Please run this as administrator."
        exit 1
    }
} else {
    if(Test-Administrator)
    {
        Write-Error "Please run this as normal user."
        exit 1
    }
}


$PATH=[System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
Write-Output "---------------------------"
Write-Output "PATH = $PATH"
Write-Output "---------------------------"
