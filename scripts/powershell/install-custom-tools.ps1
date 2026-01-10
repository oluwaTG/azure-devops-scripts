param(
  [switch]$VsCode,
  [switch]$AzCli,
  [switch]$DotNet,
  [switch]$NodeJs,
  [switch]$DockerDesktop,
  [switch]$DockerEngine,
  [switch]$Terraform,
  [switch]$Kubectl,
  [switch]$Python,
  [switch]$Git,
  [switch]$Helm,
  [switch]$Jq,
  [switch]$Yq,
  [switch]$Bicep,
  [switch]$Make,
  [switch]$Minikube,

  # Needed for scheduled task to run as USER (not SYSTEM)
  [string]$RunAsUser = "",
  [string]$RunAsPassword = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$logDir  = 'C:\Windows\Temp'
$logFile = Join-Path $logDir 'toolinstall.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path $logFile -Append

function Write-Step($msg) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Write-Output "[$ts] $msg"
}

# -----------------------------
# Phase markers (prevents loops)
# -----------------------------
$StateDir     = "C:\ProgramData\DevOpsSetup"
$Phase1Marker = Join-Path $StateDir "phase1.done"
$Phase2Marker = Join-Path $StateDir "phase2.done"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$WslTaskName    = "DevOps-WSL-Tooling"
$WslTaskScript  = Join-Path $StateDir "run-wsl-tools.ps1"

# WSL tooling requested?
$NeedsWslTools = ($Kubectl -or $Helm -or $Minikube)

# Track whether we need a reboot at the end
$NeedsRestart = $false

function Ensure-Chocolatey {
  if (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe') {
    $env:Path += ';C:\ProgramData\chocolatey\bin'
    Write-Step "Chocolatey already installed."
    return
  }

  Write-Step "Downloading Chocolatey installer..."
  $chocoScript = Join-Path $logDir 'install-choco.ps1'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $chocoScript

  Write-Step "Installing Chocolatey..."
  powershell -NoProfile -ExecutionPolicy Bypass -File $chocoScript

  if (-not (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe')) {
    throw "Chocolatey installation failed (choco.exe not found)"
  }

  $env:Path += ';C:\ProgramData\chocolatey\bin'
  Write-Step "Chocolatey installed."
}

function Install-ChocoPackage {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$Params = ""
  )

  # best-effort skip if already installed
  $already = $false
  try {
    $list = choco list --local-only --exact $Name 2>$null
    if ($list -match "^$Name\s") { $already = $true }
  } catch {}

  if ($already) {
    Write-Step "Already installed: $Name"
    return
  }

  Write-Step "Installing: $Name"
  if ([string]::IsNullOrWhiteSpace($Params)) {
    choco install $Name -y --no-progress | Out-Host
  } else {
    choco install $Name -y --no-progress --params $Params | Out-Host
  }
}

function Enable-WslFeaturesIfNeeded {
  if (-not $NeedsWslTools) { return }

  Write-Step "Ensuring WSL + VirtualMachinePlatform features are enabled (needed for WSL2)..."

  $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
  $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

  if ($null -eq $wsl -or $null -eq $vmp) {
    Write-Warning "Could not query Windows optional features (possibly not Windows 10/11). Skipping WSL enable."
    return
  }

  if ($wsl.State -ne "Enabled") {
    Write-Step "Enabling feature: Microsoft-Windows-Subsystem-Linux"
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Host
    $script:NeedsRestart = $true
  }

  if ($vmp.State -ne "Enabled") {
    Write-Step "Enabling feature: VirtualMachinePlatform"
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Host
    $script:NeedsRestart = $true
  }

  try {
    Write-Step "Setting WSL2 as default version..."
    wsl --set-default-version 2 | Out-Host
  } catch {
    Write-Warning "Could not set WSL2 default yet (often requires reboot)."
    $script:NeedsRestart = $true
  }
}

function Ensure-DockerDesktopService {
  $svcName = "com.docker.service"
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if (-not $svc) {
    Write-Warning "Docker Desktop service '$svcName' not found yet. This may require reboot / first login."
    $script:NeedsRestart = $true
    return
  }

  if ($svc.Status -ne "Running") {
    Write-Step "Starting Docker Desktop service ($svcName)..."
    try {
      Start-Service -Name $svcName
      Start-Sleep -Seconds 5
    } catch {
      Write-Warning "Could not start Docker Desktop service. Likely needs reboot / first user session."
      $script:NeedsRestart = $true
      return
    }
  }

  try {
    docker version | Out-Host
  } catch {
    Write-Warning "Docker daemon not reachable yet. Likely needs reboot / WSL initialization."
    $script:NeedsRestart = $true
  }
}

function Register-WslToolingScheduledTask {
  if (-not $NeedsWslTools) { return }

  if ([string]::IsNullOrWhiteSpace($RunAsUser) -or [string]::IsNullOrWhiteSpace($RunAsPassword)) {
    Write-Warning "WSL tooling requested, but RunAsUser/RunAsPassword not provided. Skipping scheduled task creation."
    return
  }

  # Write the script that the scheduled task will run AS THE USER
  # It installs Ubuntu, then installs docker.io, kubectl, helm (binary), minikube, starts minikube.
  @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'

Write-Output "=== WSL scheduled task started at: `$(Get-Date) ==="
Write-Output "Running as: `$(whoami)"

# 1) Install Ubuntu distro (user context)
try {
  wsl --install -d Ubuntu | Out-Host
} catch {
  # If Ubuntu is already installed, this may throw or return non-zero; ignore.
  Write-Warning "wsl --install returned non-zero (often means already installed). Continuing..."
}

Start-Sleep -Seconds 10

# 2) Verify Ubuntu exists for this user
`$distros = (wsl -l -q) 2>`$null
if (-not (`$distros | Select-String -SimpleMatch "Ubuntu")) {
  Write-Warning "Ubuntu distro not detected for this user yet. Exiting without marking phase2."
  exit 0
}

# 3) Run Linux installs inside Ubuntu
`$bash = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Ubuntu WSL tooling started: $(date -Is) ==="

sudo apt-get update -y

# docker.io (Ubuntu package)
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get install -y docker.io
  sudo systemctl enable docker || true
  sudo systemctl start docker || true
fi

# kubectl (repo)
if ! command -v kubectl >/dev/null 2>&1; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y kubectl
fi

# helm v4.0.4 (binary)
if ! command -v helm >/dev/null 2>&1; then
  TMPDIR="$(mktemp -d)"
  curl -fsSL -o "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" https://get.helm.sh/helm-v4.0.4-linux-amd64.tar.gz
  tar -zxvf "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" -C "${TMPDIR}" >/dev/null
  sudo mv "${TMPDIR}/linux-amd64/helm" /usr/local/bin/helm
  sudo chmod +x /usr/local/bin/helm
  rm -rf "${TMPDIR}"
fi

# minikube (binary)
if ! command -v minikube >/dev/null 2>&1; then
  sudo curl -fsSL -o /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo chmod +x /usr/local/bin/minikube
fi

# start minikube
minikube delete || true
minikube start --driver=docker || true
minikube status || true

echo "=== Ubuntu WSL tooling completed: $(date -Is) ==="
'@

wsl -d Ubuntu -- bash -lc "`$bash"

"@ | Set-Content -Path $WslTaskScript -Encoding UTF8

  # Calculate start time 15 minutes from now in HH:mm (schtasks uses local time)
  $startTime = (Get-Date).AddMinutes(15).ToString("HH:mm")

  Write-Step "Creating scheduled task '$WslTaskName' to run at $startTime as user '$RunAsUser'..."

  # Delete existing if present
  schtasks /Delete /TN $WslTaskName /F 2>$null | Out-Null

  # Create one-time task (runs once)
  schtasks /Create /TN $WslTaskName `
    /TR "powershell -NoProfile -ExecutionPolicy Bypass -File `"$WslTaskScript`"" `
    /SC ONCE /ST $startTime /RL HIGHEST /RU $RunAsUser /RP $RunAsPassword /F | Out-Host

  Write-Step "Scheduled task created. It will run WSL installs as the user in ~15 minutes."
}

try {
  Ensure-Chocolatey
  choco feature enable -n allowGlobalConfirmation | Out-Host

  Write-Step "Starting tool installations..."

  # Enable WSL features early (no reboot yet)
  Enable-WslFeaturesIfNeeded

  # Original tools
  if ($VsCode) { Install-ChocoPackage "vscode" }
  if ($AzCli)  { Install-ChocoPackage "azure-cli" }
  if ($DotNet) { Install-ChocoPackage "dotnet-sdk" }
  if ($NodeJs) { Install-ChocoPackage "nodejs-lts" }

  # DevOps workshop essentials
  if ($Git)       { Install-ChocoPackage "git" }
  if ($Python)    { Install-ChocoPackage "python" }
  if ($Terraform) { Install-ChocoPackage "terraform" }
  if ($Kubectl)   { Install-ChocoPackage "kubernetes-cli" }
  if ($Helm)      { Install-ChocoPackage "kubernetes-helm" }
  if ($Jq)        { Install-ChocoPackage "jq" }
  if ($Yq)        { Install-ChocoPackage "yq" }
  if ($Make)      { Install-ChocoPackage "make" }
  if ($Bicep)     { Install-ChocoPackage "bicep" }

  # Docker options
  if ($DockerDesktop) {
    Install-ChocoPackage "docker-desktop"
    $NeedsRestart = $true
    Ensure-DockerDesktopService
  }
  if ($DockerEngine)  { Install-ChocoPackage "docker-engine" }

  # Minikube on Windows: install binary, but DO NOT start (docker driver unsupported on windows/amd64)
  if ($Minikube) {
    Install-ChocoPackage "minikube"
    Write-Step "Minikube installed on Windows. It will be started inside WSL by the scheduled task."
  }

  # Create scheduled task at the end (enough time for reboot)
  if ($NeedsWslTools) {
    Register-WslToolingScheduledTask
    $NeedsRestart = $true  # WSL feature enable typically requires restart anyway
  }

  # Mark phase 1 done
  New-Item -ItemType File -Path $Phase1Marker -Force | Out-Null

  Write-Step "All done."

  if ($NeedsRestart) {
    Write-Step "Restart required. Restarting now (after all tools installed)..."
    Restart-Computer -Force
  }
}
catch {
  Write-Error "Installation failed: $($_.Exception.Message)"
  throw
}
finally {
  Stop-Transcript
}
