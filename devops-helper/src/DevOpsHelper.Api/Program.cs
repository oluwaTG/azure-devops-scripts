using Prometheus;
using System.Collections.Concurrent;
using System.Threading;

var builder = WebApplication.CreateBuilder(args);

// --------------------
// Services
// --------------------
builder.Services.AddHealthChecks();

// Prometheus
builder.Services.AddSingleton<IMetricServer>(_ =>
    new KestrelMetricServer(port: 9090));

var app = builder.Build();

// --------------------
// Prometheus metrics
// --------------------
var counter = Metrics.CreateCounter(
    "devops_helper_requests_total",
    "Total HTTP requests",
    new CounterConfiguration
    {
        LabelNames = new[] { "method", "endpoint", "status" }
    });

app.Use(async (ctx, next) =>
{
    await next();
    counter
        .WithLabels(ctx.Request.Method, ctx.Request.Path, ctx.Response.StatusCode.ToString())
        .Inc();
});

// --------------------
// Simple in-memory "backend" store
// --------------------
var items = new ConcurrentDictionary<int, Item>();
var idCounter = 0;
items.TryAdd(Interlocked.Increment(ref idCounter), new Item(1, "Sample item 1"));
items.TryAdd(Interlocked.Increment(ref idCounter), new Item(2, "Sample item 2"));

// --------------------
// Homepage and status
// --------------------
app.MapGet("/", () =>
        Results.Content(@"
                <html>
                    <head><title>devops-helper</title></head>
                    <body>
                        <h1>devops-helper</h1>
                        <p>A small helper app for DevOps demos.</p>
                        <ul>
                            <li><a href=""/status"">Status</a></li>
                            <li><a href=""/info"">Info</a></li>
                            <li><a href=""/api/items"">Items API</a></li>
                            <li><a href=""/health/ready"">Readiness</a></li>
                            <li><a href=""/health/live"">Liveness</a></li>
                            <li><a href=""/metrics"">Metrics</a></li>
                        </ul>
                    </body>
                </html>", "text/html"));

app.MapGet("/status", () =>
    Results.Ok(new { service = "devops-helper", status = "running", timestamp = DateTime.UtcNow }));

// --------------------
// Health
// --------------------
app.MapGet("/health/live", () => Results.Ok("Alive"));

app.MapGet("/health/ready", () =>
{
    var ready = Environment.GetEnvironmentVariable("APP_READY") != "false";
    return ready ? Results.Ok("Ready") : Results.StatusCode(503);
});

// --------------------
// Info
// --------------------
app.MapGet("/info", () => Results.Ok(new
{
    Application = "devops-helper",
    Version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "local",
    Environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT"),
    Pod = Environment.GetEnvironmentVariable("HOSTNAME"),
    Node = Environment.GetEnvironmentVariable("NODE_NAME")
}));

// --------------------
// Config inspection
// --------------------
app.MapGet("/config", () =>
{
    var env = Environment.GetEnvironmentVariables()
        .Cast<System.Collections.DictionaryEntry>()
        .Where(e => !e.Key.ToString()!.Contains("SECRET"))
        .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString());

    return Results.Ok(env);
});

// --------------------
// Chaos endpoints
// --------------------
app.MapGet("/chaos/error", (int code) =>
{
    return Results.StatusCode(code);
});

app.MapGet("/chaos/timeout", async (int seconds) =>
{
    await Task.Delay(TimeSpan.FromSeconds(seconds));
    return Results.Ok($"Waited {seconds}s");
});

app.MapGet("/chaos/crash", () =>
{
    Environment.FailFast("Chaos crash triggered");
    return Results.Ok();
});

// --------------------
// Catastrophe endpoints (explicit status codes for testing)
// --------------------
app.MapGet("/catastrophe/500", () => Results.StatusCode(500));
app.MapGet("/catastrophe/503", () => Results.StatusCode(503));
app.MapGet("/catastrophe/592", () => Results.StatusCode(592));
app.MapGet("/catastrophe/404", () => Results.NotFound(new { error = "Catastrophe: not found" }));
// Generic route to return any status code (useful for testing)
app.MapGet("/catastrophe/{code:int}", (int code) => Results.StatusCode(code));

// --------------------
// Load testing
// --------------------
app.MapGet("/load/cpu", async (int seconds) =>
{
    var end = DateTime.UtcNow.AddSeconds(seconds);
    while (DateTime.UtcNow < end)
    {
        _ = Math.Sqrt(Random.Shared.NextDouble());
    }
    return Results.Ok($"CPU load for {seconds}s");
});

app.MapGet("/load/memory", (int mb) =>
{
    var data = new byte[mb * 1024 * 1024];
    GC.KeepAlive(data);
    return Results.Ok($"Allocated {mb}MB");
});

// --------------------
// Simulated backend endpoints
// --------------------
app.MapGet("/api/items", () => Results.Ok(items.Values));

app.MapGet("/api/items/{id:int}", (int id) =>
    items.TryGetValue(id, out var it) ? Results.Ok(it) : Results.NotFound(new { error = "Not found" }));

app.MapPost("/api/items", (ItemCreate req) =>
{
    var id = Interlocked.Increment(ref idCounter);
    var item = new Item(id, req.Name);
    items[id] = item;
    return Results.Created($"/api/items/{id}", item);
});

app.MapPut("/api/items/{id:int}", (int id, ItemCreate req) =>
{
    if (!items.ContainsKey(id)) return Results.NotFound(new { error = "Not found" });
    var updated = new Item(id, req.Name);
    items[id] = updated;
    return Results.Ok(updated);
});

app.MapDelete("/api/items/{id:int}", (int id) =>
    items.TryRemove(id, out _) ? Results.Ok(new { deleted = id }) : Results.NotFound(new { error = "Not found" }));

// Simulate a delayed backend call
app.MapGet("/api/delay/{seconds:int}", async (int seconds) =>
{
    await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(seconds, 0, 30)));
    return Results.Ok(new { waited = seconds });
});

// Simulate auth-protected endpoint (simple header check)
app.MapGet("/api/secure", (HttpContext ctx) =>
{
    if (ctx.Request.Headers.TryGetValue("X-Api-Key", out var key) && key == "secret") return Results.Ok(new { authorized = true });
    return Results.StatusCode(401);
});

// --------------------
// Metrics
// --------------------
app.MapMetrics();

// --------------------
app.Run();

// --------------------
// Local types
// --------------------
record Item(int Id, string Name);
record ItemCreate(string Name);
