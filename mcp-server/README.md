# MCP Server (minimal)

Purpose
- Small .NET service exposing read-only Kubernetes cluster context (namespaces, pods, events, logs).
- Intended to run in-cluster (recommended) or locally for development.

Quick local run
1. Install .NET 8 SDK.
2. Restore & run:
   dotnet restore
   dotnet run

The service will use in-cluster credentials when running in Kubernetes, otherwise it reads ~/.kube/config.

Build & push
docker build -t your-registry/mcp-server:0.1.0 .
docker push your-registry/mcp-server:0.1.0

Deploy
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/deployment.yaml

Security notes
- The provided ClusterRole is read-only for common resources. Tighten as needed.
- Add authentication (mTLS or token) and network policies before exposing the server externally.
- Sanitize/redact logs and secrets before sending any data to external LLM APIs.

Next steps
- Add auth (token or mTLS), rate limits, caching and a redact-and-summarize troubleshoot endpoint that prepares safe context for an LLM.
