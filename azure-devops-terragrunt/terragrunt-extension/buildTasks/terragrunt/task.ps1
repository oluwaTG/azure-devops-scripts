param(
  [string]$command = 'apply',
  [string]$extraArgs = '',
  [string]$workingDirectory = ''
)

Write-Host "Terragrunt task running: $command $extraArgs"

$terragrunt = 'terragrunt'

# Try to find terragrunt
if (-not (Get-Command $terragrunt -ErrorAction SilentlyContinue)) {
  Write-Host "terragrunt not found in PATH"
} else {
  Write-Host "Using terragrunt from PATH"
}

$wd = if ($workingDirectory -and (Test-Path $workingDirectory)) { $workingDirectory } else { (Get-Location).Path }

$cmd = "$terragrunt $command $extraArgs"
Write-Host "Running: $cmd (cwd: $wd)"
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { throw "Terragrunt exited with code $LASTEXITCODE" }
