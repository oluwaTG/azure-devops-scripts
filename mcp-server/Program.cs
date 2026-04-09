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
    return Results.Ok(pods.Items.Select(p => new {
        name = p.Metadata.Name,
        phase = p.Status?.Phase,
        ready = p.Status?.ContainerStatuses?.All(s => s.Ready) ?? false,
        restarts = p.Status?.ContainerStatuses?.Sum(s => s.RestartCount) ?? 0
    }));
});


app.MapGet("/namespaces/{ns}/pods/{pod}/events", async (string ns, string pod) =>
{
    var fieldSelector = $"involvedObject.name={pod},involvedObject.namespace={ns}";
    var evts = await WithK8sRetryAsync(c => c.CoreV1.ListNamespacedEventAsync(ns, fieldSelector: fieldSelector));
    return Results.Ok(evts.Items.Select(e => new { e.Metadata.CreationTimestamp, e.Reason, e.Message, e.Type }));
});


app.MapGet("/namespaces/{ns}/pods/{pod}/logs", async (string ns, string pod, int? tail = 200) =>
{
    using var logStream = await WithK8sRetryAsync(c => c.ReadNamespacedPodLogAsync(pod, ns, tailLines: tail));
    string logText = string.Empty;
    if (logStream != null)
    {
        using var reader = new StreamReader(logStream);
        logText = await reader.ReadToEndAsync();
    }
    return Results.Text(logText, "text/plain");
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
        result.Add(new {
            pod = podName,
            phase = p.Status?.Phase,
            ready = p.Status?.ContainerStatuses?.All(s => s.Ready) ?? false,
            restarts = p.Status?.ContainerStatuses?.Sum(s => s.RestartCount) ?? 0,
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

// Homepage — static HTML dashboard
app.MapGet("/", async context =>
{
    var nodes = await WithK8sRetryAsync(c => c.ListNodeAsync());
    var nsList = await WithK8sRetryAsync(c => c.ListNamespaceAsync());
    var podCount = 0;
    foreach (var ns in nsList.Items.Select(n => n.Metadata.Name))
    {
        var pods = await WithK8sRetryAsync(c => c.ListNamespacedPodAsync(ns));
        podCount += pods.Items.Count;
    }
    var html = $@"<!DOCTYPE html>
<html lang='en'>
<head>
    <meta charset='UTF-8'>
    <meta name='viewport' content='width=device-width, initial-scale=1.0'>
    <title>MCP Server Dashboard</title>
    <style>
        body {{ font-family: 'Segoe UI', Arial, sans-serif; background: #181c24; color: #f3f6fa; margin: 0; }}
        .header {{ background: #232946; padding: 1.5rem 2rem; display: flex; align-items: center; justify-content: space-between; }}
        .header h1 {{ margin: 0; font-size: 2rem; color: #f3f6fa; }}
        .nav {{ display: flex; gap: 1.5rem; }}
        .nav a {{ color: #eebf3f; text-decoration: none; font-weight: 500; }}
        .nav a:hover {{ text-decoration: underline; }}
        .main {{ max-width: 900px; margin: 2rem auto; background: #232946; border-radius: 12px; box-shadow: 0 2px 12px #0002; padding: 2rem; }}
        .summary {{ display: flex; gap: 2rem; margin-bottom: 2rem; }}
        .card {{ background: #2a2d3a; border-radius: 8px; padding: 1.5rem; flex: 1; text-align: center; }}
        .card h2 {{ margin: 0 0 0.5rem 0; font-size: 2.2rem; color: #eebf3f; }}
        .card p {{ margin: 0; color: #b8bccc; }}
        .footer {{ text-align: center; color: #b8bccc; margin: 2rem 0 0 0; font-size: 0.95rem; }}
    </style>
</head>
<body>
    <div class='header'>
        <h1>&#9096; MCP Server</h1>
        <nav class='nav'>
            <a href='/'>Dashboard</a>
            <a href='/metrics/nodes'>Node Metrics</a>
            <a href='/metrics/pods'>Pod Metrics</a>
            <a href='/namespaces'>Namespaces</a>
            <a href='/cluster/info'>Cluster Info</a>
            <a href='https://github.com/oluwaTG/azure-devops-scripts' target='_blank'>GitHub</a>
        </nav>
    </div>
    <div class='main'>
        <div class='summary'>
            <div class='card'><h2>{nodes.Items.Count}</h2><p>Nodes</p></div>
            <div class='card'><h2>{nsList.Items.Count}</h2><p>Namespaces</p></div>
            <div class='card'><h2>{podCount}</h2><p>Pods</p></div>
        </div>
        <h2 style='color:#eebf3f;'>Welcome to MCP Server</h2>
        <p>This dashboard provides a unified view of your Kubernetes cluster(s). Use the navigation above to explore metrics, namespaces, and more.</p>
        <p><b>Multi-cluster support and authentication coming soon.</b></p>
    </div>
    <div class='footer'>MCP Server &copy; 2026</div>
</body>
</html>";
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

app.Run();