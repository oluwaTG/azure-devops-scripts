# CVE Repo Scan Script (`cve-repo-scan.ps1`)

This script scans **all Azure DevOps repos in one project** using OWASP Dependency-Check, then creates:
- Per-repo HTML + CSV vulnerability reports
- One merged CSV report for all repos

---

## What this script does

1. Logs into Azure DevOps with your PAT
2. Lists repos in your project
3. Clones each repo locally
4. Runs Dependency-Check against each repo
5. Saves reports per repo
6. Deletes local cloned repo
7. Merges all CSV reports into one master CSV

---

## Prerequisites

Install these first:

- **PowerShell** (Windows PowerShell 5.1 or PowerShell 7)
- **Java 17+** (required by OWASP Dependency-Check)
  - Verify:
    ```powershell
    java -version
    ```
- **Git** (for `git clone`)
- **Azure CLI** + Azure DevOps extension
  - Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli
  - Install extension:
    ```powershell
    az extension add --name azure-devops
    ```
- **OWASP Dependency-Check**
  - Download: https://github.com/dependency-check/DependencyCheck
  - Note the full path to `dependency-check.bat`
- **Azure DevOps PAT** (with repo read access)
- **NVD API Key** (recommended)
  - Get key: https://nvd.nist.gov/developers/request-an-api-key

---

## Configure the script

Open `cve-repo-scan.ps1` and update the **CONFIG** block:

- `$AZURE_ORG`
  - Example: `dev.azure.com/myorg`
- `$PROJECT`
  - Exact Azure DevOps project name
- `$ENCODED_PROJECT`
  - URL-encoded project name (example: `My%20Project`)
- `$sourcePATPlain`
  - Your Azure DevOps PAT
- `$NVD_API_KEY`
  - Your NVD API key
- `$cloneRoot`
  - Temporary clone folder (example: `C:\temp\azdo-sca`)
- `$reportsRoot`
  - Report output folder (example: `C:\temp\azdo-sca-reports`)
- `$DC_PATH`
  - Full path to `dependency-check.bat`
- `$DC_DATA`
  - Persistent data folder for Dependency-Check DB

> Tip: Keep `$DC_DATA` persistent so future scans are faster.

---

## Run the script

From the script folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\cve-repo-scan.ps1
```

---

## Output

The script creates:

- Per-repo reports:
  - `$reportsRoot\<repo-name>\<repo-name>.html`
  - `$reportsRoot\<repo-name>\<repo-name>.csv`
- Combined report:
  - `$reportsRoot\AllRepos_SCA_Report.csv`

---

## Notes / common issues

- **Dependency-Check path error**
  - If you see `Dependency-Check not found at ...`, fix `$DC_PATH`.

- **Azure DevOps login / repo list fails**
  - Check PAT validity, organization URL, and project name.

- **Project name has spaces**
  - Ensure `$ENCODED_PROJECT` is URL-encoded (for example `My%20Project`).

- **NVD data freshness**
  - Script currently runs with `--noupdate`.
  - If you want live DB updates, remove `--noupdate` from the Dependency-Check command.

- **Security warning**
  - PAT and API key are currently stored in plain text in the script.
  - For production use, move secrets to environment variables or Azure Key Vault.

---

## Quick checklist

- [ ] Azure CLI installed
- [ ] `azure-devops` extension installed
- [ ] Java 17+ installed (`java -version` works)
- [ ] Git installed
- [ ] Dependency-Check installed
- [ ] PAT set in script
- [ ] NVD API key set in script
- [ ] Paths updated (`$cloneRoot`, `$reportsRoot`, `$DC_PATH`, `$DC_DATA`)
- [ ] Script executed successfully
