param(
  [bool]$VsCode = $false,
  [bool]$AzCli  = $false,
  [bool]$DotNet = $false,
  [bool]$NodeJs = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$logDir = 'C:\Windows\Temp'
$logFile = Join-Path $logDir 'toolinstall.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path $logFile -Append

try {
  Write-Output "Downloading Chocolatey installer..."
  $chocoScript = Join-Path $logDir 'install-choco.ps1'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $chocoScript

  Write-Output "Installing Chocolatey..."
  powershell -NoProfile -ExecutionPolicy Bypass -File $chocoScript

  if (-not (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe')) {
    throw "Chocolatey installation failed (choco.exe not found)"
  }

  $env:Path += ';C:\ProgramData\chocolatey\bin'
  choco feature enable -n allowGlobalConfirmation | Out-Host

  if ($VsCode) { choco install vscode -y | Out-Host }
  if ($AzCli)  { choco install azure-cli -y | Out-Host }
  if ($DotNet) { choco install dotnet-sdk -y | Out-Host }
  if ($NodeJs) { choco install nodejs-lts -y | Out-Host }

  Write-Output "All done."
}
finally {
  Stop-Transcript
}
