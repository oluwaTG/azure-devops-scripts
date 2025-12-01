# IIS App Pool Monitor

This PowerShell script monitors a list of IIS Application Pools and automatically starts any that are stopped.  
It is designed to prevent unexpected downtime in production environments where app pools occasionally stop.

---

## Features
- Checks multiple IIS App Pools from a config file
- Automatically starts stopped app pools
- Logs all actions and errors
- Easy to schedule using Task Scheduler

---

## Setup

1. Place `Monitor-AppPools.ps1` and `appPools.txt` in the same folder.
2. Edit `appPools.txt` to include the names of the app pools you want to monitor.
3. Adjust paths in the script if needed:
   - `$configPath` → path to `appPools.txt`
   - `$logPath` → path to log file

---

## Usage

Run manually for testing:

```powershell
.\Monitor-AppPools.ps1

Schedule in Task Scheduler to run at your preferred interval (e.g., every 5 minutes).

--- 

## Example log Output
2025-12-01 14:05:01 - App pool 'MyAppPool1' is running. No action needed.
2025-12-01 14:05:01 - App pool 'MyAppPool2' is stopped. Attempting to start...
2025-12-01 14:05:02 - App pool 'MyAppPool2' started successfully.

## Requirements
PowerShell 5.1+
IIS with WebAdministration module installed
Windows Server environment