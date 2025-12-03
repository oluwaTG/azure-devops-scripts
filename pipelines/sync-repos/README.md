### Folder Sync Pipeline

This pipeline synchronizes selected folders from a source repository into one or more target repositories, commits the changes, and automatically creates a Pull Request (PR) for each target repo.

It is designed for environments where shared folders, policy fragments, or reusable components need to be propagated across multiple repositories in a controlled, automated way.

### 🚀 Features

- Syncs selected subfolders from a source repo to multiple target repos

- Automatically creates a feature branch in each target repo

- Commits only when there are actual changes

- Pushes updates and opens a Pull Request

- Enables auto-complete with squash merge and branch deletion

- Supports multiple folder selections and multiple target repos

- Fully parameterized

### 📁 Folder Structure

This pipeline is stored under:

/pipelines/sync-repos/sync-repos.yml

### 🧩 Parameters
## foldersToSync (object)

A list of folder names that should be synchronized from the source repository.

These correspond to physical folders and should be available in the source repo:

Example default:

foldersToSync:
  - Folder1
  - Folder2
  - Folder3

### targetRepos (object)

A list of Azure DevOps repo names where the selected folders should be synced.

Example default:

targetRepos:
  - Repo.One
  - Repo.Two
  - Repo.Three

### 🛠 How It Works

The pipeline loops through each repo in targetRepos.

It clones the target repository.

Creates a timestamped feature branch:

feature/sync_YYYYMMDD_HHMM


Copies the selected folders from the source repo into the target repo.

Detects changes:

- If no changes, PR creation is skipped.

- If changes exist, it commits and pushes.

- Automatically creates a PR to main.

Enables auto-complete with:

- squash merge

- delete source branch