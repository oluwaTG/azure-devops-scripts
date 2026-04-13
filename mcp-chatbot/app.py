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
The data is organised into labelled sections such as [PODS], [DEPLOYMENTS], [LOGS], [NAMESPACES], etc.
When asked about pods, always look at the [PODS] or [PODS_BY_NAMESPACE] section and list them explicitly.
When asked about logs or errors but no specific pod is named, list the pod names from [PODS] and ask the user to specify which one.
If a section is missing from the data, say so clearly rather than claiming the data doesn't exist.
Format your answer clearly using bullet points or tables where helpful."""

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
            if word in ns_lower and word not in stopwords and (len(word) >= 4 or "-" in word):
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

    # 4. Deployment / service / app name
    for pattern in [
        r"\b(?:deployment|service|app|svc)\s+([\w-]+)",
        r"\btroubleshoot\s+([\w-]+)",
        r"\bfor\s+([\w-]+)\s+(?:pod|service|deployment|app)",
    ]:
        m = re.search(pattern, question, re.IGNORECASE)
        if m and m.group(1).lower() not in stopwords:
            service = m.group(1)
            break

    return ns, pod, service

def classify_intent(question: str) -> list[str]:
    """Return a prioritised list of MCP data to fetch based on question keywords."""
    q = question.lower()
    calls = ["cluster"]  # always fetch cluster info

    if any(w in q for w in ["metric", "cpu", "memory", "resource", "limit", "request", "usage"]):
        calls.append("node_metrics")
        calls.append("pod_metrics")
    if any(w in q for w in ["namespace", "namespaces", " ns "]):
        calls.append("namespaces")
    if any(w in q for w in ["pod", "pods", "container", "running", "crash",
                             "restart", "restarts", "phase", "status", "ready"]):
        calls.append("pods")
    if any(w in q for w in ["log", "logs", "error", "exception", "stdout", "stderr", "output"]):
        calls.append("logs")
    if any(w in q for w in ["event", "events", "warning", "oom", "kill", "backoff"]):
        calls.append("events")
    if any(w in q for w in ["troubleshoot", "debug", "broken", "down", "failing",
                             "issue", "problem", "not working", "investigate"]):
        calls.append("troubleshoot")
    if any(w in q for w in ["deployment", "deployments", "deploy", "replica", "replicas", "rollout"]):
        calls.append("deployments")
    if any(w in q for w in ["service", "services", "svc", "clusterip", "nodeport", "loadbalancer"]):
        calls.append("services")
    if any(w in q for w in ["ingress", "ingresses", "route", "host", "tls", "hostname"]):
        calls.append("ingresses")
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
    if any(w in q for w in ["pvc", "pv", "persistentvolume", "persistentvolumeclaim",
                             "volume", "volumes", "storage", "storageclass"]):
        calls.append("volumes")

    return list(dict.fromkeys(calls))

def fetch_mcp_context(question: str) -> tuple[dict, list[str]]:
    """
    Smart retrieval:
    1. Always fetch namespaces first so we can match namespace names in the question.
    2. Extract entities (ns, pod, service) with cluster-aware matching.
    3. Call only the endpoints relevant to the question intent.
    4. If a namespace is needed but not found, fall back to fetching pods across all namespaces.
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
    ns, pod, service = extract_entities(question, known_namespaces=all_namespaces)

    needs_pods    = any(i in intents for i in ["pods", "logs", "events", "troubleshoot"])
    needs_metrics = any(i in intents for i in ["node_metrics", "pod_metrics"])

    # Step 3: node metrics (no namespace needed)
    if "node_metrics" in intents:
        ctx["node_metrics"] = mcp_get("/metrics/nodes")
        endpoints_used.append("/metrics/nodes")

    # Step 4: pod metrics across all namespaces (no namespace needed)
    if "pod_metrics" in intents:
        ctx["pod_metrics"] = mcp_get("/metrics/pods")
        endpoints_used.append("/metrics/pods")

    # Step 5: pod listing
    if needs_pods:
        if ns:
            # Specific namespace
            ctx["pods"] = mcp_get(f"/namespaces/{ns}/pods")
            endpoints_used.append(f"/namespaces/{ns}/pods")
        else:
            # No namespace found — fetch pods from every namespace
            all_pods = {}
            for n in all_namespaces:
                result = mcp_get(f"/namespaces/{n}/pods")
                if isinstance(result, list) and result:
                    all_pods[n] = result
            if all_pods:
                ctx["pods_by_namespace"] = all_pods
                endpoints_used.append("/namespaces/*/pods (all)")

    # Step 6: logs — need both ns and pod name
    if "logs" in intents:
        if ns and pod:
            ctx["logs"] = mcp_get(f"/namespaces/{ns}/pods/{pod}/logs?tail=100", text=True)
            endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/logs")
        # If we have a namespace but no specific pod, pods were already fetched in step 5.
        # The LLM will see [PODS] and can ask the user to clarify which pod they mean.

    # Step 7: events
    if "events" in intents and ns and pod:
        ctx["events"] = mcp_get(f"/namespaces/{ns}/pods/{pod}/events")
        endpoints_used.append(f"/namespaces/{ns}/pods/{pod}/events")

    # Step 8: troubleshoot
    svc_name = service or pod
    if "troubleshoot" in intents and ns and svc_name:
        ctx["troubleshoot"] = mcp_get(f"/troubleshoot/service/{ns}/{svc_name}")
        endpoints_used.append(f"/troubleshoot/service/{ns}/{svc_name}")
    elif "troubleshoot" in intents and not ns:
        ctx["troubleshoot_note"] = "Namespace not identified. Please specify a namespace to troubleshoot."

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

    # Step 10: services
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

    # Step 11: ingresses
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

    # Step 12: configmaps
    if "configmaps" in intents:
        if ns and service:
            ctx["configmap"] = mcp_get(f"/namespaces/{ns}/configmaps/{service}")
            endpoints_used.append(f"/namespaces/{ns}/configmaps/{service}")
        elif ns:
            ctx["configmaps"] = mcp_get(f"/namespaces/{ns}/configmaps")
            endpoints_used.append(f"/namespaces/{ns}/configmaps")

    # Step 13: secrets (keys only)
    if "secrets" in intents and ns:
        ctx["secrets"] = mcp_get(f"/namespaces/{ns}/secrets")
        endpoints_used.append(f"/namespaces/{ns}/secrets")

    # Step 14: RBAC
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

    # Step 15: service accounts
    if "serviceaccounts" in intents and ns:
        ctx["serviceaccounts"] = mcp_get(f"/namespaces/{ns}/serviceaccounts")
        endpoints_used.append(f"/namespaces/{ns}/serviceaccounts")

    # Step 16: statefulsets
    if "statefulsets" in intents and ns:
        ctx["statefulsets"] = mcp_get(f"/namespaces/{ns}/statefulsets")
        endpoints_used.append(f"/namespaces/{ns}/statefulsets")

    # Step 17: daemonsets
    if "daemonsets" in intents and ns:
        ctx["daemonsets"] = mcp_get(f"/namespaces/{ns}/daemonsets")
        endpoints_used.append(f"/namespaces/{ns}/daemonsets")

    # Step 18: PVCs and PVs
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