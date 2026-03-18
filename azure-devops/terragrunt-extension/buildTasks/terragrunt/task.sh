#!/usr/bin/env bash
set -euo pipefail

command="${1:-apply}"
extraArgs="${2:-}"
workingDirectory="${3:-}"
installFlag="${4:-false}"

echo "Terragrunt task running: $command $extraArgs (install=$installFlag)"

terragrunt_cmd="terragrunt"

if ! command -v terragrunt >/dev/null 2>&1; then
  if [ "${installFlag}" = "true" ]; then
    echo "Terragrunt not found. Attempting download..."
    platform=$(uname | tr '[:upper:]' '[:lower:]')
    dlurl=""
    case "$platform" in
      linux) dlurl="https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_linux_amd64" ;;
      darwin) dlurl="https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_darwin_amd64" ;;
      msys*|mingw*|cygwin*) dlurl="https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_windows_amd64.exe" ;;
      *) echo "Unsupported platform: $platform" ;;
    esac

    if [ -n "$dlurl" ]; then
      tools_dir="${AGENT_TOOLSDIRECTORY:-$HOME/.tools}"
      mkdir -p "$tools_dir"
      binpath="$tools_dir/terragrunt"
      echo "Downloading $dlurl to $binpath"
      curl -sL -o "$binpath" "$dlurl"
      chmod +x "$binpath" || true
      terragrunt_cmd="$binpath"
    else
      echo "Could not determine download URL; please ensure terragrunt is available on PATH."
    fi
  else
    echo "Terragrunt not found and install not requested. Exiting with failure."
    exit 1
  fi
fi

cwd="$workingDirectory"
if [ -z "$cwd" ]; then cwd="${BUILD_SOURCESDIRECTORY:-$(pwd)}"; fi

set -x
$terragrunt_cmd $command $extraArgs
res=$?
set +x

if [ $res -ne 0 ]; then
  echo "Terragrunt failed with exit code $res"
  exit $res
fi

echo "Terragrunt completed successfully"
