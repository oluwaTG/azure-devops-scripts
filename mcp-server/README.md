# MCP Server

A lightweight .NET 10 minimal API that exposes read-only Kubernetes cluster context over HTTP.  
Designed to run in-cluster and serve as the data layer for the MCP RAG Chatbot.

---

## Features

- **Live cluster data** — namespaces, pods, events, logs, node & pod metrics
- **Homepage dashboard** at `/` — ArgoCD-inspired UI with live node/namespace/pod counts
- **Auto-reconnect** — automatically recreates the Kubernetes client on SSL/connection drops
- **Troubleshoot endpoint** — aggregates pods, events and logs for a service in one call
- **In-cluster & local** — uses in-cluster config when deployed, falls back to `~/.kube/config` locally

---

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Homepage dashboard (live cluster summary) |
| GET | `/health` | Health check |
| GET | `/cluster/info` | Cluster version, node count, node ready status |
| GET | `/namespaces` | List all namespaces |
| **Pods** ||||
| GET | `/namespaces/{ns}/pods` | List pods with phase/restarts |
| GET | `/namespaces/{ns}/pods/{pod}/events` | Events for a pod |
| GET | `/namespaces/{ns}/pods/{pod}/logs?tail=200` | Last N log lines |
| **Metrics** ||||
| GET | `/metrics/nodes` | Node CPU/memory capacity & allocatable |
| GET | `/metrics/pods` | Per-container CPU/memory requests & limits |
| **Deployments** ||||
| GET | `/namespaces/{ns}/deployments` | List deployments with replica status |
| GET | `/namespaces/{ns}/deployments/{name}` | Full deployment config |
| **Services** ||||
| GET | `/namespaces/{ns}/services` | List services with type/ports |
| GET | `/namespaces/{ns}/services/{name}` | Full service config |
| **Ingresses** ||||
| GET | `/namespaces/{ns}/ingresses` | List ingresses with rules/TLS |
| GET | `/namespaces/{ns}/ingresses/{name}` | Full ingress config |
| **ConfigMaps** ||||
| GET | `/namespaces/{ns}/configmaps` | List configmaps (keys only) |
| GET | `/namespaces/{ns}/configmaps/{name}` | Full configmap with data |
| **Secrets** ||||
| GET | `/namespaces/{ns}/secrets` | List secrets (keys only, values redacted) |
| **RBAC** ||||
| GET | `/namespaces/{ns}/roles` | Namespaced roles with rules |
| GET | `/namespaces/{ns}/rolebindings` | Namespaced role bindings |
| GET | `/clusterroles` | Cluster-wide roles (system roles excluded) |
| GET | `/clusterrolebindings` | Cluster-wide role bindings |
| **Workloads** ||||
| GET | `/namespaces/{ns}/statefulsets` | StatefulSets with replica status |
| GET | `/namespaces/{ns}/daemonsets` | DaemonSets with scheduling status |
| **Storage** ||||
| GET | `/namespaces/{ns}/persistentvolumeclaims` | PVCs with status/capacity |
| GET | `/persistentvolumes` | Cluster-wide PVs |
| **Service Accounts** ||||
| GET | `/namespaces/{ns}/serviceaccounts` | Service accounts |
| **Troubleshoot** ||||
| GET | `/troubleshoot/service/{ns}/{name}` | Aggregated pods + events + logs for a service |

---

## Quick Local Run

1. Install [.NET 10 SDK](https://dotnet.microsoft.com/download)
2. Restore & run:
   ```bash
   dotnet restore
   dotnet run
   ```
The service reads `~/.kube/config` when running locally, and uses in-cluster credentials when deployed.

---

## Build & Push

```bash
docker build -t your-registry/mcp-server:latest .
docker push your-registry/mcp-server:latest
```

---

## Deploy to Kubernetes

```bash
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/deployment.yaml
```

---

## Security Notes

- The provided `ClusterRole` is read-only. Tighten as needed for your environment.
- Add authentication (mTLS, JWT, or token) and network policies before exposing externally.
- Sanitize/redact logs and secrets before sending any data to external LLM APIs.

---

## Roadmap

- [ ] Authentication (token / mTLS)
- [ ] Multi-cluster support
- [ ] Deployments, Services, Ingress, ConfigMap endpoints
- [ ] Cluster-wide health summary endpoint (`/summary`)
- [ ] Rate limiting & response caching
