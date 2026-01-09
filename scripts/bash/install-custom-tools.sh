#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/devops-tools"
LOG_FILE="${LOG_DIR}/install-tools.log"
mkdir -p "${LOG_DIR}"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== DevOps tools install started: $(date -Is) ==="

# Flags passed as "true"/"false" strings
VS_CODE="${1:-false}"
AZ_CLI="${2:-false}"
DOTNET="${3:-false}"
NODEJS="${4:-false}"
GIT="${5:-false}"
PYTHON="${6:-false}"
TERRAFORM="${7:-false}"
KUBECTL="${8:-false}"
HELM="${9:-false}"
JQ="${10:-false}"
YQ="${11:-false}"
BICEP="${12:-false}"
MAKE="${13:-false}"
DOCKER="${14:-false}"
MINIKUBE="${15:-false}"

as_bool () {
  [[ "${1}" == "true" ]]
}

apt_update () {
  sudo apt-get update -y
}

install_pkg () {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "Already installed: $pkg"
  else
    echo "Installing: $pkg"
    sudo apt-get install -y "$pkg"
  fi
}

ensure_prereqs () {
  apt_update
  install_pkg ca-certificates
  install_pkg curl
  install_pkg gnupg
  install_pkg lsb-release
}

install_vscode () {
  echo "Installing VS Code..."
  install_pkg wget
  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null

  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

  apt_update
  install_pkg code
}

install_azcli () {
  echo "Installing Azure CLI..."
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
}

install_dotnet () {
  echo "Installing .NET SDK..."
  # Uses Ubuntu packages (may vary by distro). If this fails, we can switch to Microsoft repo method.
  install_pkg dotnet-sdk-7.0
}

install_nodejs () {
  echo "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  install_pkg nodejs
}

install_git () {
  echo "Installing Git..."
  install_pkg git
}

install_python () {
  echo "Installing Python..."
  install_pkg python3
  install_pkg python3-pip
  install_pkg python3-venv
}

install_terraform () {
  echo "Installing Terraform..."
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/hashicorp.gpg > /dev/null

  echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

  apt_update
  install_pkg terraform
}

install_kubectl () {
  echo "Installing kubectl..."
  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

  apt_update
  install_pkg kubectl
}

install_helm () {
  echo "Installing Helm..."
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://baltocdn.com/helm/signing.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/helm.gpg > /dev/null

  echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
    | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list > /dev/null

  apt_update
  install_pkg helm
}

install_jq () {
  echo "Installing jq..."
  install_pkg jq
}

install_yq () {
  echo "Installing yq..."
  # Ubuntu has yq in repos, though versions vary.
  install_pkg yq
}

install_bicep () {
  echo "Installing Bicep..."
  # Microsoft provides a single binary; install to /usr/local/bin
  install_pkg unzip
  curl -fsSL -o /usr/local/bin/bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64
  sudo chmod +x /usr/local/bin/bicep
}

install_make () {
  echo "Installing make..."
  install_pkg make
}

install_docker () {
  echo "Installing Docker Engine..."
  ensure_prereqs
  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null

  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt_update
  install_pkg docker-ce
  install_pkg docker-ce-cli
  install_pkg containerd.io
  install_pkg docker-buildx-plugin
  install_pkg docker-compose-plugin

  # Add current user to docker group (takes effect next login)
  if id -nG "$USER" | grep -qw docker; then
    echo "User already in docker group: $USER"
  else
    sudo usermod -aG docker "$USER" || true
    echo "Added $USER to docker group (log out/in to take effect)."
  fi
}

install_minikube () {
  echo "Installing Minikube..."
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found. Minikube requires kubectl."
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Minikube requires Docker driver."
    return
  fi
  curl -fsSL -o /usr/local/bin/minikube \
    https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  chmod +x /usr/local/bin/minikube
  echo "Minikube installed."
  echo "Starting Minikube with Docker driver..."
  mi
}

# ---- Execution ----
ensure_prereqs

as_bool "$VS_CODE"   && install_vscode
as_bool "$AZ_CLI"    && install_azcli
as_bool "$DOTNET"    && install_dotnet
as_bool "$NODEJS"    && install_nodejs
as_bool "$GIT"       && install_git
as_bool "$PYTHON"    && install_python
as_bool "$TERRAFORM" && install_terraform
as_bool "$KUBECTL"   && install_kubectl
as_bool "$HELM"      && install_helm
as_bool "$JQ"        && install_jq
as_bool "$YQ"        && install_yq
as_bool "$BICEP"     && install_bicep
as_bool "$MAKE"      && install_make
as_bool "$DOCKER"    && install_docker
as_bool "$MINIKUBE"  && install_minikube

echo "=== DevOps tools install completed: $(date -Is) ==="
