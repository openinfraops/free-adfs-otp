using System.Net.Http.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient("otp-api", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["OtpApi:BaseUrl"] ?? "https://localhost:7043");

  var adminApiKey = builder.Configuration["OtpApi:AdminApiKey"];
  if (!string.IsNullOrWhiteSpace(adminApiKey))
  {
    client.DefaultRequestHeaders.Add("X-Admin-ApiKey", adminApiKey);
  }
});

var app = builder.Build();

app.MapGet("/", () => Results.Content("""
<!doctype html>
<html lang=\"fr\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" />
  <title>Admin OTP</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 2rem; max-width: 800px; }
    input, button, textarea { padding: .6rem; margin: .3rem 0; width: 100%; }
    .card { border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
  </style>
</head>
<body>
  <h1>Administration OTP</h1>
  <div class=\"card\">
    <h2>Reset methodes OTP</h2>
    <form method=\"post\" action=\"/admin/reset\">
      <input name=\"targetUpn\" placeholder=\"target@contoso.com\" required />
      <input name=\"adminUpn\" placeholder=\"admin@contoso.com\" required />
      <textarea name=\"reason\" placeholder=\"Motif\" required></textarea>
      <button type=\"submit\">Reset</button>
    </form>
  </div>
  <div class=\"card\">
    <h2>Unlock user</h2>
    <form method=\"post\" action=\"/admin/unlock\">
      <input name=\"targetUpn\" placeholder=\"target@contoso.com\" required />
      <input name=\"adminUpn\" placeholder=\"admin@contoso.com\" required />
      <textarea name=\"reason\" placeholder=\"Motif\" required></textarea>
      <button type=\"submit\">Unlock</button>
    </form>
  </div>
</body>
</html>
""", "text/html"));

app.MapPost("/admin/reset", async (HttpContext ctx, IHttpClientFactory factory) =>
{
    var form = await ctx.Request.ReadFormAsync();
    var targetUpn = form["targetUpn"].ToString();
    var adminUpn = form["adminUpn"].ToString();
    var reason = form["reason"].ToString();

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync($"/admin/users/{Uri.EscapeDataString(targetUpn)}/reset-methods", new { adminUpn, reason });
    var payload = await response.Content.ReadAsStringAsync();

    return Results.Content($"<pre>{System.Net.WebUtility.HtmlEncode(payload)}</pre><p><a href='/'>Retour</a></p>", "text/html");
});

app.MapPost("/admin/unlock", async (HttpContext ctx, IHttpClientFactory factory) =>
{
    var form = await ctx.Request.ReadFormAsync();
    var targetUpn = form["targetUpn"].ToString();
    var adminUpn = form["adminUpn"].ToString();
    var reason = form["reason"].ToString();

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync($"/admin/users/{Uri.EscapeDataString(targetUpn)}/unlock", new { adminUpn, reason });
    var payload = await response.Content.ReadAsStringAsync();

    return Results.Content($"<pre>{System.Net.WebUtility.HtmlEncode(payload)}</pre><p><a href='/'>Retour</a></p>", "text/html");
});

app.Run();
