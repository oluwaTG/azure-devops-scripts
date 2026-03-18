install-custom-tools.ps1

Purpose
-------
A small convenience PowerShell installer used to bootstrap common developer/DevOps tools on Windows VMs. It was designed to be invoked from Terraform (or other VM provisioning tooling) to prepare a machine for labs or demos, but you can run it interactively on any Windows host.

What it does
------------
- Installs Chocolatey (if missing) and then installs requested packages using choco.
- Optionally prepares WSL2 tooling (kubectl, helm, minikube) by creating a scheduled task that runs a bash installer inside WSL.
- Logs actions to a central state/logs directory.
- Is idempotent for choco packages (skips packages that are already installed).

Location
--------
The script is at:

`./scripts/powershell/Install-Tools/install-custom-tools.ps1`

Requirements / Notes
--------------------
- Windows 10/11 or Windows Server with PowerShell.
- Run with Administrator privileges for system-level installs and feature changes.
- Internet access to download Chocolatey and packages.
- If you request WSL tooling (kubectl/helm/minikube), you should provide a user account and password via `-RunAsUser` / `-RunAsPassword` so the script can create a scheduled task that runs as that user inside WSL.

Usage
-----
Open an elevated PowerShell prompt and run the script with the switches for the tools you want. Example:

```powershell
# Install common tools interactively
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-custom-tools.ps1 -VsCode -AzCli -DotNet -Git -Terraform

# Install WSL tooling: must supply user credentials for the scheduled task
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-custom-tools.ps1 -Kubectl -Helm -Minikube -RunAsUser "demo-user" -RunAsPassword "P@ssw0rd"
```

Available switches
------------------
- `-VsCode`  - Visual Studio Code
- `-AzCli`   - Azure CLI
- `-DotNet`  - .NET SDK
- `-NodeJs`  - Node.js LTS
- `-DockerDesktop` - Docker Desktop
- `-DockerEngine`  - Docker engine
- `-Terraform` - Terraform
- `-Kubectl`  - kubernetes-cli
- `-Helm`     - kubernetes-helm
- `-Minikube` - minikube
- `-Python`, `-Git`, `-Jq`, `-Yq`, `-Bicep`, `-Make` - other common tools

Logging and state
-----------------
The script writes state and logs to:

- State directory: `C:\ProgramData\DevOpsSetup`
- Main log: `C:\ProgramData\DevOpsSetup\logs\install-custom-tools.log`
- Transcript (if available): `C:\ProgramData\DevOpsSetup\logs\transcript.log`
- WSL scheduled task log: `C:\ProgramData\DevOpsSetup\logs\run-wsl-tools.log`

A "phase1" marker file is created at `C:\ProgramData\DevOpsSetup\phase1.done` when the run completes successfully.

WSL tooling and scheduled task
------------------------------
When WSL-related switches are requested the script:
- Enables WSL and VirtualMachinePlatform features (best-effort).
- Writes a bash installer to `C:\ProgramData\DevOpsSetup\wsl-tools.sh` (this will be run inside the chosen Ubuntu WSL distro).
- Writes a scheduled task script and registers a scheduled task named `DevOps-WSL-Tooling` that runs as the provided `-RunAsUser` at a short delay. The scheduled task runs the WSL-side installer so heavy WSL operations don't run in the system provisioning context.

Behavior notes
--------------
- The script uses Chocolatey package names (e.g. `kubernetes-cli`, `kubernetes-helm`, `minikube`). If you need different versions, edit the script or install manually.
- Chocolatey installation is performed automatically if `choco.exe` is missing.
- The script is idempotent for choco packages and will skip already-installed packages.
- Some operations may require a restart (e.g., enabling WSL features); the script sets a restart flag and will reboot if necessary.

Troubleshooting
---------------
- If Chocolatey fails to install, inspect the download/run of `https://community.chocolatey.org/install.ps1` in the log file.
- Check the main log: `C:\ProgramData\DevOpsSetup\logs\install-custom-tools.log` for step-by-step output.
- If WSL scheduled task fails to create, verify the `-RunAsUser` and `-RunAsPassword` were correct and that the account exists.
- If minikube or helm fail inside WSL, examine `C:\ProgramData\DevOpsSetup\wsl-tools.sh` and `C:\ProgramData\DevOpsSetup\logs\run-wsl-tools.log` (the scheduled task writes detailed logs).

Re-running the script
---------------------
It's safe to re-run the script. Installed choco packages are detected and skipped. The WSL scheduled task creation will delete and recreate the task if necessary.

License / Attribution
---------------------
Use and modify as you like. This script is intended for labs and demos and may be opinionated (package versions, user setup). Review before use in production.
