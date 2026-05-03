# --- MCP RAG Chatbot ---
import streamlit as st
import requests
import os
import json
import re
import yaml
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()

# ── Config ────────────────────────────────────────────────────────────────────
st.set_page_config(page_title="MCP RAG Chatbot", page_icon="🤖", layout="wide")
openai_api_key = os.getenv("OPENAI_API_KEY", "")
client = OpenAI(api_key=openai_api_key)
mcp_url = os.getenv("MCP_SERVER_URL", "http://mcp-server.local")

SYSTEM_PROMPT = """You are an expert Kubernetes assistant.
You MUST answer using ONLY the live cluster data provided in the [SECTION] blocks below.
Do NOT make up pod names, namespaces, or resource values.

The data is organised into labelled sections. Key sections you may receive:
- [PODS] / [PODS_BY_NAMESPACE]: running pods, their status, restarts, and containers
- [LOGS]: stdout/stderr from a specific container
- [EVENTS] / [NAMESPACE_EVENTS]: Kubernetes events (Warnings, OOMKills, back-offs, etc.)
- [DEPLOYMENTS] / [DEPLOYMENT]: deployment spec and status
- [STATEFULSETS], [DAEMONSETS], [REPLICASETS]: other workload types
- [JOBS], [JOB]: batch job details and completion status
- [CRONJOBS], [CRONJOB]: scheduled job definitions and last run status
- [HPA]: HorizontalPodAutoscaler current replicas vs desired
- [SERVICES], [SERVICE]: ClusterIP / NodePort / LoadBalancer config
- [INGRESSES], [INGRESS]: Ingress host/path routing rules
- [NETWORKPOLICIES]: ingress/egress firewall rules
- [CONFIGMAPS], [SECRETS]: configuration and secret key names
- [RESOURCEQUOTAS]: namespace-level CPU/memory/object quotas
- [LIMITRANGES]: default container resource limits
- [STORAGECLASSES]: available storage provisioners
- [NODES], [NODE_DETAIL]: node capacity, conditions, and taints
- [RBAC]: roles, role bindings, cluster roles, cluster role bindings
- [TROUBLESHOOT]: deep-dive service health report from the MCP server
- [AUTO_TROUBLESHOOT_SUMMARY]: synthesised troubleshooting report combining all signals

When asked about pods, always look at [PODS] or [PODS_BY_NAMESPACE] and list them explicitly.
When asked for logs but no pod is named, list pod names from [PODS] and ask the user to clarify.
When logs ARE provided in [LOGS] or [LOGS_*] sections, display them directly in a code block — do NOT suggest kubectl commands or tell the user to run commands themselves.
When asked to troubleshoot, synthesise ALL provided sections — events, logs, pod status, deployment state — into a root-cause analysis with recommended actions.
Never suggest running kubectl or any CLI command when the live data has already been fetched and is present in the sections below.
If a section is missing from the data, say so clearly rather than claiming data doesn't exist.
Format answers clearly using bullet points or tables where helpful."""

# ── Session state ─────────────────────────────────────────────────────────────
if "chat_history" not in st.session_state:
    st.session_state.chat_history = []   # full conversation for LLM memory
if "display_history" not in st.session_state:
    st.session_state.display_history = []  # (role, text, raw_data) for UI

# ── MCP helpers ───────────────────────────────────────────────────────────────
def mcp_get(path: str, text=False):
    """Fetch from MCP server; returns parsed JSON or raw text."""
    try:
        r = requests.get(f"{mcp_url}{path}", timeout=15)
        r.raise_for_status()
        return r.text if text else r.json()
    except Exception as e:
        return {"error": str(e)}

def get_all_namespaces() -> list[str]:
    """Fetch all namespaces from MCP, return as a list of strings."""
    result = mcp_get("/namespaces")
    if isinstance(result, list):
        return result
    return []

def extract_entities(question: str, known_namespaces: list[str] = None):
    """
    Extract namespace, pod, and service name from the question.
    Also matches against known namespace names fetched from the cluster.
    """
    ns = None
    pod = None
    service = None

    # English stopwords that should never be treated as k8s names
    stopwords = {
        "the", "a", "an", "my", "all", "any", "some", "this", "that",
        "pods", "pod", "logs", "log", "cluster", "namespace", "namespaces",
        "has", "have", "had", "been", "be", "is", "are", "was", "were",
        "in", "on", "at", "to", "for", "of", "and", "or", "not", "no",
        "its", "it", "if", "any", "from", "with", "check", "get", "list",
        "show", "what", "which", "how", "why", "when", "where", "who",
        "errors", "error", "issues", "issue", "running", "crashed", "down",
        "there", "their", "they", "then", "than", "last", "latest",
        "job", "jobs", "cronjob", "cronjobs", "node", "nodes", "hpa",
        "service", "services", "deployment", "deployments", "ingress",
        "fetch", "get", "show", "give", "display", "retrieve", "print",
    }

    # 1. Explicit "X namespace" or "namespace X" patterns (highest confidence)
    for pattern in [
        r"\bin\s+(?:the\s+)?([\w-]+)\s+namespace\b",   # "in the map-server-dev namespace"
        r"\bnamespace[s]?\s*[=:'\"]?\s*([\w-]+)",        # "namespace map-server-dev"
        r"\bns[=:\s]\s*([\w-]+)",                         # "ns=map-server-dev"
    ]:
        m = re.search(pattern, question, re.IGNORECASE)
        if m and m.group(1).lower() not in stopwords:
            ns = m.group(1)
            break

    # 2. Match tokens in the question against the live list of known namespace names.
    #    Only accept if the token is at least 4 chars (avoids common English words)
    #    OR contains a hyphen (clear signal it's a k8s name like "map-server-dev").
    if ns is None and known_namespaces:
        ns_lower = [n.lower() for n in known_namespaces]
        q_words = re.findall(r"[\w-]+", question.lower())
        for word in q_words:
            # Accept any token that is an actual known namespace name, regardless of length.
            # The stopwords list guards against false positives.
            if word in ns_lower and word not in stopwords:
                ns = word
                break

    # 3. Pod name: support both "pod <name>" and "<name> pod" orderings
    m = re.search(r"\bpod[s]?\s+([\w][\w-]*)", question, re.IGNORECASE)
    if m and m.group(1).lower() not in stopwords:
        pod = m.group(1)
    if pod is None:
        m = re.search(r"\b([\w][\w-]*)\s+pod\b", question, re.IGNORECASE)
        if m and m.group(1).lower() not in stopwords:
            pod = m.group(1)

    # 4. Container name: "container <name>", "<name> container", "-c <name>"
    container = None
    for pattern in [
        r"\bcontainer[s]?\s+([\w][\w-]*)",
        r"\b([\w][\w-]*)\s+container\b",
        r"\b-c\s+([\w][\w-]*)",
    ]:
        m = re.search(pattern, question, re.IGNORECASE)
        if m and m.group(1).lower() not in stopwords:
            container = m.group(1)
            break

    # 5. Deployment / service / app name — also catches job/cronjob/node targets
    for pattern in [
        r"\b(?:deployment|service|app|svc)\s+([\w-]+)",    # "app devops-helper"
        r"\b([\w-]+)\s+(?:app|service|svc|deployment)\b",  # "devops-helper app"
        r"\btroubleshoot\s+([\w-]+)",
        r"\bfor\s+([\w-]+)\s+(?:pod|service|deployment|app|job|cronjob)",
        r"\bfrom\s+(?:the\s+)?([\w-]+)\s+(?:app|service|svc|deployment)\b",  # "from the devops-helper app"
        r"\b(?:job|cronjob|node)\s+([\w-]+)",
        r"\b(?:debug|investigate|fix|what(?:'s| is) wrong with)\s+([\w-]+)",
    ]:
        m = re.search(pattern, question, re.IGNORECASE)
        if m and m.group(1).lower() not in stopwords:
            service = m.group(1)
            break

    return ns, pod, service, container

def classify_intent(question: str) -> list[str]:
    """Return a prioritised list of MCP data to fetch based on question keywords."""
    q = question.lower()
    calls = ["cluster"]  # always fetch cluster info

    if any(w in q for w in ["metric", "cpu", "memory", "resource", "limit", "request", "usage"]):
        calls.append("node_metrics")
        calls.append("pod_metrics")
    if any(w in q for w in ["namespace", "namespaces", " ns "]):
        calls.append("namespaces")
    if any(w in q for w in ["node", "nodes", "capacity", "taint", "condition", "schedulable"]):
        calls.append("nodes")
    if any(w in q for w in ["pod", "pods", "container", "running", "crash",
                             "restart", "restarts", "phase", "status", "ready",
                             "what is going on", "what's going on", "what's happening",
                             "what is happening", "going on", "happening", "overview", "health"]):
        calls.append("pods")
    if any(w in q for w in ["log", "logs", "error", "exception", "stdout", "stderr", "output"]):
        calls.append("logs")
    if any(w in q for w in ["event", "events", "warning", "oom", "kill", "backoff", "back-off",
                             "what is going on", "what's going on", "what's happening",
                             "what is happening", "going on", "happening", "status", "overview",
                             "health", "healthy", "unhealthy", "activity"]):
        calls.append("events")
    if any(w in q for w in ["troubleshoot", "debug", "broken", "down", "failing", "not working",
                             "investigate", "what's wrong", "what is wrong", "why is", "fix",
                             "unhealthy", "degraded", "crashing", "not responding", "unreachable"]):
        calls.append("troubleshoot")
    if any(w in q for w in ["deployment", "deployments", "deploy", "rollout",
                             "what is going on", "what's going on", "what's happening",
                             "what is happening", "going on", "happening", "overview", "health"]):
        calls.append("deployments")
    if any(w in q for w in ["replicaset", "replicasets", "replica set"]):
        calls.append("replicasets")
    if any(w in q for w in ["service", "services", "svc", "clusterip", "nodeport", "loadbalancer"]):
        calls.append("services")
    if any(w in q for w in ["ingress", "ingresses", "route", "host", "tls", "hostname"]):
        calls.append("ingresses")
    if any(w in q for w in ["networkpolicy", "networkpolicies", "network policy", "firewall", "egress", "ingress policy"]):
        calls.append("networkpolicies")
    if any(w in q for w in ["configmap", "configmaps", "config", "configuration"]):
        calls.append("configmaps")
    if any(w in q for w in ["secret", "secrets"]):
        calls.append("secrets")
    if any(w in q for w in ["role", "roles", "rolebinding", "rolebindings", "rbac",
                             "clusterrole", "clusterrolebinding", "permission", "permissions"]):
        calls.append("rbac")
    if any(w in q for w in ["serviceaccount", "serviceaccounts", "sa"]):
        calls.append("serviceaccounts")
    if any(w in q for w in ["statefulset", "statefulsets"]):
        calls.append("statefulsets")
    if any(w in q for w in ["daemonset", "daemonsets"]):
        calls.append("daemonsets")
    if any(w in q for w in ["job", "jobs", "batch"]):
        calls.append("jobs")
    if any(w in q for w in ["cronjob", "cronjobs", "cron", "scheduled"]):
        calls.append("cronjobs")
    if any(w in q for w in ["hpa", "autoscal", "horizontal", "scale", "scaling"]):
        calls.append("hpa")
    if any(w in q for w in ["resourcequota", "resourcequotas", "quota", "quotas", "limit range"]):
        calls.append("resourcequotas")
    if any(w in q for w in ["limitrange", "limitranges", "default limit", "default request"]):
        calls.append("limitranges")
    if any(w in q for w in ["storageclass", "storageclasses", "provisioner", "storage class"]):
        calls.append("storageclasses")
    if any(w in q for w in ["pvc", "pv", "persistentvolume", "persistentvolumeclaim",
                             "volume", "volumes"]):
        calls.append("volumes")

    return list(dict.fromkeys(calls))

def fetch_mcp_context(question: str) -> tuple[dict, list[str]]:
    """
    Smart retrieval:
    1. Always fetch namespaces first so we can match namespace names in the question.
    2. Extract entities (ns, pod, service) with cluster-aware matching.
    3. Call only the endpoints relevant to the question intent.
    4. Auto-troubleshoot mode: when triggered, fan out across events, logs, deployment state.
    """
    ctx: dict = {}
    endpoints_used: list[str] = []

    # Step 1: always get namespaces & cluster info upfront
    all_namespaces = get_all_namespaces()
    ctx["namespaces"] = all_namespaces
    endpoints_used.append("/namespaces")

    ctx["cluster_info"] = mcp_get("/cluster/info")
    endpoints_used.append("/cluster/info")

    # Step 2: extract entities with knowledge of real namespace names
    intents = classify_intent(question)
    ns, pod, service, container = extract_entities(question, known_namespaces=all_namespaces)

    needs_pods = any(i in intents for i in ["pods", "logs", "events", "troubleshoot"])

    # Step 3: node metrics (no namespace needed)
    if "node_metrics" in intents:
        ctx["node_metrics"] = mcp_get("/metrics/nodes")
        endpoints_used.append("/metrics/nodes")

    # Step 4: pod metrics
    if "pod_metrics" in intents:
        ctx["pod_metrics"] = mcp_get("/metrics/pods")
        endpoints_used.append("/metrics/pods")

    # Step 5: nodes
    if "nodes" in intents:
        ctx["nodes"] = mcp_get("/nodes")
        endpoints_used.append("/nodes")
        if service:  # "service" slot reused for node name when user says "node <name>"
            ctx["node_detail"] = mcp_get(f"/nodes/{service}")
            endpoints_used.append(f"/nodes/{service}")

    # Step 6: pod listing
    if needs_pods:
        if ns:
            ctx["pods"] = mcp_get(f"/namespaces/{ns}/pods")
            endpoints_used.append(f"/namespaces/{ns}/pods")
        else:
            all_pods = {}
            for n in all_namespaces:
                result = mcp_get(f"/namespaces/{n}/pods")
                if isinstance(result, list) and result:
                    all_pods[n] = result
            if all_pods:
                ctx["pods_by_namespace"] = all_pods
                endpoints_used.append("/namespaces/*/pods (all)")

    # Step 7: logs — container-specific if named, otherwise all-containers tail
    if "logs" in intents:
        if ns and pod:
            if container:
                # Per-container logs
                ctx["logs"] = mcp_get(
                    f"/namespaces/{ns}/pods/{pod}/containers/{container}/logs?tail=100",
                    text=True,
                )
                endpoints_used.append(
                    f"/namespaces/{ns}/pods/{pod}/containers/{container}/logs"
                )
            else:
                # All containers combined
                ctx["logs"] = mcp_get(
                    f"/namespaces/{ns}/pods/{pod}/logs?tail=100", text=True
                )
                endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/logs")
        elif ns and service:
            # No explicit pod name — find pods matching the app/service name and fetch their logs
            pods_data = ctx.get("pods", [])
            if not isinstance(pods_data, list) or not pods_data:
                pods_data = mcp_get(f"/namespaces/{ns}/pods")
                ctx["pods"] = pods_data
                endpoints_used.append(f"/namespaces/{ns}/pods")
            matching = [
                p for p in (pods_data if isinstance(pods_data, list) else [])
                if isinstance(p, dict) and service.lower() in p.get("name", "").lower()
            ]
            for p in matching[:2]:  # fetch logs for up to 2 matching pods
                pname = p.get("name", "")
                if pname:
                    log_path = (
                        f"/namespaces/{ns}/pods/{pname}/containers/{container}/logs?tail=150"
                        if container
                        else f"/namespaces/{ns}/pods/{pname}/logs?tail=150"
                    )
                    ctx[f"logs_{pname}"] = mcp_get(log_path, text=True)
                    endpoints_used.append(log_path.split("?")[0])
            if not matching:
                ctx["logs_note"] = (
                    f"No pods matching '{service}' found in namespace '{ns}'. "
                    "Check [PODS] for the exact pod name."
                )
        # If we have ns but no pod and no service, pods are already in [PODS].
        # The LLM will see [PODS] and ask the user to clarify which pod they mean.

    # Step 8: events — pod-level or namespace-level
    if "events" in intents:
        if ns and pod:
            ctx["events"] = mcp_get(f"/namespaces/{ns}/pods/{pod}/events")
            endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/events")
        elif ns:
            ctx["namespace_events"] = mcp_get(f"/namespaces/{ns}/events")
            endpoints_used.append(f"/namespaces/{ns}/events")

    # ── AUTO-TROUBLESHOOT ─────────────────────────────────────────────────────
    # When troubleshoot intent is detected, fan out to gather all diagnostic signals.
    if "troubleshoot" in intents:
        svc_name = service or pod
        if ns and svc_name:
            # 1. Dedicated troubleshoot endpoint
            ctx["troubleshoot"] = mcp_get(f"/troubleshoot/service/{ns}/{svc_name}")
            endpoints_used.append(f"/troubleshoot/service/{ns}/{svc_name}")

            # 2. Namespace-wide events (catches OOMKills, back-offs, scheduling failures)
            ctx["namespace_events"] = mcp_get(f"/namespaces/{ns}/events")
            endpoints_used.append(f"/namespaces/{ns}/events")

            # 3. Deployment state for the named service/app
            ctx["deployment"] = mcp_get(f"/namespaces/{ns}/deployments/{svc_name}")
            endpoints_used.append(f"/namespaces/{ns}/deployments/{svc_name}")

            # 4. Pod list so we can find crashed/pending pods
            if "pods" not in ctx:
                ctx["pods"] = mcp_get(f"/namespaces/{ns}/pods")
                endpoints_used.append(f"/namespaces/{ns}/pods")

            # 5. Fetch logs for any pod that isn't Running/Succeeded
            pods_data = ctx.get("pods", [])
            if isinstance(pods_data, list):
                unhealthy_pods = [
                    p for p in pods_data
                    if isinstance(p, dict)
                    and p.get("phase") not in ("Running", "Succeeded")
                    and svc_name.lower() in p.get("name", "").lower()
                ]
                # Also grab logs from the first matching running pod if no unhealthy ones
                if not unhealthy_pods:
                    unhealthy_pods = [
                        p for p in pods_data
                        if isinstance(p, dict) and svc_name.lower() in p.get("name", "").lower()
                    ][:1]
                for p in unhealthy_pods[:3]:  # cap at 3 pods to avoid context explosion
                    pname = p.get("name", "")
                    ctx[f"logs_{pname}"] = mcp_get(
                        f"/namespaces/{ns}/pods/{pname}/logs?tail=80", text=True
                    )
                    endpoints_used.append(f"/namespaces/{ns}/pods/{pname}/logs")

            # 6. HPA (are replicas being throttled or unable to scale?)
            ctx["hpa"] = mcp_get(f"/namespaces/{ns}/hpa")
            endpoints_used.append(f"/namespaces/{ns}/hpa")

            # 7. Resource quotas (could the namespace be out of quota?)
            ctx["resourcequotas"] = mcp_get(f"/namespaces/{ns}/resourcequotas")
            endpoints_used.append(f"/namespaces/{ns}/resourcequotas")

            ctx["auto_troubleshoot_summary"] = (
                f"Auto-troubleshoot for '{svc_name}' in namespace '{ns}'. "
                "Data gathered: troubleshoot report, namespace events, deployment state, "
                "pod logs (crashed/pending pods prioritised), HPA, resource quotas. "
                "Synthesise all sections into a root-cause analysis."
            )

        elif ns and not svc_name:
            # Namespace-level troubleshoot (e.g. "troubleshoot this pod" with no name,
            # or "what's wrong in the dev namespace"): events + pods + logs for unhealthy pods
            ctx["namespace_events"] = mcp_get(f"/namespaces/{ns}/events")
            endpoints_used.append(f"/namespaces/{ns}/events")
            if "pods" not in ctx:
                ctx["pods"] = mcp_get(f"/namespaces/{ns}/pods")
                endpoints_used.append(f"/namespaces/{ns}/pods")
            ctx["resourcequotas"] = mcp_get(f"/namespaces/{ns}/resourcequotas")
            endpoints_used.append(f"/namespaces/{ns}/resourcequotas")
            # If a specific pod was extracted (e.g. "troubleshoot pod my-app-xyz"), fetch its logs
            if pod:
                ctx[f"logs_{pod}"] = mcp_get(
                    f"/namespaces/{ns}/pods/{pod}/logs?tail=100", text=True
                )
                endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/logs")
                ctx["events"] = mcp_get(f"/namespaces/{ns}/pods/{pod}/events")
                endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/events")
            else:
                # No specific pod — grab logs for every unhealthy pod in the namespace
                pods_data = ctx.get("pods", [])
                if isinstance(pods_data, list):
                    unhealthy = [
                        p for p in pods_data
                        if isinstance(p, dict)
                        and p.get("phase") not in ("Running", "Succeeded")
                    ]
                    for p in unhealthy[:3]:
                        pname = p.get("name", "")
                        if pname:
                            ctx[f"logs_{pname}"] = mcp_get(
                                f"/namespaces/{ns}/pods/{pname}/logs?tail=80", text=True
                            )
                            endpoints_used.append(f"/namespaces/{ns}/pods/{pname}/logs")
        else:
            ctx["troubleshoot_note"] = (
                "Namespace not identified. Please specify a namespace (and optionally a service/app name) to troubleshoot."
            )

    # Step 9: deployments
    if "deployments" in intents:
        if ns and service:
            ctx["deployment"] = mcp_get(f"/namespaces/{ns}/deployments/{service}")
            endpoints_used.append(f"/namespaces/{ns}/deployments/{service}")
        elif ns:
            ctx["deployments"] = mcp_get(f"/namespaces/{ns}/deployments")
            endpoints_used.append(f"/namespaces/{ns}/deployments")
        else:
            dep_all = {}
            for n in all_namespaces:
                r = mcp_get(f"/namespaces/{n}/deployments")
                if isinstance(r, list) and r:
                    dep_all[n] = r
            if dep_all:
                ctx["deployments_by_namespace"] = dep_all
                endpoints_used.append("/namespaces/*/deployments (all)")

    # Step 10: replicasets
    if "replicasets" in intents and ns:
        ctx["replicasets"] = mcp_get(f"/namespaces/{ns}/replicasets")
        endpoints_used.append(f"/namespaces/{ns}/replicasets")

    # Step 11: services
    if "services" in intents:
        if ns and service:
            ctx["service"] = mcp_get(f"/namespaces/{ns}/services/{service}")
            endpoints_used.append(f"/namespaces/{ns}/services/{service}")
        elif ns:
            ctx["services"] = mcp_get(f"/namespaces/{ns}/services")
            endpoints_used.append(f"/namespaces/{ns}/services")
        else:
            svc_all = {}
            for n in all_namespaces:
                r = mcp_get(f"/namespaces/{n}/services")
                if isinstance(r, list) and r:
                    svc_all[n] = r
            if svc_all:
                ctx["services_by_namespace"] = svc_all
                endpoints_used.append("/namespaces/*/services (all)")

    # Step 12: ingresses
    if "ingresses" in intents:
        if ns and service:
            ctx["ingress"] = mcp_get(f"/namespaces/{ns}/ingresses/{service}")
            endpoints_used.append(f"/namespaces/{ns}/ingresses/{service}")
        elif ns:
            ctx["ingresses"] = mcp_get(f"/namespaces/{ns}/ingresses")
            endpoints_used.append(f"/namespaces/{ns}/ingresses")
        else:
            ing_all = {}
            for n in all_namespaces:
                r = mcp_get(f"/namespaces/{n}/ingresses")
                if isinstance(r, list) and r:
                    ing_all[n] = r
            if ing_all:
                ctx["ingresses_by_namespace"] = ing_all
                endpoints_used.append("/namespaces/*/ingresses (all)")

    # Step 13: network policies
    if "networkpolicies" in intents and ns:
        ctx["networkpolicies"] = mcp_get(f"/namespaces/{ns}/networkpolicies")
        endpoints_used.append(f"/namespaces/{ns}/networkpolicies")

    # Step 14: configmaps
    if "configmaps" in intents:
        if ns and service:
            ctx["configmap"] = mcp_get(f"/namespaces/{ns}/configmaps/{service}")
            endpoints_used.append(f"/namespaces/{ns}/configmaps/{service}")
        elif ns:
            ctx["configmaps"] = mcp_get(f"/namespaces/{ns}/configmaps")
            endpoints_used.append(f"/namespaces/{ns}/configmaps")

    # Step 15: secrets (keys only)
    if "secrets" in intents and ns:
        ctx["secrets"] = mcp_get(f"/namespaces/{ns}/secrets")
        endpoints_used.append(f"/namespaces/{ns}/secrets")

    # Step 16: RBAC
    if "rbac" in intents:
        ctx["clusterroles"] = mcp_get("/clusterroles")
        endpoints_used.append("/clusterroles")
        ctx["clusterrolebindings"] = mcp_get("/clusterrolebindings")
        endpoints_used.append("/clusterrolebindings")
        if ns:
            ctx["roles"] = mcp_get(f"/namespaces/{ns}/roles")
            endpoints_used.append(f"/namespaces/{ns}/roles")
            ctx["rolebindings"] = mcp_get(f"/namespaces/{ns}/rolebindings")
            endpoints_used.append(f"/namespaces/{ns}/rolebindings")

    # Step 17: service accounts
    if "serviceaccounts" in intents and ns:
        ctx["serviceaccounts"] = mcp_get(f"/namespaces/{ns}/serviceaccounts")
        endpoints_used.append(f"/namespaces/{ns}/serviceaccounts")

    # Step 18: statefulsets
    if "statefulsets" in intents and ns:
        ctx["statefulsets"] = mcp_get(f"/namespaces/{ns}/statefulsets")
        endpoints_used.append(f"/namespaces/{ns}/statefulsets")

    # Step 19: daemonsets
    if "daemonsets" in intents and ns:
        ctx["daemonsets"] = mcp_get(f"/namespaces/{ns}/daemonsets")
        endpoints_used.append(f"/namespaces/{ns}/daemonsets")

    # Step 20: jobs
    if "jobs" in intents:
        if ns and service:
            ctx["job"] = mcp_get(f"/namespaces/{ns}/jobs/{service}")
            endpoints_used.append(f"/namespaces/{ns}/jobs/{service}")
        elif ns:
            ctx["jobs"] = mcp_get(f"/namespaces/{ns}/jobs")
            endpoints_used.append(f"/namespaces/{ns}/jobs")

    # Step 21: cronjobs
    if "cronjobs" in intents:
        if ns and service:
            ctx["cronjob"] = mcp_get(f"/namespaces/{ns}/cronjobs/{service}")
            endpoints_used.append(f"/namespaces/{ns}/cronjobs/{service}")
        elif ns:
            ctx["cronjobs"] = mcp_get(f"/namespaces/{ns}/cronjobs")
            endpoints_used.append(f"/namespaces/{ns}/cronjobs")

    # Step 22: HPA
    if "hpa" in intents and ns:
        ctx["hpa"] = mcp_get(f"/namespaces/{ns}/hpa")
        endpoints_used.append(f"/namespaces/{ns}/hpa")

    # Step 23: resource quotas
    if "resourcequotas" in intents and ns:
        ctx["resourcequotas"] = mcp_get(f"/namespaces/{ns}/resourcequotas")
        endpoints_used.append(f"/namespaces/{ns}/resourcequotas")

    # Step 24: limit ranges
    if "limitranges" in intents and ns:
        ctx["limitranges"] = mcp_get(f"/namespaces/{ns}/limitranges")
        endpoints_used.append(f"/namespaces/{ns}/limitranges")

    # Step 25: storage classes (cluster-scoped)
    if "storageclasses" in intents:
        ctx["storageclasses"] = mcp_get("/storageclasses")
        endpoints_used.append("/storageclasses")

    # Step 26: PVCs and PVs
    if "volumes" in intents:
        ctx["persistentvolumes"] = mcp_get("/persistentvolumes")
        endpoints_used.append("/persistentvolumes")
        if ns:
            ctx["pvcs"] = mcp_get(f"/namespaces/{ns}/persistentvolumeclaims")
            endpoints_used.append(f"/namespaces/{ns}/persistentvolumeclaims")

    return ctx, endpoints_used

def summarise_context(ctx: dict) -> str:
    """Format MCP data into a compact, readable string for the LLM prompt."""
    lines = []
    for key, val in ctx.items():
        if isinstance(val, (dict, list)):
            lines.append(f"[{key.upper()}]\n{json.dumps(val, indent=2, default=str)}")
        else:
            lines.append(f"[{key.upper()}]\n{val}")
    return "\n\n".join(lines)

# ── UI ────────────────────────────────────────────────────────────────────────
st.title("🤖 MCP RAG Chatbot")
st.caption("AI-powered Kubernetes assistant — answers grounded in live cluster data")

col1, col2 = st.columns([4, 1])
with col2:
    if st.button("🗑️ Clear chat"):
        st.session_state.chat_history = []
        st.session_state.display_history = []
        st.rerun()

st.markdown("---")

# ── YAML upload (improvement 4) ───────────────────────────────────────────────
with st.expander("📄 Upload a YAML manifest for validation / explanation"):
    uploaded = st.file_uploader("Upload a Kubernetes YAML", type=["yaml", "yml"])
    if uploaded:
        raw_yaml = uploaded.read().decode()
        try:
            parsed = yaml.safe_load(raw_yaml)
            yaml_summary = json.dumps(parsed, indent=2, default=str)
        except Exception:
            yaml_summary = raw_yaml
        if st.button("Analyse manifest"):
            yaml_prompt = (
                f"Analyse the following Kubernetes manifest. "
                f"Identify any misconfigurations, missing best practices, "
                f"or security issues. Explain what it does.\n\n```yaml\n{raw_yaml}\n```"
            )
            st.session_state.chat_history.append({"role": "user", "content": yaml_prompt})
            with st.spinner("Analysing manifest..."):
                resp = client.chat.completions.create(
                    model="gpt-4o",
                    messages=[{"role": "system", "content": SYSTEM_PROMPT}]
                    + st.session_state.chat_history,
                )
            answer = resp.choices[0].message.content
            st.session_state.chat_history.append({"role": "assistant", "content": answer})
            st.session_state.display_history.append(("user", f"📄 Manifest: `{uploaded.name}`", None))
            st.session_state.display_history.append(("assistant", answer, {"yaml": raw_yaml}))
            st.rerun()

st.markdown("---")

# ── Chat display (improvement 3) ──────────────────────────────────────────────
for role, text, raw in st.session_state.display_history:
    with st.chat_message(role):
        st.markdown(text)
        if raw:
            with st.expander("🔍 Raw MCP data used"):
                st.json(raw)

# ── Input ─────────────────────────────────────────────────────────────────────
user_input = st.chat_input("Ask about your cluster…")
if user_input and user_input.strip():
    # Show user message immediately
    st.session_state.display_history.append(("user", user_input, None))
    st.session_state.chat_history.append({"role": "user", "content": user_input})

    # RAG: smart retrieval (improvement 1)
    with st.spinner("Fetching live cluster data…"):
        ctx, endpoints_used = fetch_mcp_context(user_input)

    context_str = summarise_context(ctx)

    # Build prompt with summarised context (improvement 2)
    rag_user_msg = (
        f"Question: {user_input}\n\n"
        f"Live Kubernetes cluster data (from endpoints: {', '.join(endpoints_used)}):\n\n"
        f"{context_str}\n\n"
        f"Answer using only the data above."
    )

    messages = (
        [{"role": "system", "content": SYSTEM_PROMPT}]
        + st.session_state.chat_history[:-1]   # history without the raw question
        + [{"role": "user", "content": rag_user_msg}]
    )

    with st.spinner("Thinking…"):
        response = client.chat.completions.create(model="gpt-4o", messages=messages)

    ai_message = response.choices[0].message.content
    st.session_state.chat_history.append({"role": "assistant", "content": ai_message})
    st.session_state.display_history.append(("assistant", ai_message, ctx))

    st.rerun()