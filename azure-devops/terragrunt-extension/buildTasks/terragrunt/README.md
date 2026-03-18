Terragrunt Azure DevOps task

This Azure DevOps pipeline task runs Terragrunt commands on the agent. It supports:

- Optional auto-install of Terragrunt on the agent (Linux/macOS/Windows)
- Any Terragrunt subcommand (init, plan, apply, destroy, run-all, output, etc.)
- Passing arbitrary additional arguments
- Optional working directory

Usage
-----
Add the task to a pipeline (classic editor) or use a packaged extension in a YAML pipeline after installing the extension in your organization.

YAML example (after publishing the extension and installing it in your org):

steps:
- task: Terragrunt@0
  inputs:
    install: true
    command: 'plan'
    extraArgs: '-out=tfplan -no-color'
    workingDirectory: 'infra/prod'

Notes
-----
- Hosted agents may not have terragrunt preinstalled. Enable `install` to download a platform-specific binary to the agent tools directory.
- Be careful with secrets in extraArgs; prefer pipeline secure variables and environment variables.
- The task runs terragrunt non-interactively; provide `-auto-approve` where required (e.g., for apply/destroy).
