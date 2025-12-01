# Monitor-AppPools.ps1
# Checks a list of IIS App Pools and starts any that are stopped.

Import-Module WebAdministration

# Path to config file
$configPath = "C:\AppPoolMonitor\appPools.txt"

# Path to Log output
$logPath = "C:\AppPoolMonitor\Monitor-AppPools.log"

# Function for logging
function Write-Log {
    param ([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logPath -Value "$timestamp - $Message"
}

# Check if config file exists
if (-Not (Test-Path $configPath)) {
    Write-Log "ERROR: Config file not found at $configPath"
    exit 1
}

# Read app pool names
$appPools = Get-Content $configPath | Where-Object { $_.Trim() -ne "" }

foreach ($pool in $appPools) {
    $poolTrimmed = $pool.Trim()

    # Check if pool exists
    $appPoolExists = (Get-WebAppPoolState -Name $poolTrimmed -ErrorAction SilentlyContinue)

    if (-not $appPoolExists) {
        Write-Log "WARNING: App pool '$poolTrimmed' does not exist."
        continue
    }

    # Check state
    $state = (Get-WebAppPoolState -Name $poolTrimmed).Value

    if ($state -eq "Stopped") {
        Write-Log "App pool '$poolTrimmed' is stopped. Attempting to start..."
        try {
            Start-WebAppPool -Name $poolTrimmed
            Write-Log "App pool '$poolTrimmed' started successfully."
        }
        catch {
            Write-Log "ERROR: Failed to start app pool '$poolTrimmed'. $_"
        }
    }
    else {
        Write-Log "App pool '$poolTrimmed' is running. No action needed."
    }
}
