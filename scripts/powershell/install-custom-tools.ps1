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

try {
  Ensure-Chocolatey
  choco feature enable -n allowGlobalConfirmation | Out-Host

  Write-Step "Starting tool installations..."

  # Original tools
  if ($VsCode) { Install-ChocoPackage "vscode" }
  if ($AzCli)  { Install-ChocoPackage "azure-cli" }
  if ($DotNet) { Install-ChocoPackage "dotnet-sdk" }
  if ($NodeJs) { Install-ChocoPackage "nodejs-lts" }

  # DevOps workshop essentials
  if ($Git)      { Install-ChocoPackage "git" }
  if ($Python)   { Install-ChocoPackage "python" }
  if ($Terraform){ Install-ChocoPackage "terraform" }
  if ($Kubectl)  { Install-ChocoPackage "kubernetes-cli" }
  if ($Helm)     { Install-ChocoPackage "kubernetes-helm" }
  if ($Jq)       { Install-ChocoPackage "jq" }
  if ($Yq)       { Install-ChocoPackage "yq" }
  if ($Make)     { Install-ChocoPackage "make" }

  # Azure IaC tooling
  if ($Bicep)    { Install-ChocoPackage "bicep" }

  # Docker options
  # NOTE: Docker Desktop is generally for Windows 10/11. On Windows Server prefer Docker Engine.
  if ($DockerDesktop) { Install-ChocoPackage "docker-desktop" }
  if ($DockerEngine)  { Install-ChocoPackage "docker-engine" }

  # Kubernetes
  if ($Minikube)  { Install-ChocoPackage "minikube" }
  Write-Step "All done."
}
catch {
  Write-Error "Installation failed: $($_.Exception.Message)"
  throw
}
finally {
  Stop-Transcript
}
