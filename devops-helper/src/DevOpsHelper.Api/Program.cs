using Prometheus;

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
// Metrics
// --------------------
app.MapMetrics();

// --------------------
app.Run();
