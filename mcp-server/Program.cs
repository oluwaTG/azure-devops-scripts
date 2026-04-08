using System;
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

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/cluster/info", async () =>
{
    var nodes = await k8s.ListNodeAsync();
    var ver = await k8s.GetCodeAsync();
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
    var ns = await k8s.ListNamespaceAsync();
    return Results.Ok(ns.Items.Select(n => n.Metadata.Name));
});

app.MapGet("/namespaces/{ns}/pods", async (string ns) =>
{
    var pods = await k8s.ListNamespacedPodAsync(ns);
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
    var evts = await k8s.CoreV1.ListNamespacedEventAsync(ns, fieldSelector: fieldSelector);
    return Results.Ok(evts.Items.Select(e => new { e.Metadata.CreationTimestamp, e.Reason, e.Message, e.Type }));
});


app.MapGet("/namespaces/{ns}/pods/{pod}/logs", async (string ns, string pod, int? tail = 200) =>
{
    using var logStream = await k8s.ReadNamespacedPodLogAsync(pod, ns, tailLines: tail);
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
    var pods = await k8s.ListNamespacedPodAsync(ns, labelSelector: $"app={name}");
    if (pods.Items.Count == 0)
    {
        // fallback: try pods with name prefix
        pods = await k8s.ListNamespacedPodAsync(ns, fieldSelector: $"metadata.name={name}");
    }

    var result = new List<object>();
    foreach (var p in pods.Items)
    {
        var podName = p.Metadata.Name;
        var evtSel = $"involvedObject.name={podName},involvedObject.namespace={ns}";
        var evts = await k8s.CoreV1.ListNamespacedEventAsync(ns, fieldSelector: evtSel);
        string lastLogText = string.Empty;
        using (var lastLogStream = await k8s.ReadNamespacedPodLogAsync(podName, ns, tailLines: 200))
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

app.Run();
