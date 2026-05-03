using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using k8s;
using Microsoft.Extensions.Caching.Memory;
using k8s.Models;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddMemoryCache();
builder.Services.AddEndpointsApiExplorer();

var app = builder.Build();

Kubernetes CreateK8sClient()
{
    try
    {
        return new Kubernetes(KubernetesClientConfiguration.InClusterConfig());
    }
    catch
    {
        return new Kubernetes(KubernetesClientConfiguration.BuildConfigFromConfigFile());
    }
}

var k8s = CreateK8sClient();
var cache = app.Services.GetRequiredService<IMemoryCache>();

// Recreates the k8s client if the connection has dropped (fixes SSL NullReferenceException after idle)
T WithK8sRetry<T>(Func<Kubernetes, T> action)
{
    try
    {
        return action(k8s);
    }
    catch (Exception ex) when (
        ex is System.Net.Http.HttpRequestException ||
        ex is NullReferenceException ||
        (ex.InnerException is NullReferenceException) ||
        (ex.InnerException is System.Net.Http.HttpRequestException))
    {
        k8s = CreateK8sClient();
        return action(k8s);
    }
}

async Task<T> WithK8sRetryAsync<T>(Func<Kubernetes, Task<T>> action)
{
    try
    {
        return await action(k8s);
    }
    catch (Exception ex) when (
        ex is System.Net.Http.HttpRequestException ||
        ex is NullReferenceException ||
        (ex.InnerException is NullReferenceException) ||
        (ex.InnerException is System.Net.Http.HttpRequestException))
    {
        k8s = CreateK8sClient();
        return await action(k8s);
    }
}

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/cluster/info", async () =>
{
    var nodes = await WithK8sRetryAsync(c => c.ListNodeAsync());
    var ver = await WithK8sRetryAsync(c => c.GetCodeAsync());
    return Results.Ok(new {
        version = ver.GitVersion,
        nodeCount = nodes.Items.Count,
        nodes = nodes.Items.Select(n => new {
            name = n.Metadata.Name,
            ready = n.Status?.Conditions?.FirstOrDefault(c => c.Type == "Ready")?.Status
        })
    });
});

app.MapGet("/namespaces", async () =>
{
    var ns = await WithK8sRetryAsync(c => c.ListNamespaceAsync());
    return Results.Ok(ns.Items.Select(n => n.Metadata.Name));
});

app.MapGet("/namespaces/{ns}/pods", async (string ns) =>
{
    var pods = await WithK8sRetryAsync(c => c.ListNamespacedPodAsync(ns));
    return Results.Ok(pods.Items.Select(p => {
        var statuses = p.Status?.ContainerStatuses ?? [];
        var initStatuses = p.Status?.InitContainerStatuses ?? [];
        var readyCount = statuses.Count(s => s.Ready);
        var totalCount = statuses.Count;
        return new {
            name       = p.Metadata.Name,
            phase      = p.Status?.Phase,
            ready      = $"{readyCount}/{totalCount}",
            restarts   = statuses.Sum(s => s.RestartCount),
            containers = statuses.Select(s => new {
                name     = s.Name,
                ready    = s.Ready,
                restarts = s.RestartCount,
                image    = s.Image,
                state    = s.State?.Running  != null ? "Running"  :
                           s.State?.Waiting  != null ? $"Waiting({s.State.Waiting.Reason})"  :
                           s.State?.Terminated != null ? $"Terminated({s.State.Terminated.Reason})" : "Unknown"
            }),
            initContainers = initStatuses.Select(s => new {
                name     = s.Name,
                ready    = s.Ready,
                restarts = s.RestartCount,
                state    = s.State?.Running  != null ? "Running"  :
                           s.State?.Waiting  != null ? $"Waiting({s.State.Waiting.Reason})"  :
                           s.State?.Terminated != null ? $"Terminated({s.State.Terminated.Reason})" : "Unknown"
            })
        };
    }));
});


app.MapGet("/namespaces/{ns}/pods/{pod}/events", async (string ns, string pod) =>
{
    var fieldSelector = $"involvedObject.name={pod},involvedObject.namespace={ns}";
    var evts = await WithK8sRetryAsync(c => c.CoreV1.ListNamespacedEventAsync(ns, fieldSelector: fieldSelector));
    return Results.Ok(evts.Items.Select(e => new { e.Metadata.CreationTimestamp, e.Reason, e.Message, e.Type }));
});


app.MapGet("/namespaces/{ns}/pods/{pod}/logs", async (string ns, string pod, string? container = null, int? tail = 200) =>
{
    using var logStream = await WithK8sRetryAsync(c =>
        c.ReadNamespacedPodLogAsync(pod, ns, container: container, tailLines: tail));
    string logText = string.Empty;
    if (logStream != null)
    {
        using var reader = new StreamReader(logStream);
        logText = await reader.ReadToEndAsync();
    }
    return Results.Text(logText, "text/plain");
});

// Fetch logs from ALL containers in a pod, returned as a JSON map { containerName -> logText }
app.MapGet("/namespaces/{ns}/pods/{pod}/logs/all", async (string ns, string pod, int? tail = 200) =>
{
    var podObj = await WithK8sRetryAsync(c => c.ReadNamespacedPodAsync(pod, ns));
    var containerNames = podObj.Spec?.Containers?.Select(c => c.Name).ToList() ?? [];
    var result = new Dictionary<string, string>();
    foreach (var cname in containerNames)
    {
        try
        {
            using var logStream = await WithK8sRetryAsync(c =>
                c.ReadNamespacedPodLogAsync(pod, ns, container: cname, tailLines: tail));
            if (logStream != null)
            {
                using var reader = new StreamReader(logStream);
                result[cname] = await reader.ReadToEndAsync();
            }
        }
        catch (Exception ex)
        {
            result[cname] = $"[error fetching logs: {ex.Message}]";
        }
    }
    return Results.Ok(result);
});

// Per-container logs via clean REST path: /namespaces/{ns}/pods/{pod}/containers/{container}/logs
app.MapGet("/namespaces/{ns}/pods/{pod}/containers/{container}/logs", async (string ns, string pod, string container, int? tail = 200) =>
{
    try
    {
        using var logStream = await WithK8sRetryAsync(c =>
            c.ReadNamespacedPodLogAsync(pod, ns, container: container, tailLines: tail));
        string logText = string.Empty;
        if (logStream != null)
        {
            using var reader = new StreamReader(logStream);
            logText = await reader.ReadToEndAsync();
        }
        return Results.Text(logText, "text/plain");
    }
    catch (Exception ex)
    {
        return Results.NotFound(new { error = $"Could not fetch logs for container '{container}': {ex.Message}" });
    }
});

// List containers in a pod
app.MapGet("/namespaces/{ns}/pods/{pod}/containers", async (string ns, string pod) =>
{
    var podObj = await WithK8sRetryAsync(c => c.ReadNamespacedPodAsync(pod, ns));
    var containers = podObj.Spec?.Containers?.Select(c => new {
        name  = c.Name,
        image = c.Image,
        ports = c.Ports?.Select(p => new { p.ContainerPort, p.Protocol }),
        resources = new {
            requests = c.Resources?.Requests?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
            limits   = c.Resources?.Limits?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
        }
    }) ?? [];
    var initContainers = podObj.Spec?.InitContainers?.Select(c => new {
        name  = c.Name,
        image = c.Image,
        init  = true
    }) ?? [];
    var statuses = podObj.Status?.ContainerStatuses ?? [];
    return Results.Ok(new {
        pod        = pod,
        @namespace = ns,
        containers = containers.Select(c => new {
            c.name, c.image, c.ports, c.resources,
            status = statuses.FirstOrDefault(s => s.Name == c.name) is {} s ? new {
                ready    = s.Ready,
                restarts = s.RestartCount,
                state    = s.State?.Running    != null ? "Running"
                         : s.State?.Waiting    != null ? $"Waiting({s.State.Waiting.Reason})"
                         : s.State?.Terminated != null ? $"Terminated({s.State.Terminated.Reason})"
                         : "Unknown",
                image = s.Image
            } : null
        }),
        initContainers = initContainers
    });
});

// Troubleshoot endpoint: aggregates pods, events and last logs for a deployment/service name
app.MapGet("/troubleshoot/service/{ns}/{name}", async (string ns, string name) =>
{
    // find pods by label app=name
    var pods = await WithK8sRetryAsync(c => c.ListNamespacedPodAsync(ns, labelSelector: $"app={name}"));
    if (pods.Items.Count == 0)
    {
        // fallback: try pods with name prefix
        pods = await WithK8sRetryAsync(c => c.ListNamespacedPodAsync(ns, fieldSelector: $"metadata.name={name}"));
    }

    var result = new List<object>();
    foreach (var p in pods.Items)
    {
        var podName = p.Metadata.Name;
        var evtSel = $"involvedObject.name={podName},involvedObject.namespace={ns}";
        var evts = await WithK8sRetryAsync(c => c.CoreV1.ListNamespacedEventAsync(ns, fieldSelector: evtSel));
        string lastLogText = string.Empty;
        using (var lastLogStream = await WithK8sRetryAsync(c => c.ReadNamespacedPodLogAsync(podName, ns, tailLines: 200)))
        {
            if (lastLogStream != null)
            {
                using var reader = new StreamReader(lastLogStream);
                lastLogText = await reader.ReadToEndAsync();
            }
        }
        var lastLogLines = lastLogText.Split('\n').TakeLast(200);
        var tStatuses = p.Status?.ContainerStatuses ?? [];
        result.Add(new {
            pod = podName,
            phase = p.Status?.Phase,
            ready = $"{tStatuses.Count(s => s.Ready)}/{tStatuses.Count}",
            restarts = tStatuses.Sum(s => s.RestartCount),
            containers = tStatuses.Select(s => new {
                name = s.Name, ready = s.Ready, restarts = s.RestartCount, image = s.Image
            }),
            events = evts.Items.Select(e => new { e.Metadata.CreationTimestamp, e.Reason, e.Message, e.Type }),
            lastLog = lastLogLines
        });
    }

    return Results.Ok(new {
        service = name,
        @namespace = ns,
        found = result.Count,
        details = result
    });
});

// Node resource metrics endpoint
app.MapGet("/metrics/nodes", async () =>
{
    var nodes = await WithK8sRetryAsync(c => c.ListNodeAsync());
    var nodeMetrics = nodes.Items.Select(n => new {
        name = n.Metadata.Name,
        cpu = n.Status?.Capacity != null && n.Status.Capacity.ContainsKey("cpu") ? n.Status.Capacity["cpu"].ToString() : null,
        memory = n.Status?.Capacity != null && n.Status.Capacity.ContainsKey("memory") ? n.Status.Capacity["memory"].ToString() : null,
        allocatable_cpu = n.Status?.Allocatable != null && n.Status.Allocatable.ContainsKey("cpu") ? n.Status.Allocatable["cpu"].ToString() : null,
        allocatable_memory = n.Status?.Allocatable != null && n.Status.Allocatable.ContainsKey("memory") ? n.Status.Allocatable["memory"].ToString() : null,
        ready = n.Status?.Conditions?.FirstOrDefault(c => c.Type == "Ready")?.Status,
        labels = n.Metadata.Labels
    });
    return Results.Ok(nodeMetrics);
});

// List all nodes (summary)
app.MapGet("/nodes", async () =>
{
    var nodes = await WithK8sRetryAsync(c => c.ListNodeAsync());
    return Results.Ok(nodes.Items.Select(n => new {
        name        = n.Metadata.Name,
        ready       = n.Status?.Conditions?.FirstOrDefault(c => c.Type == "Ready")?.Status,
        roles       = n.Metadata.Labels?
                        .Where(l => l.Key.StartsWith("node-role.kubernetes.io/"))
                        .Select(l => l.Key.Replace("node-role.kubernetes.io/", ""))
                        .ToList(),
        osImage     = n.Status?.NodeInfo?.OsImage,
        kubeletVersion = n.Status?.NodeInfo?.KubeletVersion,
        cpu         = n.Status?.Capacity != null && n.Status.Capacity.ContainsKey("cpu")    ? n.Status.Capacity["cpu"].ToString()    : null,
        memory      = n.Status?.Capacity != null && n.Status.Capacity.ContainsKey("memory") ? n.Status.Capacity["memory"].ToString() : null
    }));
});

// Full detail for a single node
app.MapGet("/nodes/{name}", async (string name) =>
{
    var nodes = await WithK8sRetryAsync(c => c.ListNodeAsync());
    var n = nodes.Items.FirstOrDefault(x => x.Metadata.Name == name);
    if (n is null) return Results.NotFound(new { error = $"Node '{name}' not found" });

    return Results.Ok(new {
        name       = n.Metadata.Name,
        uid        = n.Metadata.Uid,
        createdAt  = n.Metadata.CreationTimestamp,
        labels     = n.Metadata.Labels,
        annotations = n.Metadata.Annotations,
        roles      = n.Metadata.Labels?
                        .Where(l => l.Key.StartsWith("node-role.kubernetes.io/"))
                        .Select(l => l.Key.Replace("node-role.kubernetes.io/", ""))
                        .ToList(),

        // Node info
        nodeInfo = new {
            osImage          = n.Status?.NodeInfo?.OsImage,
            operatingSystem  = n.Status?.NodeInfo?.OperatingSystem,
            architecture     = n.Status?.NodeInfo?.Architecture,
            kernelVersion    = n.Status?.NodeInfo?.KernelVersion,
            containerRuntime = n.Status?.NodeInfo?.ContainerRuntimeVersion,
            kubeletVersion   = n.Status?.NodeInfo?.KubeletVersion,
            kubeProxyVersion = n.Status?.NodeInfo?.KubeProxyVersion
        },

        // Capacity & allocatable
        capacity = n.Status?.Capacity?
            .ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
        allocatable = n.Status?.Allocatable?
            .ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),

        // Conditions (Ready, MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable)
        conditions = n.Status?.Conditions?.Select(c => new {
            type    = c.Type,
            status  = c.Status,
            reason  = c.Reason,
            message = c.Message,
            lastTransitionTime = c.LastTransitionTime
        }),

        // Addresses (InternalIP, ExternalIP, Hostname)
        addresses = n.Status?.Addresses?.Select(a => new {
            type    = a.Type,
            address = a.Address
        }),

        // Taints
        taints = n.Spec?.Taints?.Select(t => new {
            key    = t.Key,
            value  = t.Value,
            effect = t.Effect
        }),

        // Pods currently scheduled on this node (cross-namespace scan)
        unschedulable = n.Spec?.Unschedulable ?? false
    });
});

// Pod/container resource metrics endpoint
app.MapGet("/metrics/pods", async () =>
{
    var nsList = await WithK8sRetryAsync(c => c.ListNamespaceAsync());
    var allPods = new List<object>();
    foreach (var ns in nsList.Items.Select(n => n.Metadata.Name))
    {
        var pods = await WithK8sRetryAsync(c => c.ListNamespacedPodAsync(ns));
        foreach (var pod in pods.Items)
        {
            var containers = pod.Spec.Containers.Select(c => new {
                name = c.Name,
                requests = c.Resources?.Requests != null
                    ? c.Resources.Requests.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
                    : null,
                limits = c.Resources?.Limits != null
                    ? c.Resources.Limits.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
                    : null
            });
            allPods.Add(new {
                namespaceName = ns,
                pod = pod.Metadata.Name,
                phase = pod.Status?.Phase,
                containers = containers
            });
        }
    }
    return Results.Ok(allPods);
});

// ── Dashboard UI (served from ui/dashboard.html) ─────────────────────────────
app.MapGet("/", async context =>
{
    var basePath = AppContext.BaseDirectory;
    var htmlPath = Path.Combine(basePath, "ui", "dashboard.html");
    if (!File.Exists(htmlPath))
    {
        context.Response.StatusCode = 404;
        await context.Response.WriteAsync("dashboard.html not found at: " + htmlPath);
        return;
    }
    var html = await File.ReadAllTextAsync(htmlPath);
    context.Response.ContentType = "text/html";
    await context.Response.WriteAsync(html);
});

// ── Deployments ──────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/deployments", async (string ns) =>
{
    var deps = await WithK8sRetryAsync(c => c.ListNamespacedDeploymentAsync(ns));
    return Results.Ok(deps.Items.Select(d => new {
        name       = d.Metadata.Name,
        replicas   = d.Spec?.Replicas,
        ready      = d.Status?.ReadyReplicas,
        available  = d.Status?.AvailableReplicas,
        labels     = d.Metadata.Labels,
        selector   = d.Spec?.Selector?.MatchLabels
    }));
});

app.MapGet("/namespaces/{ns}/deployments/{name}", async (string ns, string name) =>
{
    var d = await WithK8sRetryAsync(c => c.ReadNamespacedDeploymentAsync(name, ns));
    return Results.Ok(new {
        name       = d.Metadata.Name,
        @namespace = d.Metadata.NamespaceProperty,
        replicas   = d.Spec?.Replicas,
        ready      = d.Status?.ReadyReplicas,
        available  = d.Status?.AvailableReplicas,
        strategy   = d.Spec?.Strategy?.Type,
        labels     = d.Metadata.Labels,
        annotations= d.Metadata.Annotations,
        selector   = d.Spec?.Selector?.MatchLabels,
        containers = d.Spec?.Template?.Spec?.Containers?.Select(c => new {
            name    = c.Name,
            image   = c.Image,
            ports   = c.Ports?.Select(p => new { p.ContainerPort, p.Protocol }),
            requests= c.Resources?.Requests?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
            limits  = c.Resources?.Limits?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
        })
    });
});

// ── Services ─────────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/services", async (string ns) =>
{
    var svcs = await WithK8sRetryAsync(c => c.ListNamespacedServiceAsync(ns));
    return Results.Ok(svcs.Items.Select(s => new {
        name      = s.Metadata.Name,
        type      = s.Spec?.Type,
        clusterIP = s.Spec?.ClusterIP,
        ports     = s.Spec?.Ports?.Select(p => new { p.Port, p.TargetPort, p.Protocol, p.NodePort }),
        selector  = s.Spec?.Selector,
        labels    = s.Metadata.Labels
    }));
});

app.MapGet("/namespaces/{ns}/services/{name}", async (string ns, string name) =>
{
    var s = await WithK8sRetryAsync(c => c.ReadNamespacedServiceAsync(name, ns));
    return Results.Ok(new {
        name        = s.Metadata.Name,
        @namespace  = s.Metadata.NamespaceProperty,
        type        = s.Spec?.Type,
        clusterIP   = s.Spec?.ClusterIP,
        externalIPs = s.Spec?.ExternalIPs,
        ports       = s.Spec?.Ports?.Select(p => new { p.Port, p.TargetPort, p.Protocol, p.NodePort }),
        selector    = s.Spec?.Selector,
        labels      = s.Metadata.Labels,
        annotations = s.Metadata.Annotations
    });
});

// ── Ingresses ────────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/ingresses", async (string ns) =>
{
    var ings = await WithK8sRetryAsync(c => c.ListNamespacedIngressAsync(ns));
    return Results.Ok(ings.Items.Select(i => new {
        name        = i.Metadata.Name,
        ingressClass= i.Spec?.IngressClassName,
        rules       = i.Spec?.Rules?.Select(r => new {
            host  = r.Host,
            paths = r.Http?.Paths?.Select(p => new {
                path    = p.Path,
                pathType= p.PathType,
                backend = new { service = p.Backend?.Service?.Name, port = p.Backend?.Service?.Port?.Number }
            })
        }),
        tls         = i.Spec?.Tls?.Select(t => new { t.Hosts, t.SecretName }),
        labels      = i.Metadata.Labels
    }));
});

app.MapGet("/namespaces/{ns}/ingresses/{name}", async (string ns, string name) =>
{
    var i = await WithK8sRetryAsync(c => c.ReadNamespacedIngressAsync(name, ns));
    return Results.Ok(new {
        name        = i.Metadata.Name,
        @namespace  = i.Metadata.NamespaceProperty,
        ingressClass= i.Spec?.IngressClassName,
        annotations = i.Metadata.Annotations,
        rules       = i.Spec?.Rules?.Select(r => new {
            host  = r.Host,
            paths = r.Http?.Paths?.Select(p => new {
                path    = p.Path,
                pathType= p.PathType,
                backend = new { service = p.Backend?.Service?.Name, port = p.Backend?.Service?.Port?.Number }
            })
        }),
        tls         = i.Spec?.Tls?.Select(t => new { t.Hosts, t.SecretName })
    });
});

// ── ConfigMaps ───────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/configmaps", async (string ns) =>
{
    var cms = await WithK8sRetryAsync(c => c.ListNamespacedConfigMapAsync(ns));
    return Results.Ok(cms.Items.Select(cm => new {
        name   = cm.Metadata.Name,
        keys   = cm.Data?.Keys,
        labels = cm.Metadata.Labels
    }));
});

app.MapGet("/namespaces/{ns}/configmaps/{name}", async (string ns, string name) =>
{
    var cm = await WithK8sRetryAsync(c => c.ReadNamespacedConfigMapAsync(name, ns));
    return Results.Ok(new {
        name        = cm.Metadata.Name,
        @namespace  = cm.Metadata.NamespaceProperty,
        labels      = cm.Metadata.Labels,
        annotations = cm.Metadata.Annotations,
        data        = cm.Data
    });
});

// ── Secrets (keys only — values redacted) ────────────────────────────────────

app.MapGet("/namespaces/{ns}/secrets", async (string ns) =>
{
    var secrets = await WithK8sRetryAsync(c => c.ListNamespacedSecretAsync(ns));
    return Results.Ok(secrets.Items.Select(s => new {
        name   = s.Metadata.Name,
        type   = s.Type,
        keys   = s.Data?.Keys,   // values intentionally omitted
        labels = s.Metadata.Labels
    }));
});

// ── RBAC ─────────────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/rolebindings", async (string ns) =>
{
    var rbs = await WithK8sRetryAsync(c => c.ListNamespacedRoleBindingAsync(ns));
    return Results.Ok(rbs.Items.Select(rb => new {
        name     = rb.Metadata.Name,
        roleRef  = new { rb.RoleRef.Kind, rb.RoleRef.Name },
        subjects = rb.Subjects?.Select(s => new { s.Kind, s.Name, s.NamespaceProperty })
    }));
});

app.MapGet("/namespaces/{ns}/roles", async (string ns) =>
{
    var roles = await WithK8sRetryAsync(c => c.ListNamespacedRoleAsync(ns));
    return Results.Ok(roles.Items.Select(r => new {
        name  = r.Metadata.Name,
        rules = r.Rules?.Select(rule => new {
            apiGroups = rule.ApiGroups,
            resources = rule.Resources,
            verbs     = rule.Verbs
        })
    }));
});

app.MapGet("/clusterroles", async () =>
{
    var crs = await WithK8sRetryAsync(c => c.ListClusterRoleAsync());
    return Results.Ok(crs.Items
        .Where(r => r.Metadata.Name != null && !r.Metadata.Name.StartsWith("system:"))
        .Select(r => new {
            name  = r.Metadata.Name,
            rules = r.Rules?.Select(rule => new {
                apiGroups = rule.ApiGroups,
                resources = rule.Resources,
                verbs     = rule.Verbs
            })
        }));
});

app.MapGet("/clusterrolebindings", async () =>
{
    var crbs = await WithK8sRetryAsync(c => c.ListClusterRoleBindingAsync());
    return Results.Ok(crbs.Items
        .Where(r => r.Metadata.Name != null && !r.Metadata.Name.StartsWith("system:"))
        .Select(rb => new {
            name     = rb.Metadata.Name,
            roleRef  = new { rb.RoleRef.Kind, rb.RoleRef.Name },
            subjects = rb.Subjects?.Select(s => new { s.Kind, s.Name, s.NamespaceProperty })
        }));
});

// ── ServiceAccounts ──────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/serviceaccounts", async (string ns) =>
{
    var sas = await WithK8sRetryAsync(c => c.ListNamespacedServiceAccountAsync(ns));
    return Results.Ok(sas.Items.Select(sa => new {
        name        = sa.Metadata.Name,
        labels      = sa.Metadata.Labels,
        annotations = sa.Metadata.Annotations
    }));
});

// ── StatefulSets ─────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/statefulsets", async (string ns) =>
{
    var sets = await WithK8sRetryAsync(c => c.ListNamespacedStatefulSetAsync(ns));
    return Results.Ok(sets.Items.Select(s => new {
        name      = s.Metadata.Name,
        replicas  = s.Spec?.Replicas,
        ready     = s.Status?.ReadyReplicas,
        labels    = s.Metadata.Labels,
        selector  = s.Spec?.Selector?.MatchLabels,
        containers= s.Spec?.Template?.Spec?.Containers?.Select(c => new { c.Name, c.Image })
    }));
});

// ── DaemonSets ───────────────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/daemonsets", async (string ns) =>
{
    var dsets = await WithK8sRetryAsync(c => c.ListNamespacedDaemonSetAsync(ns));
    return Results.Ok(dsets.Items.Select(d => new {
        name          = d.Metadata.Name,
        desired       = d.Status?.DesiredNumberScheduled,
        ready         = d.Status?.NumberReady,
        labels        = d.Metadata.Labels,
        containers    = d.Spec?.Template?.Spec?.Containers?.Select(c => new { c.Name, c.Image })
    }));
});

// ── Persistent Volumes ───────────────────────────────────────────────────────

app.MapGet("/namespaces/{ns}/persistentvolumeclaims", async (string ns) =>
{
    var pvcs = await WithK8sRetryAsync(c => c.ListNamespacedPersistentVolumeClaimAsync(ns));
    return Results.Ok(pvcs.Items.Select(pvc => new {
        name         = pvc.Metadata.Name,
        status       = pvc.Status?.Phase,
        capacity     = pvc.Status?.Capacity?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
        accessModes  = pvc.Spec?.AccessModes,
        storageClass = pvc.Spec?.StorageClassName,
        volumeName   = pvc.Spec?.VolumeName
    }));
});

app.MapGet("/persistentvolumes", async () =>
{
    var pvs = await WithK8sRetryAsync(c => c.ListPersistentVolumeAsync());
    return Results.Ok(pvs.Items.Select(pv => new {
        name         = pv.Metadata.Name,
        status       = pv.Status?.Phase,
        capacity     = pv.Spec?.Capacity?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
        accessModes  = pv.Spec?.AccessModes,
        storageClass = pv.Spec?.StorageClassName,
        claimRef     = pv.Spec?.ClaimRef != null ? new { pv.Spec.ClaimRef.Name, pv.Spec.ClaimRef.NamespaceProperty } : null,
        reclaimPolicy= pv.Spec?.PersistentVolumeReclaimPolicy
    }));
});

// ── Namespace-wide events ──────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/events", async (string ns) =>
{
    var evts = await WithK8sRetryAsync(c => c.CoreV1.ListNamespacedEventAsync(ns));
    return Results.Ok(evts.Items
        .OrderByDescending(e => e.LastTimestamp ?? e.Metadata.CreationTimestamp)
        .Select(e => new {
            name       = e.Metadata.Name,
            type       = e.Type,          // Normal / Warning
            reason     = e.Reason,
            message    = e.Message,
            regarding  = new { kind = e.InvolvedObject.Kind, name = e.InvolvedObject.Name },
            count      = e.Count,
            firstTime  = e.FirstTimestamp,
            lastTime   = e.LastTimestamp ?? e.Metadata.CreationTimestamp
        }));
});

// ── Jobs ──────────────────────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/jobs", async (string ns) =>
{
    var jobs = await WithK8sRetryAsync(c => c.ListNamespacedJobAsync(ns));
    return Results.Ok(jobs.Items.Select(j => new {
        name        = j.Metadata.Name,
        completions = j.Spec?.Completions,
        succeeded   = j.Status?.Succeeded ?? 0,
        failed      = j.Status?.Failed ?? 0,
        active      = j.Status?.Active ?? 0,
        startTime   = j.Status?.StartTime,
        completionTime = j.Status?.CompletionTime,
        conditions  = j.Status?.Conditions?.Select(c => new { c.Type, c.Status, c.Reason, c.Message })
    }));
});

app.MapGet("/namespaces/{ns}/jobs/{name}", async (string ns, string name) =>
{
    var jobs = await WithK8sRetryAsync(c => c.ListNamespacedJobAsync(ns));
    var j = jobs.Items.FirstOrDefault(x => x.Metadata.Name == name);
    if (j is null) return Results.NotFound(new { error = $"Job '{name}' not found" });
    return Results.Ok(new {
        name        = j.Metadata.Name,
        labels      = j.Metadata.Labels,
        completions = j.Spec?.Completions,
        parallelism = j.Spec?.Parallelism,
        succeeded   = j.Status?.Succeeded ?? 0,
        failed      = j.Status?.Failed ?? 0,
        active      = j.Status?.Active ?? 0,
        startTime   = j.Status?.StartTime,
        completionTime = j.Status?.CompletionTime,
        conditions  = j.Status?.Conditions?.Select(c => new { c.Type, c.Status, c.Reason, c.Message }),
        selector    = j.Spec?.Selector?.MatchLabels
    });
});

// ── CronJobs ──────────────────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/cronjobs", async (string ns) =>
{
    var cjs = await WithK8sRetryAsync(c => c.ListNamespacedCronJobAsync(ns));
    return Results.Ok(cjs.Items.Select(cj => new {
        name             = cj.Metadata.Name,
        schedule         = cj.Spec?.Schedule,
        suspend          = cj.Spec?.Suspend ?? false,
        lastScheduleTime = cj.Status?.LastScheduleTime,
        lastSuccessTime  = cj.Status?.LastSuccessfulTime,
        activeJobs       = cj.Status?.Active?.Count ?? 0
    }));
});

app.MapGet("/namespaces/{ns}/cronjobs/{name}", async (string ns, string name) =>
{
    var cjs = await WithK8sRetryAsync(c => c.ListNamespacedCronJobAsync(ns));
    var cj = cjs.Items.FirstOrDefault(x => x.Metadata.Name == name);
    if (cj is null) return Results.NotFound(new { error = $"CronJob '{name}' not found" });
    return Results.Ok(new {
        name             = cj.Metadata.Name,
        labels           = cj.Metadata.Labels,
        schedule         = cj.Spec?.Schedule,
        suspend          = cj.Spec?.Suspend ?? false,
        concurrencyPolicy= cj.Spec?.ConcurrencyPolicy,
        successfulJobsLimit = cj.Spec?.SuccessfulJobsHistoryLimit,
        failedJobsLimit  = cj.Spec?.FailedJobsHistoryLimit,
        lastScheduleTime = cj.Status?.LastScheduleTime,
        lastSuccessTime  = cj.Status?.LastSuccessfulTime,
        activeJobs       = cj.Status?.Active?.Select(r => r.Name)
    });
});

// ── HorizontalPodAutoscalers ───────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/hpa", async (string ns) =>
{
    var hpas = await WithK8sRetryAsync(c => c.AutoscalingV2.ListNamespacedHorizontalPodAutoscalerAsync(ns));
    return Results.Ok(hpas.Items.Select(h => new {
        name           = h.Metadata.Name,
        target         = h.Spec?.ScaleTargetRef?.Name,
        targetKind     = h.Spec?.ScaleTargetRef?.Kind,
        minReplicas    = h.Spec?.MinReplicas,
        maxReplicas    = h.Spec?.MaxReplicas,
        currentReplicas= h.Status?.CurrentReplicas,
        desiredReplicas= h.Status?.DesiredReplicas,
        conditions     = h.Status?.Conditions?.Select(c => new { c.Type, c.Status, c.Reason, c.Message }),
        metrics        = h.Status?.CurrentMetrics?.Select(m => new {
            type   = m.Type,
            cpu    = m.Resource?.Current?.AverageUtilization
        })
    }));
});

// ── ResourceQuotas ────────────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/resourcequotas", async (string ns) =>
{
    var rqs = await WithK8sRetryAsync(c => c.ListNamespacedResourceQuotaAsync(ns));
    return Results.Ok(rqs.Items.Select(rq => new {
        name = rq.Metadata.Name,
        hard = rq.Status?.Hard?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
        used = rq.Status?.Used?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
    }));
});

// ── LimitRanges ───────────────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/limitranges", async (string ns) =>
{
    var lrs = await WithK8sRetryAsync(c => c.ListNamespacedLimitRangeAsync(ns));
    return Results.Ok(lrs.Items.Select(lr => new {
        name   = lr.Metadata.Name,
        limits = lr.Spec?.Limits?.Select(l => new {
            type           = l.Type,
            max            = l.Max?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
            min            = l.Min?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
            defaultLimit   = l.DefaultProperty?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString()),
            defaultRequest = l.DefaultRequest?.ToDictionary(kv => kv.Key, kv => kv.Value.ToString())
        })
    }));
});

// ── NetworkPolicies ───────────────────────────────────────────────────────
app.MapGet("/namespaces/{ns}/networkpolicies", async (string ns) =>
{
    var nps = await WithK8sRetryAsync(c => c.NetworkingV1.ListNamespacedNetworkPolicyAsync(ns));
    return Results.Ok(nps.Items.Select(np => new {
        name        = np.Metadata.Name,
        podSelector = np.Spec?.PodSelector?.MatchLabels,
        policyTypes = np.Spec?.PolicyTypes,
        ingressRules= np.Spec?.Ingress?.Count ?? 0,
        egressRules = np.Spec?.Egress?.Count ?? 0
    }));
});

// ── StorageClasses ────────────────────────────────────────────────────────
app.MapGet("/storageclasses", async () =>
{
    var scs = await WithK8sRetryAsync(c => c.ListStorageClassAsync());
    return Results.Ok(scs.Items.Select(sc => new {
        name              = sc.Metadata.Name,
        provisioner       = sc.Provisioner,
        reclaimPolicy     = sc.ReclaimPolicy,
        volumeBindingMode = sc.VolumeBindingMode,
        allowExpansion    = sc.AllowVolumeExpansion ?? false,
        isDefault         = sc.Metadata.Annotations != null &&
                            sc.Metadata.Annotations.TryGetValue("storageclass.kubernetes.io/is-default-class", out var v) && v == "true"
    }));
});

// ── ReplicaSets (rollout history) ─────────────────────────────────────────
app.MapGet("/namespaces/{ns}/replicasets", async (string ns) =>
{
    var rss = await WithK8sRetryAsync(c => c.ListNamespacedReplicaSetAsync(ns));
    return Results.Ok(rss.Items.Select(rs => new {
        name       = rs.Metadata.Name,
        deployment = rs.Metadata.OwnerReferences?.FirstOrDefault(o => o.Kind == "Deployment")?.Name,
        replicas   = rs.Spec?.Replicas ?? 0,
        ready      = rs.Status?.ReadyReplicas ?? 0,
        image      = rs.Spec?.Template?.Spec?.Containers?.FirstOrDefault()?.Image,
        createdAt  = rs.Metadata.CreationTimestamp
    }));
});

app.Run();