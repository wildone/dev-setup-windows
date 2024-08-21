# Dev Setup Windows

This is how I configure my Windows development environment.

Thid allows me to remove the need to manually install and configure software on a new machine.

I prefer to use portable applications where possible, as they can be easily backed up and restored.

All other programs are installed using native `winget`.

I have fixed path where I install all my dev apps and its configured in the `.env` file.

## Principles

1. **Automation** - I want to be able to run a single script and have my entire development environment configured.
2. **Portability** - I want to be able to easily backup and restore my development environment.
3. **No Admin Rights** - I want to be able to configure my development environment without needing admin rights, hence no Chocolatey as it follows admin first approach. Admin rights are only needed for some envriorment variables and file associations.
4. **Native Bash Utils** - In very rare cases I want to be able to use bash utils natively this is done using Git/usr/bin.
5. **No Mingw or Cygwin** - I say no Mingw or Cygwin, because it only causes you pain and you don't even know why you are using it.
6. **WSL only Docker** - If you cant use Docker Desktop, then use WSL2 with Docker, nothing else.
7. **No Bash** - I have written so many bash scripts, but I am done with it. Moved to Powershell and not looking back, core version runs on all platforms anyways, so I keep my scripts simple.

## Usage

To get started:

1. Install Powershell 7
2. Clone this repository
3. update the `.env` file
    - update path to files, if needed
    - update your git into
4. run `setup-apps.ps1` to install all the apps
5. run `setup-env.ps1` to configure environment variables and file associations
6. IF needed, run `setup-env-admin.ps1` to update registry settings

## Scripts

Here is a list of scripts included in this repository and their purpose:

1. `setup-apps.ps1`: This script installs all the necessary applications for the development environment. It uses the native `winget` package manager to install the applications specified in the `.env` file.
2. `setup-env.ps1`: This script configures environment variables and file associations for the development environment. It sets up the necessary paths and associations to ensure smooth operation of the installed applications.
3. `setup-env-admin.ps1`: This script is optional and should only be run if there is a need to update registry settings. It requires administrative rights and should be used sparingly.
4. `functions.ps1`: This script contains helper functions used by the other scripts. It is sourced by the other scripts to provide common functionality.

These scripts are designed to automate the setup process and ensure consistency across different machines. By running these scripts, you can easily configure your development environment without the need for manual installation and configuration.

