install-custom-tools.sh (Bash)

Purpose
-------
This is a small convenience installer for Linux (Ubuntu/Debian) systems that bootstraps common developer and DevOps tools. It was written to be used when provisioning VMs (for example from Terraform cloud-init or remote-exec), but you can run it interactively on any compatible Linux host.

What it does
------------
- Installs common prerequisites (curl, ca-certificates, gnupg, lsb-release).
- Installs requested tools via apt or binary releases (kubectl, helm, minikube, docker, terraform, nodejs, .NET, etc.).
- Attempts to seed Docker/minikube user membership and starts minikube as the specified user.
- Logs actions to `/var/log/devops-tools/install-tools.log` for later review.

Location
--------
The script lives at:

`./scripts/bash/install-custom-tools.sh`

How the script accepts options
------------------------------
The script uses positional arguments (strings "true"/"false") for feature switches. The arguments are (in order):

1. VS_CODE
2. AZ_CLI
3. DOTNET
4. NODEJS
5. GIT
6. PYTHON
7. TERRAFORM
8. KUBECTL
9. HELM
10. JQ
11. YQ
12. BICEP
13. MAKE
14. DOCKER
15. MINIKUBE
16. LOCAL_USER (username used when configuring/starting minikube)

Example invocation
------------------
Run the script as root or with sudo. Examples below assume you are in the `scripts/bash` folder.

Install only kubectl/helm/minikube for a user (example: `example-user`):

```bash
sudo ./install-custom-tools.sh false false false false false false false true true false false false false false true example-user
```

Install Docker, Terraform, Git and Node.js:

```bash
sudo ./install-custom-tools.sh false false false true true false true false false false false false false true false
```

Notes about the `LOCAL_USER` / minikube behavior
-----------------------------------------------
- The script will attempt to add the chosen user to the `docker` group and run `minikube start` as that user so minikube runs with the proper home directory and permissions.
- Provide the username as the 16th positional argument (see examples). If you don't specify a user, the script attempts to infer one from `SUDO_USER` or the current user.
- The script uses the `LOCAL_USER` positional argument (16th) to determine which user to add to the `docker` group and to run `minikube start`. If `LOCAL_USER` is not provided the script will attempt to infer the user from `SUDO_USER` or the current user.

Logs and run state
------------------
- Log directory: `/var/log/devops-tools`
- Main log: `/var/log/devops-tools/install-tools.log`
- The script prints progress to stdout and appends to the log file.

Requirements and assumptions
----------------------------
- Tested on Debian/Ubuntu-style distributions (uses apt and the associated repositories).
- Internet access is required to download packages and binaries.
- Run as root (sudo) to allow package installation and group membership changes.
- `minikube` installation and startup assume Docker is installed and the Docker daemon is available.

Troubleshooting
---------------
- If a tool fails to install, check `/var/log/devops-tools/install-tools.log` for errors.
- If `minikube` fails to start, verify that the specified `LOCAL_USER` exists, is in the `docker` group, and has a valid home directory. You may need to log out and back in (or use `newgrp docker`) for group changes to take effect.
- If helm or other binary installs fail, verify network access and check the temporary directory output printed to the log.

Re-running the script
---------------------
The script is generally idempotent for apt packages (it checks dpkg before installing). It is safe to re-run; already-installed packages will be skipped.

Want improvements?
------------------
If you want, I can:
- Add a short wrapper to accept named flags instead of positional args (safer for manual runs).
- Add more robust checks for distribution and package sources.

License
-------
Free to use and adapt; review before running in production environments.
