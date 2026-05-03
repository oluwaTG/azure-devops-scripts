# MCP Server

A lightweight .NET 10 minimal API that exposes read-only Kubernetes cluster context over HTTP.  
Designed to run in-cluster and serve as the data layer for the MCP RAG Chatbot.

---

## Features

- **Live cluster data** — 40+ endpoints covering every major Kubernetes resource type
- **Full SPA dashboard** at `/` — sidebar navigation, namespace switcher, resource tables, log viewer
- **Multi-container log support** — view logs per container or all containers merged in one call
- **Auto-reconnect** — recreates the Kubernetes client automatically on SSL/connection drops
- **Troubleshoot endpoint** — aggregates pods, events and logs for a service in one call
- **In-cluster & local** — uses in-cluster config when deployed, falls back to `~/.kube/config` locally
- **Helm packaged** — distributed as a Helm chart with fully overridable `values.yaml`
- **ArgoCD managed** — GitOps deployment via ArgoCD Application manifests

---

## Quick Local Run

1. Install [.NET 10 SDK](https://dotnet.microsoft.com/download)
2. Restore and run:
   ```bash
   cd mcp-server
   dotnet restore
   dotnet run
   ```
3. Open `http://localhost:8080` in your browser.

The service reads `~/.kube/config` when running locally, and uses in-cluster credentials when deployed.

---

## Deploy with Helm

The chart is published in this repository under `helm/Application/mcp-server/`.  
Anyone with `kubectl` access to a cluster can install it directly — no ArgoCD required.

### Install

```bash
helm upgrade --install mcp-server \
  oci://raw.githubusercontent.com/oluwaTG/azure-devops-scripts/main/helm/Application/mcp-server \
  --namespace mcp-server \
  --create-namespace
```

Or clone the repo and install from the local path:

```bash
git clone https://github.com/oluwaTG/azure-devops-scripts.git
cd azure-devops-scripts

helm upgrade --install mcp-server helm/Application/mcp-server \
  --namespace mcp-server \
  --create-namespace
```

### Install with custom values

Override any value inline or with your own values file:

```bash
# Override the ingress hostname
helm upgrade --install mcp-server helm/Application/mcp-server \
  --namespace mcp-server \
  --create-namespace \
  --set ingress.hosts[0].host=mcp-server.yourdomain.com

# Or use a custom values file
helm upgrade --install mcp-server helm/Application/mcp-server \
  --namespace mcp-server \
  --create-namespace \
  --values my-values.yaml
```

### Uninstall

```bash
helm uninstall mcp-server --namespace mcp-server
```

### Key values to override

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `elumole22/mcp-server` | Container image registry and name |
| `image.tag` | `1.0.5` | Image tag — update on every release |
| `ingress.enabled` | `true` | Enable/disable the ingress |
| `ingress.hosts[0].host` | `mcp-server.local` | Hostname for the dashboard |
| `ingress.className` | `nginx` | Ingress class (change if using Traefik, etc.) |
| `serviceAccount.create` | `true` | Create a dedicated service account |
| `rbac.create` | `true` | Create the ClusterRole and ClusterRoleBinding |
| `resources.requests.memory` | `64Mi` | Pod memory request |
| `resources.limits.memory` | `256Mi` | Pod memory limit |

See `helm/Application/mcp-server/values.yaml` for the full list of options with comments.

---

## Dashboard

The SPA dashboard is served at `/` and includes:

- **Overview** — cluster version, node count, pod count, not-ready pods, deployment health
- **Nodes** — CPU/memory capacity and allocatable per node
- **Pods** — ready count (`2/2`), phase, restarts, per-container status tooltip, log viewer
- **Deployments / StatefulSets / DaemonSets** — replica status
- **Jobs / CronJobs** — status badge, succeeded/failed counts, schedule and last run times
- **Autoscalers (HPA)** — min–max range, current vs desired replicas, "At Max" warning
- **Services / Ingresses / Network Policies** — networking resources
- **ConfigMaps / Secrets** — keys listed, secret values are redacted
- **PVCs / Storage Classes** — storage resources with capacity and binding mode
- **Events** — namespace-wide Warning/Normal events sorted by last seen
- **Resource Quotas** — used vs hard limit per resource

### Log viewer

Click **Logs** on any pod row to open the slide-up log panel:
- **Container selector** — for multi-container pods, pick a specific container or view all merged
- **Tail selector** — last 100 / 250 / 500 / 1000 lines
- **Filter** — real-time text filter across log lines
- **Colour coding** — errors (red), warnings (amber), info (blue)
- **Wrap toggle** — enable/disable line wrapping

---

## Endpoints

### Core

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | SPA dashboard |
| GET | `/health` | Health probe — returns `{"status":"ok"}` |
| GET | `/cluster/info` | Cluster version, node count, node ready status |
| GET | `/namespaces` | List all namespaces |

### Nodes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/nodes` | All nodes — name, roles, OS, kubelet version, CPU/memory |
| GET | `/nodes/{name}` | Full node detail — labels, taints, conditions, addresses, capacity, allocatable |
| GET | `/metrics/nodes` | Node CPU/memory capacity and allocatable |

### Pods

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/pods` | List pods with ready count (`2/2`), phase, restarts, per-container status |
| GET | `/namespaces/{ns}/pods/{pod}/events` | Events scoped to a single pod |
| GET | `/namespaces/{ns}/pods/{pod}/logs?tail=200` | Default container logs (last N lines) |
| GET | `/namespaces/{ns}/pods/{pod}/logs/all?tail=200` | All containers' logs as `{ containerName: logText }` |
| GET | `/namespaces/{ns}/pods/{pod}/containers` | List containers with image, ports, resource requests/limits, live status |
| GET | `/namespaces/{ns}/pods/{pod}/containers/{container}/logs?tail=200` | Logs for a specific container by name |

### Metrics

| Method | Path | Description |
|--------|------|-------------|
| GET | `/metrics/nodes` | CPU/memory capacity and allocatable per node |
| GET | `/metrics/pods` | Per-container CPU/memory requests and limits (all namespaces) |

### Deployments

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/deployments` | List deployments with replica status |
| GET | `/namespaces/{ns}/deployments/{name}` | Full deployment spec and status |
| GET | `/namespaces/{ns}/replicasets` | ReplicaSets with owning deployment name and image |

### StatefulSets & DaemonSets

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/statefulsets` | StatefulSets with replica status |
| GET | `/namespaces/{ns}/daemonsets` | DaemonSets with desired/ready/available counts |

### Jobs & CronJobs

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/jobs` | Jobs with succeeded/failed/active counts and start time |
| GET | `/namespaces/{ns}/jobs/{name}` | Full job detail including conditions and selector |
| GET | `/namespaces/{ns}/cronjobs` | CronJobs with schedule, suspend status, last run times |
| GET | `/namespaces/{ns}/cronjobs/{name}` | Full CronJob detail including history limits and active jobs |

### Autoscaling

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/hpa` | HPAs with target, min/max replicas, current vs desired, conditions |

### Services & Networking

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/services` | List services with type and ports |
| GET | `/namespaces/{ns}/services/{name}` | Full service config |
| GET | `/namespaces/{ns}/ingresses` | List ingresses with hosts and TLS |
| GET | `/namespaces/{ns}/ingresses/{name}` | Full ingress config |
| GET | `/namespaces/{ns}/networkpolicies` | Network policies with policy types and rule counts |

### Config

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/configmaps` | List configmaps (key names only) |
| GET | `/namespaces/{ns}/configmaps/{name}` | Full configmap including data values |
| GET | `/namespaces/{ns}/secrets` | List secrets (key names only — values are always redacted) |

### Storage

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/persistentvolumeclaims` | PVCs with status, capacity, storage class |
| GET | `/persistentvolumes` | Cluster-wide PVs with capacity, claim ref, reclaim policy |
| GET | `/storageclasses` | Storage classes with provisioner, binding mode, default flag |

### RBAC

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/roles` | Namespaced roles with rules |
| GET | `/namespaces/{ns}/rolebindings` | Namespaced role bindings |
| GET | `/namespaces/{ns}/serviceaccounts` | Service accounts in a namespace |
| GET | `/clusterroles` | Cluster-wide roles (system roles excluded) |
| GET | `/clusterrolebindings` | Cluster-wide role bindings |

### Namespace Observability

| Method | Path | Description |
|--------|------|-------------|
| GET | `/namespaces/{ns}/events` | All namespace events sorted by last seen (Warning and Normal) |
| GET | `/namespaces/{ns}/resourcequotas` | Resource quotas with hard limits vs current usage |
| GET | `/namespaces/{ns}/limitranges` | LimitRanges with min/max/default per resource |

### Troubleshoot

| Method | Path | Description |
|--------|------|-------------|
| GET | `/troubleshoot/service/{ns}/{name}` | Aggregated pods + events + last 200 log lines for a service or deployment name |

---

## Security Notes

- The ClusterRole is **read-only**. No write, delete, or exec permissions are granted.
- Secret values are never returned — only key names are exposed.
- Add authentication (mTLS, JWT, or an ingress-level token) before exposing the service externally.
- Sanitize logs before forwarding to any external LLM API to avoid leaking sensitive data.

---

## Roadmap

- [ ] Authentication (token / mTLS)
- [ ] Multi-cluster support
- [ ] Rate limiting and response caching
- [ ] Cluster-wide health summary endpoint (`/summary`)
- [ ] WebSocket log streaming (real-time instead of tail)
