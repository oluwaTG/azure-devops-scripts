# MCP Server Helm Chart

This Helm chart deploys the MCP Server, a .NET-based troubleshooting and cluster context API for Kubernetes.

## Features
- Exposes REST endpoints for cluster health, namespaces, pods, events, logs, and troubleshooting.
- Includes RBAC for read-only access to cluster resources.
- Deploys with Ingress, Service, and customizable values.

## Installation

1. Update the image repository and tag in `values.yaml`:
   ```yaml
   image:
     repository: <your-docker-repo>/mcp-server
     tag: <your-tag>
   ```
2. Install or upgrade the chart:
   ```sh
   helm upgrade --install mcp-server ./helm/Application/mcp-server -n mcp-server --create-namespace
   ```
3. Ensure Ingress is configured and accessible (see `values.yaml`).

## Endpoints

Assuming your Ingress is set to `http://mcp-server.local`:

### Health
- `GET /health`
  - Check if the API is running.
  - Example: `curl http://mcp-server.local/health`

### Cluster Info
- `GET /cluster/info`
  - Returns Kubernetes version, node count, and node status.

### Namespaces
- `GET /namespaces`
  - Lists all namespaces.

### Pods in a Namespace
- `GET /namespaces/{ns}/pods`
  - Lists pods in the namespace `{ns}`.
  - Example: `curl http://mcp-server.local/namespaces/dev/pods`

### Pod Events
- `GET /namespaces/{ns}/pods/{pod}/events`
  - Lists events for a pod.

### Pod Logs
- `GET /namespaces/{ns}/pods/{pod}/logs?tail=200`
  - Gets the last N lines of logs for a pod (default 200).

### Troubleshoot Service/Deployment
- `GET /troubleshoot/service/{ns}/{name}`
  - Aggregates pod info, events, and logs for a service or deployment.

## RBAC
This chart creates a ServiceAccount and ClusterRole with read-only permissions for safe cluster introspection.

## Customization
- Edit `values.yaml` to set image, resources, ingress, and more.
- Add secrets, configmaps, or environment variables as needed.

## Example Usage
```sh
curl http://mcp-server.local/health
curl http://mcp-server.local/namespaces/dev/pods
curl http://mcp-server.local/troubleshoot/service/dev/my-app
```

---

For more details, see the chart templates and values file.
