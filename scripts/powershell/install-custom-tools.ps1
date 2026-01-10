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

# -----------------------------
# State + reliable logging
# -----------------------------
$StateDir   = "C:\ProgramData\DevOpsSetup"
$LogsDir    = Join-Path $StateDir "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

$LogFile    = Join-Path $LogsDir "install-custom-tools.log"
$WslTaskLog = Join-Path $LogsDir "run-wsl-tools.log"

function Write-Step($msg) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[$ts] $msg"
  Write-Output $line
  $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

try { Start-Transcript -Path (Join-Path $LogsDir "transcript.log") -Append -ErrorAction SilentlyContinue | Out-Null } catch {}

Write-Step "=== install-custom-tools.ps1 started ==="
Write-Step "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Step "Args: VsCode=$VsCode AzCli=$AzCli DotNet=$DotNet NodeJs=$NodeJs DockerDesktop=$DockerDesktop DockerEngine=$DockerEngine Terraform=$Terraform Kubectl=$Kubectl Helm=$Helm Minikube=$Minikube"

$Phase1Marker = Join-Path $StateDir "phase1.done"

$WslTaskName   = "DevOps-WSL-Tooling"
$WslTaskScript = Join-Path $StateDir "run-wsl-tools.ps1"

$NeedsWslTools = ($Kubectl -or $Helm -or $Minikube)
$NeedsRestart  = $false

Write-Step "Needs WSL tools? $NeedsWslTools"

# -----------------------------
# Chocolatey helpers
# -----------------------------
function Ensure-Chocolatey {
  if (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe') {
    $env:Path += ';C:\ProgramData\chocolatey\bin'
    Write-Step "Chocolatey already installed."
    return
  }

  Write-Step "Downloading Chocolatey installer..."
  $tmp = "C:\Windows\Temp"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $chocoScript = Join-Path $tmp 'install-choco.ps1'
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

# -----------------------------
# WSL feature enable (best-effort)
# -----------------------------
function Enable-WslFeaturesIfNeeded {
  if (-not $NeedsWslTools) { return }

  Write-Step "Ensuring WSL + VirtualMachinePlatform features are enabled (needed for WSL2)..."

  $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
  $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

  if ($null -eq $wsl -or $null -eq $vmp) {
    Write-Step "Could not query Windows optional features. Skipping WSL feature enable."
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
    Write-Step "Setting WSL2 as default version (best-effort)..."
    wsl --set-default-version 2 | Out-Host
  } catch {
    Write-Step "WSL default version could not be set yet (often requires reboot)."
    $script:NeedsRestart = $true
  }
}

function Note-DockerDesktopInstalled {
  Write-Step "Docker Desktop installed. Skipping docker daemon validation during extension run."
  $script:NeedsRestart = $true
}

# -----------------------------
# Scheduled Task creation for WSL tooling (runs as USER)
# Uses Solution B: --no-launch + root useradd/passwd + run tool installer as Linux user
# -----------------------------
function Register-WslToolingScheduledTask {
  if (-not $NeedsWslTools) { return }

  if ([string]::IsNullOrWhiteSpace($RunAsUser) -or [string]::IsNullOrWhiteSpace($RunAsPassword)) {
    Write-Step "WSL tooling requested, but RunAsUser/RunAsPassword not provided. Skipping scheduled task creation."
    return
  }

  # Linux username: use the trailing part of DOMAIN\user if present
  $linuxUser = $RunAsUser
  if ($linuxUser -match "\\") { $linuxUser = $linuxUser.Split("\")[-1] }

  $distroName = "Ubuntu"
  $wslBashPathWin = Join-Path $StateDir "wsl-tools.sh"

  Write-Step "Writing WSL bash installer to: $wslBashPathWin"
  Write-Step "Writing scheduled-task PS script to: $WslTaskScript"
  Write-Step "WSL distro: $distroName | Linux user: $linuxUser"

  # 1) Bash installer (runs inside WSL)
  $bashContent = @'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Ubuntu WSL tooling started: $(date -Is) ==="

sudo apt-get update -y

# docker.io (Ubuntu)
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get install -y docker.io
fi

# ensure docker service (WSL may not run systemd; non-fatal)
sudo service docker start >/dev/null 2>&1 || true

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y kubectl
fi

# helm v4.0.4 (binary)
if ! command -v helm >/dev/null 2>&1; then
  TMPDIR="$(mktemp -d)"
  curl -fsSL -o "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" https://get.helm.sh/helm-v4.0.4-linux-amd64.tar.gz
  tar -zxf "${TMPDIR}/helm-v4.0.4-linux-amd64.tar.gz" -C "${TMPDIR}"
  sudo mv "${TMPDIR}/linux-amd64/helm" /usr/local/bin/helm
  sudo chmod +x /usr/local/bin/helm
  rm -rf "${TMPDIR}"
fi

# minikube (binary)
if ! command -v minikube >/dev/null 2>&1; then
  sudo curl -fsSL -o /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo chmod +x /usr/local/bin/minikube
fi

echo "Tools installed:"
docker --version || true
kubectl version --client --short 2>/dev/null || true
helm version --short 2>/dev/null || true
minikube version || true

# Start minikube using docker driver (non-fatal)
minikube delete || true
minikube start --driver=docker || true
minikube status || true

echo "=== Ubuntu WSL tooling completed: $(date -Is) ==="
'@
  $bashContent | Set-Content -Path $wslBashPathWin -Encoding utf8

  # 2) Scheduled task PS script (runs as the USER)
  $psTaskContent = @"
`$ErrorActionPreference = 'Continue'
`$ProgressPreference = 'SilentlyContinue'

New-Item -ItemType Directory -Force -Path `"$LogsDir`" | Out-Null
"=== WSL scheduled task started: `$(Get-Date -Format o) ===" | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
"Running as: `$(whoami)" | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

`$distro = "$distroName"
`$linuxUser = "$linuxUser"
`$linuxPass = "$RunAsPassword"

"Installing distro '`$distro' (no-launch)..." | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
wsl --install `$distro --no-launch 2>&1 | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

# Wait/retry until distro appears
`$maxWait = 120
`$found = `$false
for (`$i=0; `$i -lt `$maxWait; `$i += 5) {
  Start-Sleep -Seconds 5
  `$distros = (wsl -l -q) 2>`$null
  if (`$distros -and (`$distros | Select-String -SimpleMatch `$distro)) {
    `$found = `$true
    break
  }
}

if (-not `$found) {
  "Distro '`$distro' still not detected after wait. Exiting." | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
  exit 0
}

"Launching distro once to initialize..." | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
wsl.exe -d `$distro -- echo "WSL init ok" 2>&1 | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

# Create user if missing
"Ensuring Linux user '`$linuxUser' exists..." | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
wsl.exe -d `$distro -u root -- bash -lc "id -u '`$linuxUser' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm '`$linuxUser'" 2>&1 |
  Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

# Set password (best-effort)
wsl.exe -d `$distro -u root -- bash -lc "printf '%s\n%s\n' '`$linuxPass' '`$linuxPass' | passwd '`$linuxUser'" 2>&1 |
  Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

# Set default user via /etc/wsl.conf
wsl.exe -d `$distro -u root -- bash -lc "cat > /etc/wsl.conf <<'EOF'
[user]
default=`$linuxUser
EOF" 2>&1 | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

# Convert bash file to LF endings
`$bashWin = `"$wslBashPathWin`"
`$bashText = Get-Content -Raw -Path `$bashWin
`$bashText = `$bashText -replace "`r`n", "`n"
Set-Content -Path `$bashWin -Value `$bashText -Encoding utf8

# Execute installer as the Linux user
`$bashWsl = "/mnt/c/ProgramData/DevOpsSetup/wsl-tools.sh"
"Executing WSL bash installer as '`$linuxUser': `$bashWsl" | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

wsl.exe -d `$distro -u `$linuxUser -- bash -lc "chmod +x `$bashWsl && `$bashWsl" 2>&1 |
  Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8

"=== WSL scheduled task completed: `$(Get-Date -Format o) ===" | Out-File -FilePath `"$WslTaskLog`" -Append -Encoding utf8
"@

  $psTaskContent | Set-Content -Path $WslTaskScript -Encoding utf8

  # 3) Create the scheduled task (15 mins)
  $startTime = (Get-Date).AddMinutes(15).ToString("HH:mm")
  $psExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

  Write-Step "Creating scheduled task '$WslTaskName' to run at $startTime as user '$RunAsUser'..."

  try { schtasks /Delete /TN $WslTaskName /F 2>$null | Out-Null } catch {}

  $taskCmd = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$WslTaskScript`""
  Write-Step "schtasks /TR will be: $taskCmd"

  $out = schtasks /Create /TN $WslTaskName `
    /TR $taskCmd `
    /SC ONCE /ST $startTime /RL HIGHEST /RU $RunAsUser /RP $RunAsPassword /F 2>&1

  $out | ForEach-Object { Write-Step "schtasks: $_" }
  Write-Step "Scheduled task created. It will run WSL installs as the user in ~15 minutes."
}

# -----------------------------
# Main
# -----------------------------
try {
  Ensure-Chocolatey
  choco feature enable -n allowGlobalConfirmation | Out-Host
  Write-Step "Starting tool installations..."

  Enable-WslFeaturesIfNeeded

  # Tools
  if ($VsCode) { Install-ChocoPackage "vscode" }
  if ($AzCli)  { Install-ChocoPackage "azure-cli" }
  if ($DotNet) { Install-ChocoPackage "dotnet-sdk" }
  if ($NodeJs) { Install-ChocoPackage "nodejs-lts" }

  if ($Git)       { Install-ChocoPackage "git" }
  if ($Python)    { Install-ChocoPackage "python" }
  if ($Terraform) { Install-ChocoPackage "terraform" }
  if ($Kubectl)   { Install-ChocoPackage "kubernetes-cli" }
  if ($Helm)      { Install-ChocoPackage "kubernetes-helm" }
  if ($Jq)        { Install-ChocoPackage "jq" }
  if ($Yq)        { Install-ChocoPackage "yq" }
  if ($Make)      { Install-ChocoPackage "make" }
  if ($Bicep)     { Install-ChocoPackage "bicep" }

  # Docker
  if ($DockerDesktop) {
    Install-ChocoPackage "docker-desktop"
    Note-DockerDesktopInstalled
  }
  if ($DockerEngine) {
    Install-ChocoPackage "docker-engine"
    $NeedsRestart = $true
  }

  # Minikube on Windows: install only (starting happens in WSL task)
  if ($Minikube) {
    Install-ChocoPackage "minikube"
    Write-Step "Minikube installed on Windows. It will be started inside WSL by the scheduled task."
  }

  if ($NeedsWslTools) {
    Register-WslToolingScheduledTask
    $NeedsRestart = $true
  }

  New-Item -ItemType File -Path $Phase1Marker -Force | Out-Null
  Write-Step "All done."

  if ($NeedsRestart) {
    Write-Step "Restart required. Restarting now (after all tools installed)..."
    Restart-Computer -Force
  }
}
catch {
  Write-Step "FATAL: Installation failed: $($_.Exception.Message)"
  throw
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}
