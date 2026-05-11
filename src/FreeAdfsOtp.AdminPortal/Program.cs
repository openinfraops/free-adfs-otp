using System.Net;
using System.Net.Http.Json;
using System.Security.Principal;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Server.IISIntegration;

var builder = WebApplication.CreateBuilder(args);

var isHostedByIis = !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ASPNETCORE_IIS_PHYSICAL_PATH"));
var forceNegotiateHandler = builder.Configuration.GetValue("Authentication:ForceNegotiateHandler", false);

if (isHostedByIis && !forceNegotiateHandler)
{
    builder.Services.AddAuthentication(IISDefaults.AuthenticationScheme);
}
else
{
    builder.Services
        .AddAuthentication(NegotiateDefaults.AuthenticationScheme)
        .AddNegotiate();
}

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("ServerAdminOnly", policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireAssertion(context =>
        {
      if (!OperatingSystem.IsWindows())
      {
        return false;
      }

            var windowsIdentity = context.User?.Identity as WindowsIdentity;
            if (windowsIdentity == null)
            {
                return false;
            }

            var principal = new WindowsPrincipal(windowsIdentity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        });
    });
});

builder.Services.AddAntiforgery(options =>
{
  options.FormFieldName = "__RequestVerificationToken";
  options.Cookie.Name = "__Host-freeadfsotp-admin-csrf";
  options.Cookie.HttpOnly = true;
  options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
  options.Cookie.SameSite = SameSiteMode.Strict;
});

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

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();

var admin = app.MapGroup("/").RequireAuthorization("ServerAdminOnly");

admin.MapGet("/", (HttpContext ctx, IAntiforgery antiforgery) =>
{
  var csrfTokenInput = BuildCsrfHiddenInput(antiforgery, ctx);
    var adminIdentity = WebUtility.HtmlEncode(ctx.User.Identity?.Name ?? "inconnu");
    return Results.Content($$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Console Admin OTP</title>
  <style>
    :root {
      --bg1: #eef3ff;
      --bg2: #f8fbf4;
      --ink: #1f2430;
      --muted: #5f6674;
      --line: #d3dbe6;
      --brand: #2f5ee2;
      --brand2: #1f3d96;
      --danger: #8f1e3e;
      --danger2: #6d112b;
      --card: rgba(255,255,255,.9);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 24px;
      min-height: 100vh;
      color: var(--ink);
      font-family: Bahnschrift, "Segoe UI", sans-serif;
      background: radial-gradient(circle at 10% -30%, #ffffff 0%, transparent 45%),
                  linear-gradient(155deg, var(--bg1), var(--bg2));
    }
    .wrap { max-width: 980px; margin: 0 auto; }
    .hero {
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 18px;
      background: var(--card);
      box-shadow: 0 12px 30px rgba(20,29,38,.08);
      margin-bottom: 16px;
    }
    h1 { margin: 0 0 8px 0; font-size: clamp(1.5rem, 2vw, 2.1rem); }
    .meta { color: var(--muted); margin: 0; }
    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 16px;
    }
    .card {
      grid-column: span 12;
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 16px;
      background: var(--card);
      box-shadow: 0 10px 24px rgba(20,29,38,.06);
    }
    @media (min-width: 920px) {
      .col-6 { grid-column: span 6; }
    }
    h2 { margin-top: 0; font-size: 1.15rem; }
    label { display: block; font-weight: 600; margin: 10px 0 6px; }
    input, textarea {
      width: 100%;
      border: 1px solid #bcc7d8;
      border-radius: 10px;
      padding: 10px 12px;
      font-size: .98rem;
      background: #fff;
    }
    textarea { min-height: 88px; resize: vertical; }
    .readonly {
      background: #f4f7fd;
      color: #3f4652;
    }
    .btn {
      margin-top: 12px;
      border: 0;
      border-radius: 10px;
      padding: 10px 12px;
      color: #fff;
      font-weight: 700;
      cursor: pointer;
      width: 100%;
      background: linear-gradient(135deg, var(--brand), var(--brand2));
    }
    .btn.danger { background: linear-gradient(135deg, var(--danger), var(--danger2)); }
    .hint { color: var(--muted); font-size: .92rem; margin: 8px 0 0; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="hero">
      <h1>Console administration OTP</h1>
      <p class="meta">Accès réservé aux administrateurs locaux du serveur. Session: <strong>{{adminIdentity}}</strong></p>
    </section>

    <section class="grid">
      <article class="card col-6">
        <h2>Réinitialiser les méthodes OTP</h2>
        <form method="post" action="/admin/reset">
          {{csrfTokenInput}}
          <label>UPN cible</label>
          <input name="targetUpn" placeholder="target@domaine" required />
          <label>Administrateur</label>
          <input class="readonly" value="{{adminIdentity}}" readonly />
          <label>Motif</label>
          <textarea name="reason" placeholder="Motif de la réinitialisation" required></textarea>
          <button class="btn danger" type="submit">Réinitialiser</button>
        </form>
        <p class="hint">L’utilisateur devra se ré-enrôler après cette action.</p>
      </article>

      <article class="card col-6">
        <h2>Déverrouiller un compte OTP</h2>
        <form method="post" action="/admin/unlock">
          {{csrfTokenInput}}
          <label>UPN cible</label>
          <input name="targetUpn" placeholder="target@domaine" required />
          <label>Administrateur</label>
          <input class="readonly" value="{{adminIdentity}}" readonly />
          <label>Motif</label>
          <textarea name="reason" placeholder="Motif du déverrouillage" required></textarea>
          <button class="btn" type="submit">Déverrouiller</button>
        </form>
        <p class="hint">Le compteur d’échecs OTP est remis à zéro.</p>
      </article>
    </section>
  </main>
</body>
</html>
""", "text/html");
});

admin.MapPost("/admin/reset", async (HttpContext ctx, IHttpClientFactory factory, IAntiforgery antiforgery) =>
{
  if (!IsSameOriginRequest(ctx))
  {
    return Results.Content(
      RenderActionResultHtml("Requete invalide", "err", "400", "Origin/Referer non autorise."),
      "text/html",
      statusCode: 400);
  }

  if (!await TryValidateCsrfAsync(ctx, antiforgery))
  {
    return Results.Content(
      RenderActionResultHtml("Requete invalide", "err", "400", "CSRF token manquant ou invalide."),
      "text/html",
      statusCode: 400);
  }

    var form = await ctx.Request.ReadFormAsync();
    var targetUpn = form["targetUpn"].ToString().Trim();
    var reason = form["reason"].ToString().Trim();
    var adminUpn = (ctx.User.Identity?.Name ?? "unknown").Trim();

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync($"/admin/users/{Uri.EscapeDataString(targetUpn)}/reset-methods", new { adminUpn, reason });
    var payload = await response.Content.ReadAsStringAsync();

    var statusClass = response.IsSuccessStatusCode ? "ok" : "err";
    return Results.Content(RenderActionResultHtml("Résultat - Reset OTP", statusClass, response.StatusCode.ToString(), payload), "text/html");
});

admin.MapPost("/admin/unlock", async (HttpContext ctx, IHttpClientFactory factory, IAntiforgery antiforgery) =>
{
  if (!IsSameOriginRequest(ctx))
  {
    return Results.Content(
      RenderActionResultHtml("Requete invalide", "err", "400", "Origin/Referer non autorise."),
      "text/html",
      statusCode: 400);
  }

  if (!await TryValidateCsrfAsync(ctx, antiforgery))
  {
    return Results.Content(
      RenderActionResultHtml("Requete invalide", "err", "400", "CSRF token manquant ou invalide."),
      "text/html",
      statusCode: 400);
  }

    var form = await ctx.Request.ReadFormAsync();
    var targetUpn = form["targetUpn"].ToString().Trim();
    var reason = form["reason"].ToString().Trim();
    var adminUpn = (ctx.User.Identity?.Name ?? "unknown").Trim();

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync($"/admin/users/{Uri.EscapeDataString(targetUpn)}/unlock", new { adminUpn, reason });
    var payload = await response.Content.ReadAsStringAsync();

    var statusClass = response.IsSuccessStatusCode ? "ok" : "err";
    return Results.Content(RenderActionResultHtml("Résultat - Unlock OTP", statusClass, response.StatusCode.ToString(), payload), "text/html");
});

app.Run();

static string BuildCsrfHiddenInput(IAntiforgery antiforgery, HttpContext httpContext)
{
  var tokens = antiforgery.GetAndStoreTokens(httpContext);
  if (string.IsNullOrWhiteSpace(tokens.RequestToken))
  {
    return string.Empty;
  }

  var fieldName = WebUtility.HtmlEncode(tokens.FormFieldName);
  var token = WebUtility.HtmlEncode(tokens.RequestToken);
  return $"<input type='hidden' name='{fieldName}' value='{token}' />";
}

static async Task<bool> TryValidateCsrfAsync(HttpContext httpContext, IAntiforgery antiforgery)
{
  try
  {
    await antiforgery.ValidateRequestAsync(httpContext);
    return true;
  }
  catch (AntiforgeryValidationException)
  {
    return false;
  }
}

static bool IsSameOriginRequest(HttpContext httpContext)
{
  var request = httpContext.Request;
  var expectedScheme = request.Scheme;
  var expectedAuthority = request.Host.Value;

  var originHeader = request.Headers.Origin.ToString();
  if (!string.IsNullOrWhiteSpace(originHeader) &&
      TryBuildAuthority(originHeader, out var originScheme, out var originAuthority))
  {
    return originScheme.Equals(expectedScheme, StringComparison.OrdinalIgnoreCase)
           && originAuthority.Equals(expectedAuthority, StringComparison.OrdinalIgnoreCase);
  }

  var refererHeader = request.Headers.Referer.ToString();
  if (!string.IsNullOrWhiteSpace(refererHeader) &&
      TryBuildAuthority(refererHeader, out var refererScheme, out var refererAuthority))
  {
    return refererScheme.Equals(expectedScheme, StringComparison.OrdinalIgnoreCase)
           && refererAuthority.Equals(expectedAuthority, StringComparison.OrdinalIgnoreCase);
  }

  return false;
}

static bool TryBuildAuthority(string rawValue, out string scheme, out string authority)
{
  scheme = string.Empty;
  authority = string.Empty;

  if (!Uri.TryCreate(rawValue, UriKind.Absolute, out var parsed) ||
      string.Equals(parsed.Scheme, "null", StringComparison.OrdinalIgnoreCase))
  {
    return false;
  }

  scheme = parsed.Scheme;
  authority = parsed.IsDefaultPort ? parsed.Host : $"{parsed.Host}:{parsed.Port}";
  return true;
}

static string RenderActionResultHtml(string title, string statusClass, string statusCode, string payload)
{
    var safeTitle = WebUtility.HtmlEncode(title);
    var safeCode = WebUtility.HtmlEncode(statusCode);
    var safePayload = WebUtility.HtmlEncode(payload);

    return $$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>{{safeTitle}}</title>
  <style>
    body { margin: 0; padding: 24px; font-family: Bahnschrift, "Segoe UI", sans-serif; background: #f5f7fc; color: #1f2430; }
    .wrap { max-width: 900px; margin: 0 auto; }
    .card { background: #fff; border: 1px solid #d4dbea; border-radius: 14px; padding: 16px; box-shadow: 0 10px 24px rgba(20,29,38,.07); }
    .pill { display: inline-block; border-radius: 999px; padding: 6px 10px; font-size: .86rem; font-weight: 700; }
    .pill.ok { background: #dff4e8; color: #0f5132; border: 1px solid #a7ddc0; }
    .pill.err { background: #ffe3e8; color: #7a1a2f; border: 1px solid #f0b8c4; }
    pre { background: #f7faff; border: 1px solid #d9e4f2; border-radius: 10px; padding: 12px; white-space: pre-wrap; word-break: break-word; }
    a { display: inline-block; margin-top: 10px; text-decoration: none; color: #fff; background: #2f5ee2; border-radius: 9px; padding: 9px 12px; font-weight: 700; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>{{safeTitle}}</h1>
      <p><span class="pill {{statusClass}}">HTTP {{safeCode}}</span></p>
      <pre>{{safePayload}}</pre>
      <a href="/">Retour à la console</a>
    </section>
  </main>
</body>
</html>
""";
}
