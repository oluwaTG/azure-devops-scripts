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
  [switch]$Minikube
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

# We only need WSL if we want Minikube in WSL (and kubectl/helm there)
# You said you want kubectl/helm/minikube INSIDE WSL.
$NeedsWslTools = ($Kubectl -or $Helm -or $Minikube)

# Track whether we need a reboot at the end of Phase 1
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

  # Ensure Ubuntu is installed (may complete after reboot)
  try {
    Write-Step "Ensuring Ubuntu distro is installed..."
    wsl --install -d Ubuntu | Out-Host
    $script:NeedsRestart = $true
  } catch {
    # On some builds this returns non-zero if already installed; ignore.
  }
}

function Ensure-DockerDesktopService {
  # Docker Desktop service name
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

  # Validate docker daemon connectivity (may still require WSL init)
  try {
    docker version | Out-Host
  } catch {
    Write-Warning "Docker daemon not reachable yet. Likely needs reboot / WSL initialization."
    $script:NeedsRestart = $true
  }
}

function Install-WslTools-Phase2 {
  if (-not $NeedsWslTools) { return }

  Write-Step "PHASE 2: Installing kubectl/helm/minikube inside WSL (Ubuntu)..."

  # Install inside WSL using a single bash script (heredoc) to keep it self-contained.
  # Uses Helm v4.0.4 binary release as you requested.
  $bash = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== WSL tools install started: $(date -Is) ==="
sudo apt-get update -y

# kubectl (stable repo method)
if ! command -v kubectl >/dev/null 2>&1; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y kubectl
else
  echo "kubectl already installed"
fi

# helm (binary release)
if ! command -v helm >/dev/null 2>&1; then
  TMPDIR="$(mktemp -d)"
  curl -fsSL -o "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" https://get.helm.sh/helm-v4.0.4-linux-amd64.tar.gz
  tar -zxvf "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" -C "${TMPDIR}" >/dev/null
  sudo mv "${TMPDIR}/linux-amd64/helm" /usr/local/bin/helm
  sudo chmod +x /usr/local/bin/helm
  rm -rf "${TMPDIR}"
  helm version --short || true
else
  echo "helm already installed"
fi

# minikube (binary)
if ! command -v minikube >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo chmod +x /usr/local/bin/minikube
else
  echo "minikube already installed"
fi

# Start minikube (docker driver) if requested
echo "Starting minikube (docker driver) ..."
minikube delete || true
minikube start --driver=docker || true
minikube status || true

echo "=== WSL tools install completed: $(date -Is) ==="
'@

  # Run the script inside Ubuntu. `bash -lc` ensures PATH is correct.
  try {
    wsl -d Ubuntu -- bash -lc $bash | Out-Host
  } catch {
    Write-Warning "WSL tool installation failed (non-fatal). WSL/Docker may still be initializing."
  }
}

try {
  # -----------------------------
  # Phase 2: after reboot
  # -----------------------------
  if (Test-Path $Phase1Marker -and -not (Test-Path $Phase2Marker)) {
    Install-WslTools-Phase2
    New-Item -ItemType File -Path $Phase2Marker -Force | Out-Null
    Write-Step "PHASE 2 complete."
    Write-Step "All done."
    return
  }

  # -----------------------------
  # Phase 1: normal windows installs
  # -----------------------------
  Ensure-Chocolatey
  choco feature enable -n allowGlobalConfirmation | Out-Host

  Write-Step "Starting tool installations..."

  # Enable WSL features early (no reboot yet) so Docker Desktop can install cleanly
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

  # Azure IaC tooling
  if ($Bicep)     { Install-ChocoPackage "bicep" }

  # Docker options
  if ($DockerDesktop) {
    Install-ChocoPackage "docker-desktop"
    $NeedsRestart = $true
    Ensure-DockerDesktopService
  }
  if ($DockerEngine) {
    Install-ChocoPackage "docker-engine"
  }

  # IMPORTANT CHANGE:
  # Do NOT start Minikube on Windows with docker driver (unsupported on windows/amd64).
  # We'll start Minikube in WSL during Phase 2.
  if ($Minikube) {
    Install-ChocoPackage "minikube"
    Write-Step "Minikube installed on Windows. It will be started inside WSL after reboot (Phase 2)."
    $NeedsRestart = $true
  }

  # Mark Phase 1 complete before reboot so we can continue with Phase 2
  New-Item -ItemType File -Path $Phase1Marker -Force | Out-Null

  Write-Step "All done."

  if ($NeedsRestart) {
    Write-Step "Restart required. Restarting now (after all tools installed)..."
    Restart-Computer -Force
  } else {
    # If no restart needed, we can immediately run Phase 2 in the same session (rare).
    if ($NeedsWslTools -and -not (Test-Path $Phase2Marker)) {
      Install-WslTools-Phase2
      New-Item -ItemType File -Path $Phase2Marker -Force | Out-Null
      Write-Step "PHASE 2 complete."
    }
  }
}
catch {
  Write-Error "Installation failed: $($_.Exception.Message)"
  throw
}
finally {
  Stop-Transcript
}
