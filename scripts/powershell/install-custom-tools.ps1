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
  # Only do this when Docker Desktop or Minikube is requested (client Windows scenario)
  if (-not ($DockerDesktop -or $Minikube)) { return }

  Write-Step "Ensuring WSL + VirtualMachinePlatform features are enabled (needed for Docker Desktop/WSL2)..."

  $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
  $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

  if ($null -eq $wsl -or $null -eq $vmp) {
    Write-Warning "Could not query Windows optional features (possibly Windows Server). Skipping WSL enable."
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

  # Try to set WSL2 default; may fail until after reboot—non-fatal
  try {
    Write-Step "Setting WSL2 as default version..."
    wsl --set-default-version 2 | Out-Host
  } catch {
    Write-Warning "Could not set WSL2 default yet (often requires reboot)."
    $script:NeedsRestart = $true
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

  # Validate docker daemon connectivity (may still require reboot/WSL init)
  try {
    docker version | Out-Host
  } catch {
    Write-Warning "Docker daemon not reachable yet. Likely needs reboot / WSL initialization."
    $script:NeedsRestart = $true
  }
}

try {
  Ensure-Chocolatey
  choco feature enable -n allowGlobalConfirmation | Out-Host

  Write-Step "Starting tool installations..."

  # Enable WSL features early (no reboot yet) so Docker Desktop install can complete cleanly
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
  # NOTE: Docker Desktop is for Windows 10/11. On Windows Server prefer Docker Engine.
  if ($DockerDesktop) {
    Install-ChocoPackage "docker-desktop"
    # Docker Desktop almost always requires reboot/first login to finish initializing WSL backend
    $NeedsRestart = $true
    Ensure-DockerDesktopService
  }

  if ($DockerEngine)  { Install-ChocoPackage "docker-engine" }

  # Kubernetes / Minikube
  if ($Minikube) {
    Install-ChocoPackage "minikube"

    Write-Step "Configuring Minikube to use Docker driver by default..."
    try { minikube config set driver docker | Out-Host } catch {}

    Write-Step "Starting Minikube with Docker driver..."
    try {
      if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warning "Docker CLI not found. Install Docker Desktop (Win10/11) or Docker Engine (Server) before starting Minikube."
      } else {
        # If docker daemon isn't ready, don't fail the whole extension
        docker info | Out-Null

        Write-Step "Deleting any existing Minikube cluster (avoid driver mismatch)..."
        minikube delete | Out-Host

        minikube start --driver=docker | Out-Host
      }
    }
    catch {
      Write-Warning "Minikube was installed but could not start yet. Likely needs reboot / Docker daemon readiness."
      $NeedsRestart = $true
    }
  }

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
