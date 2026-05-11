using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
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
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

builder.Services.AddAntiforgery(options =>
{
  options.FormFieldName = "__RequestVerificationToken";
  options.Cookie.Name = "__Host-freeadfsotp-enroll-csrf";
  options.Cookie.HttpOnly = true;
  options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
  options.Cookie.SameSite = SameSiteMode.Strict;
});

builder.Services.AddHttpClient("otp-api", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["OtpApi:BaseUrl"] ?? "https://localhost:7043");
});

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

app.UseHttpsRedirection();
app.Use(async (ctx, next) =>
{
    ctx.Response.Headers["X-Frame-Options"] = "DENY";
    ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
    ctx.Response.Headers["Referrer-Policy"] = "no-referrer";
    ctx.Response.Headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;";
    await next();
});

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => Results.Redirect("/enroll"));

var enroll = app.MapGroup("/enroll").RequireAuthorization();

enroll.MapGet("", async (HttpContext ctx, IConfiguration config, IHttpClientFactory factory, IAntiforgery antiforgery) =>
{
  var csrfTokenInput = BuildCsrfHiddenInput(antiforgery, ctx);
    var resolve = ResolveUpn(ctx.User, config, null);
    var identityName = Encode(ctx.User.Identity?.Name ?? "inconnu");
    var accountName = Encode(resolve.Upn ?? string.Empty);
  var configuredIdpName = (config["Enrollment:IdpName"] ?? "freeADFSOtp").Trim();
  var configuredPhoneIssuerName = config["Enrollment:PhoneIssuerName"];
  if (string.IsNullOrWhiteSpace(configuredPhoneIssuerName))
  {
    configuredPhoneIssuerName = configuredIdpName;
  }

  var issuerName = Encode(configuredPhoneIssuerName.Trim());

    var isAlreadyEnrolled = false;
    if (resolve.Ok)
    {
        var enrollmentStatus = await GetEnrollmentStatusAsync(factory, resolve.Upn!, ctx.RequestAborted);
        isAlreadyEnrolled = enrollmentStatus.IsEnrolled;
    }

    var status = !resolve.Ok
        ? $"<p class='pill error'>{Encode(resolve.ErrorMessage ?? "Impossible de determiner le compte utilisateur")}</p>"
        : isAlreadyEnrolled
            ? $"<p class='pill info'>Utilisateur detecte: <strong>{Encode(resolve.Upn!)}</strong><br/>Ce compte est deja enrôle pour la MFA OTP.</p>"
            : $"<p class='pill success'>Utilisateur detecte: <strong>{Encode(resolve.Upn!)}</strong></p>";

    var actionsDisabled = (!resolve.Ok || isAlreadyEnrolled) ? "disabled" : string.Empty;
    var enrollmentBody = isAlreadyEnrolled
        ? $$"""
      <article class="card col-12">
        <div class="step">Statut</div>
        <h2>Compte deja enrôle</h2>
        <p class="hint">Vous disposez deja d'une methode OTP active. Aucune nouvelle generation de secret n'est necessaire.</p>
        <p class="hint">Si vous changez de telephone ou perdez l'acces, contactez un administrateur pour reinitialiser vos methodes OTP.</p>
      </article>
"""
        : $$"""
      <article class="card col-7">
        <div class="step">Etape 1</div>
        <h2>Generer le secret OTP</h2>
        <form method="post" action="/enroll/start">
          {{csrfTokenInput}}
          <label>Compte utilisateur</label>
          <input class="readonly" name="userPrincipalName" value="{{accountName}}" readonly />
          <label>Nom de l'emetteur (Issuer)</label>
          <input name="issuerName" value="{{issuerName}}" placeholder="MonEntreprise" />
          <label>Libelle dans l'application mobile</label>
          <input name="accountName" value="{{accountName}}" placeholder="prenom.nom@domaine" />
          <button class="btn" type="submit" {{actionsDisabled}}>Generer le QR code</button>
        </form>
        <p class="hint">Le secret est genere cote serveur puis associe au compte detecte automatiquement.</p>
      </article>

      <article class="card col-5">
        <div class="step">Etape 2</div>
        <h2>Verifier et activer</h2>
        <form method="post" action="/enroll/verify">
          {{csrfTokenInput}}
          <label>Compte utilisateur</label>
          <input class="readonly" name="userPrincipalName" value="{{accountName}}" readonly />
          <label>Code OTP (6 chiffres)</label>
          <input name="code" placeholder="123456" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required />
          <button class="btn alt" type="submit" {{actionsDisabled}}>Valider l'enrollement</button>
        </form>
        <p class="hint">Apres validation, la MFA OTP est activee pour votre compte.</p>
      </article>
""";

    var html = $$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>freeADFSOtp - Enrollement</title>
  <style>
    :root {
      --bg-1: #f8f4ec;
      --bg-2: #e9f4ef;
      --ink: #1f2430;
      --muted: #5e6470;
      --card: rgba(255,255,255,0.82);
      --line: #ced6dc;
      --accent: #0a7f5a;
      --accent-2: #154ec1;
      --danger: #9b1c1c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      color: var(--ink);
      font-family: Bahnschrift, "Segoe UI Variable", "Segoe UI", sans-serif;
      background: radial-gradient(circle at 10% -20%, #fff8eb 0%, transparent 45%),
                  radial-gradient(circle at 100% 0%, #e3f7ec 0%, transparent 35%),
                  linear-gradient(160deg, var(--bg-1), var(--bg-2));
      min-height: 100vh;
      padding: 24px;
    }
    .wrap { max-width: 980px; margin: 0 auto; }
    .hero {
      display: grid;
      gap: 8px;
      padding: 22px;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: linear-gradient(125deg, rgba(255,255,255,0.9), rgba(255,255,255,0.65));
      backdrop-filter: blur(2px);
      box-shadow: 0 16px 42px rgba(20, 29, 38, 0.08);
      animation: rise .45s ease-out;
    }
    h1 { margin: 0; letter-spacing: .4px; font-size: clamp(1.6rem, 2.2vw, 2.3rem); }
    .lead { margin: 0; color: var(--muted); }
    .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
    .chip {
      border: 1px solid #d8dee4;
      border-radius: 999px;
      font-size: .88rem;
      padding: 6px 12px;
      background: rgba(255,255,255,.8);
    }
    .pill {
      padding: 10px 12px;
      border-radius: 10px;
      border: 1px solid;
      font-size: .95rem;
      margin: 14px 0 0 0;
    }
  .pill.success { color: #0f5132; background: #d1f4e4; border-color: #90d9bd; }
  .pill.info { color: #084469; background: #d9efff; border-color: #99cbeb; }
  .pill.error { color: #6b1523; background: #ffe6ea; border-color: #f3b9c3; }
    .grid {
      margin-top: 16px;
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 16px;
    }
    .card {
      grid-column: span 12;
      border-radius: 16px;
      border: 1px solid var(--line);
      background: var(--card);
      padding: 18px;
      box-shadow: 0 10px 24px rgba(20, 29, 38, 0.06);
      animation: rise .6s ease-out;
    }
    @media (min-width: 900px) {
      .col-7 { grid-column: span 7; }
      .col-5 { grid-column: span 5; }
    }
    h2 { margin: 0 0 8px 0; font-size: 1.2rem; }
    .step { color: var(--accent-2); font-size: .86rem; text-transform: uppercase; letter-spacing: .12em; }
    label { display: block; font-weight: 600; margin: 10px 0 5px; }
    input {
      width: 100%;
      padding: 11px 12px;
      border-radius: 10px;
      border: 1px solid #bdc7d2;
      font-size: 1rem;
      transition: border-color .18s ease, box-shadow .18s ease;
      background: #fff;
    }
    input:focus {
      border-color: var(--accent-2);
      box-shadow: 0 0 0 4px rgba(21,78,193,.14);
      outline: none;
    }
    .readonly { color: #313641; background: #f5f8fb; }
    .btn {
      margin-top: 14px;
      border: 0;
      border-radius: 11px;
      padding: 11px 14px;
      width: 100%;
      font-size: .99rem;
      font-weight: 700;
      cursor: pointer;
      color: #fff;
      background: linear-gradient(135deg, var(--accent), #0c5d42);
    }
    .btn.alt { background: linear-gradient(135deg, var(--accent-2), #1e3f8d); }
    .hint { margin-top: 10px; color: var(--muted); font-size: .92rem; }
    .list { margin: 0; padding-left: 18px; color: var(--muted); }
    .list li { margin-bottom: 6px; }
    @keyframes rise {
      from { opacity: .25; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="hero">
      <h1>Enrollement OTP</h1>
      <p class="lead">Portail securise avec identification par authentification Windows integree.</p>
      <div class="meta">
        <span class="chip">Session: {{identityName}}</span>
      </div>
      {{status}}
    </section>

    <section class="grid">
      {{enrollmentBody}}
    </section>
  </main>
</body>
</html>
""";

    return Results.Content(html, "text/html");
});

enroll.MapPost("/start", async (HttpContext ctx, IHttpClientFactory factory, IConfiguration config, IAntiforgery antiforgery, ILogger<Program> logger) =>
{
  var originCheck = EvaluateSameOriginRequest(ctx);
  if (!originCheck.IsAllowed)
  {
    LogSameOriginRejection(logger, ctx, originCheck.Reason);
    return Results.Content(RenderError("Requete invalide (origin/referrer non autorise)."), "text/html", Encoding.UTF8, 400);
  }

  LogSameOriginFallback(logger, ctx, originCheck.Reason);

  if (!await TryValidateCsrfAsync(ctx, antiforgery))
  {
    return Results.Content(RenderError("Requete invalide (CSRF token manquant ou incorrect)."), "text/html", Encoding.UTF8, 400);
  }

    var form = await ctx.Request.ReadFormAsync();
    var resolve = ResolveUpn(ctx.User, config, form["userPrincipalName"].ToString());
    if (!resolve.Ok)
    {
        return Results.Content(RenderError(resolve.ErrorMessage ?? "Impossible de resoudre le compte utilisateur"), "text/html", Encoding.UTF8, 400);
    }

    var upn = resolve.Upn!;
    var idpName = (config["Enrollment:IdpName"] ?? "freeADFSOtp").Trim();
    var postedIssuerName = form["issuerName"].ToString();
    var phoneIssuerName = string.IsNullOrWhiteSpace(postedIssuerName)
        ? config["Enrollment:PhoneIssuerName"]
        : postedIssuerName;
    if (string.IsNullOrWhiteSpace(phoneIssuerName))
    {
        phoneIssuerName = idpName;
    }

    phoneIssuerName = phoneIssuerName.Trim();
    var accountName = form["accountName"].ToString();
    if (string.IsNullOrWhiteSpace(accountName))
    {
        accountName = upn;
    }

    var client = factory.CreateClient("otp-api");
  var response = await client.PostAsJsonAsync("/enrollment/start", new { userPrincipalName = upn, idpName, issuerName = phoneIssuerName, accountName });
    var payload = await response.Content.ReadAsStringAsync();

    if (!response.IsSuccessStatusCode)
    {
        return Results.Content(RenderError(payload), "text/html", Encoding.UTF8, (int)response.StatusCode);
    }

    using var document = JsonDocument.Parse(payload);
    var root = document.RootElement;
    var responseUpn = ReadJsonString(root, "userPrincipalName", upn);
    var responseIssuer = ReadJsonString(root, "issuerName", phoneIssuerName);
    var responsePhoneLabel = ReadJsonString(root, "phoneLabel", accountName);
    var responseSecretBase32 = ReadJsonString(root, "secretBase32", string.Empty);
    var responseOtpAuthUri = ReadJsonString(root, "otpAuthUri", string.Empty);
    var qrCodePngBase64 = ReadJsonString(root, "qrCodePngBase64", string.Empty);

    if (string.IsNullOrWhiteSpace(qrCodePngBase64))
    {
      return Results.Content(RenderError("Reponse API invalide: QR code introuvable dans la reponse enrollment/start."), "text/html", Encoding.UTF8, 502);
    }

    var html = $$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>QR OTP genere</title>
  <style>
    body { margin: 0; background: #f1f7f4; color: #1f2430; font-family: Bahnschrift, "Segoe UI", sans-serif; padding: 24px; }
    .wrap { max-width: 760px; margin: 0 auto; }
    .card { border: 1px solid #c7d7ce; border-radius: 16px; padding: 18px; background: #fff; box-shadow: 0 12px 30px rgba(23, 36, 44, .08); }
    h1 { margin-top: 0; }
    .mono { font-family: Consolas, "Courier New", monospace; font-size: .92rem; word-break: break-all; }
    .qr { margin: 12px 0; border: 8px solid #fff; box-shadow: 0 10px 24px rgba(23,36,44,.12); width: min(320px, 100%); }
    .actions { margin-top: 14px; display: flex; gap: 10px; flex-wrap: wrap; }
    a { display: inline-block; text-decoration: none; color: #fff; background: #0a7f5a; border-radius: 10px; padding: 10px 14px; font-weight: 700; }
    .secondary { background: #154ec1; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>Secret OTP genere</h1>
      <p><strong>UPN:</strong> {{Encode(responseUpn)}}</p>
  <p><strong>Issuer mobile:</strong> {{Encode(responseIssuer)}}</p>
      <p><strong>Libelle mobile:</strong> {{Encode(responsePhoneLabel)}}</p>
      <p><strong>Secret Base32:</strong><br /><span class="mono">{{Encode(responseSecretBase32)}}</span></p>
      <p><strong>URI otpAuth:</strong><br /><span class="mono">{{Encode(responseOtpAuthUri)}}</span></p>
      <img class="qr" alt="QR OTP" src="data:image/png;base64,{{Encode(qrCodePngBase64)}}" />
      <p>Scannez le QR code puis revenez sur le portail pour valider le premier code OTP.</p>
      <div class="actions">
        <a href="/enroll">Saisir le code OTP</a>
        <a class="secondary" href="/enroll">Retour au portail</a>
      </div>
    </section>
  </main>
</body>
</html>
""";

    return Results.Content(html, "text/html", Encoding.UTF8);
});

enroll.MapPost("/verify", async (HttpContext ctx, IHttpClientFactory factory, IConfiguration config, IAntiforgery antiforgery, ILogger<Program> logger) =>
{
  var originCheck = EvaluateSameOriginRequest(ctx);
  if (!originCheck.IsAllowed)
  {
    LogSameOriginRejection(logger, ctx, originCheck.Reason);
    return Results.Content(RenderError("Requete invalide (origin/referrer non autorise)."), "text/html", Encoding.UTF8, 400);
  }

  LogSameOriginFallback(logger, ctx, originCheck.Reason);

  if (!await TryValidateCsrfAsync(ctx, antiforgery))
  {
    return Results.Content(RenderError("Requete invalide (CSRF token manquant ou incorrect)."), "text/html", Encoding.UTF8, 400);
  }

    var form = await ctx.Request.ReadFormAsync();
    var resolve = ResolveUpn(ctx.User, config, form["userPrincipalName"].ToString());
    if (!resolve.Ok)
    {
        return Results.Content(RenderError(resolve.ErrorMessage ?? "Impossible de resoudre le compte utilisateur"), "text/html", Encoding.UTF8, 400);
    }

    var upn = resolve.Upn!;
    var code = form["code"].ToString();

    if (string.IsNullOrWhiteSpace(code) || code.Length < 6 || code.Length > 8 || !code.All(char.IsDigit))
    {
        return Results.Content(RenderError("Le code OTP doit contenir entre 6 et 8 chiffres."), "text/html", Encoding.UTF8, 400);
    }

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync("/enrollment/verify", new { userPrincipalName = upn, code });
    var payload = await response.Content.ReadAsStringAsync();

    if (!response.IsSuccessStatusCode)
    {
        return Results.Content(RenderError(payload), "text/html", Encoding.UTF8, (int)response.StatusCode);
    }

    var html = $$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Enrollement valide</title>
  <style>
    body { margin: 0; background: #f2f8ff; color: #1f2430; font-family: Bahnschrift, "Segoe UI", sans-serif; padding: 24px; }
    .wrap { max-width: 760px; margin: 0 auto; }
    .card { border: 1px solid #bfd2ea; border-radius: 16px; padding: 18px; background: #fff; box-shadow: 0 12px 30px rgba(23, 36, 44, .08); }
    .ok { color: #0f5132; background: #d1f4e4; border: 1px solid #90d9bd; border-radius: 10px; padding: 12px; }
    pre { background: #f5f9ff; border: 1px solid #d3dfed; padding: 10px; border-radius: 8px; white-space: pre-wrap; word-break: break-word; }
    a { display: inline-block; margin-top: 12px; text-decoration: none; color: #fff; background: #154ec1; border-radius: 10px; padding: 10px 14px; font-weight: 700; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>Enrollement OTP valide</h1>
      <p class="ok">Le compte {{Encode(upn)}} est maintenant enregistre pour la MFA OTP.</p>
      <pre>{{Encode(payload)}}</pre>
      <a href="/enroll">Retour au portail</a>
    </section>
  </main>
</body>
</html>
""";

    return Results.Content(html, "text/html", Encoding.UTF8);
});

app.Run();

static string BuildCsrfHiddenInput(IAntiforgery antiforgery, HttpContext httpContext)
{
  var tokens = antiforgery.GetAndStoreTokens(httpContext);
  if (string.IsNullOrWhiteSpace(tokens.RequestToken))
  {
    return string.Empty;
  }

  var fieldName = Encode(tokens.FormFieldName);
  var token = Encode(tokens.RequestToken);
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

static (bool IsAllowed, string Reason) EvaluateSameOriginRequest(HttpContext httpContext)
{
  var request = httpContext.Request;
  var expectedScheme = GetFirstForwardedValue(request.Headers["X-Forwarded-Proto"].ToString()) ?? request.Scheme;
  var expectedAuthority = GetFirstForwardedValue(request.Headers["X-Forwarded-Host"].ToString()) ?? request.Host.Value;
  var fetchSite = request.Headers["Sec-Fetch-Site"].ToString();
  if (fetchSite.Equals("cross-site", StringComparison.OrdinalIgnoreCase))
  {
    return (false, "sec-fetch-site-cross-site");
  }

  if (fetchSite.Equals("same-origin", StringComparison.OrdinalIgnoreCase))
  {
    return (true, "sec-fetch-site-same-origin");
  }

  var originHeader = request.Headers.Origin.ToString();
  if (string.Equals(originHeader, "null", StringComparison.OrdinalIgnoreCase))
  {
    originHeader = string.Empty;
  }

  var refererHeader = request.Headers.Referer.ToString();

  if (string.IsNullOrWhiteSpace(originHeader) && string.IsNullOrWhiteSpace(refererHeader))
  {
    // Some clients/proxies omit both headers (e.g., strict referrer policies).
    // In this case we rely on anti-forgery token validation already enforced on POST handlers.
    return (true, "origin-referer-missing");
  }

  if (!string.IsNullOrWhiteSpace(originHeader) &&
      TryBuildAuthority(originHeader, out var originScheme, out var originAuthority))
  {
    var originMatch = originScheme.Equals(expectedScheme, StringComparison.OrdinalIgnoreCase)
                      && originAuthority.Equals(expectedAuthority, StringComparison.OrdinalIgnoreCase);
    return originMatch
      ? (true, "origin-match")
      : (false, "origin-mismatch");
  }

  if (!string.IsNullOrWhiteSpace(refererHeader) &&
      TryBuildAuthority(refererHeader, out var refererScheme, out var refererAuthority))
  {
    var refererMatch = refererScheme.Equals(expectedScheme, StringComparison.OrdinalIgnoreCase)
                       && refererAuthority.Equals(expectedAuthority, StringComparison.OrdinalIgnoreCase);
    return refererMatch
      ? (true, "referer-match")
      : (false, "referer-mismatch");
  }

  return (false, "origin-referer-unusable");
}

static void LogSameOriginFallback(ILogger logger, HttpContext httpContext, string reason)
{
  if (!reason.Equals("origin-referer-missing", StringComparison.OrdinalIgnoreCase))
  {
    return;
  }

  logger.LogInformation(
    "Same-origin guard fallback: Origin/Referer missing, relying on CSRF token. Path={Path}, SecFetchSite={SecFetchSite}",
    httpContext.Request.Path,
    httpContext.Request.Headers["Sec-Fetch-Site"].ToString());
}

static void LogSameOriginRejection(ILogger logger, HttpContext httpContext, string reason)
{
  logger.LogWarning(
    "Rejected same-origin check. Reason={Reason}, Path={Path}, Origin={Origin}, Referer={Referer}, SecFetchSite={SecFetchSite}, ForwardedHost={ForwardedHost}, ForwardedProto={ForwardedProto}, Host={Host}, Scheme={Scheme}",
    reason,
    httpContext.Request.Path,
    httpContext.Request.Headers.Origin.ToString(),
    httpContext.Request.Headers.Referer.ToString(),
    httpContext.Request.Headers["Sec-Fetch-Site"].ToString(),
    httpContext.Request.Headers["X-Forwarded-Host"].ToString(),
    httpContext.Request.Headers["X-Forwarded-Proto"].ToString(),
    httpContext.Request.Host.Value,
    httpContext.Request.Scheme);
}

static string? GetFirstForwardedValue(string? headerValue)
{
  if (string.IsNullOrWhiteSpace(headerValue))
  {
    return null;
  }

  var first = headerValue.Split(',', StringSplitOptions.RemoveEmptyEntries)
    .Select(value => value.Trim())
    .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

  return string.IsNullOrWhiteSpace(first) ? null : first;
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

static string ReadJsonString(JsonElement root, string propertyName, string fallback)
{
  if (root.ValueKind == JsonValueKind.Object &&
      root.TryGetProperty(propertyName, out var propertyValue) &&
      propertyValue.ValueKind != JsonValueKind.Null &&
      propertyValue.ValueKind != JsonValueKind.Undefined)
  {
    return propertyValue.GetString() ?? fallback;
  }

  return fallback;
}

static async Task<(bool IsEnrolled, bool IsActive)> GetEnrollmentStatusAsync(IHttpClientFactory factory, string upn, CancellationToken ct)
{
  var client = factory.CreateClient("otp-api");
  var response = await client.GetAsync($"/otp/enrollment-status/{Uri.EscapeDataString(upn)}", ct);
  if (!response.IsSuccessStatusCode)
  {
    return (false, false);
  }

  var payload = await response.Content.ReadAsStringAsync(ct);
  using var document = JsonDocument.Parse(payload);
  var root = document.RootElement;

  var isEnrolled = root.TryGetProperty("isEnrolled", out var enrolledElement)
    && enrolledElement.ValueKind == JsonValueKind.True;

  var isActive = root.TryGetProperty("isActive", out var activeElement)
    && activeElement.ValueKind == JsonValueKind.True;

  return (isEnrolled, isActive);
}

static string Encode(string? value) => WebUtility.HtmlEncode(value ?? string.Empty);

static (bool Ok, string? Upn, string? ErrorMessage) ResolveUpn(ClaimsPrincipal user, IConfiguration config, string? postedUpn)
{
    if (user?.Identity?.IsAuthenticated != true)
    {
        return (false, null, "Vous devez etre authentifie via Windows Integrated Authentication.");
    }

    var allowManualUpn = config.GetValue("Enrollment:AllowManualUpn", false);
    var allowedWindowsDomain = config["Enrollment:AllowedWindowsDomain"];
    var defaultUpnSuffix = config["Enrollment:DefaultUpnSuffix"];

    if (allowManualUpn && !string.IsNullOrWhiteSpace(postedUpn))
    {
        return (true, postedUpn.Trim(), null);
    }

    var upnClaim = user.Claims.FirstOrDefault(c =>
        c.Type == ClaimTypes.Upn ||
        c.Type == "upn" ||
        c.Type == ClaimTypes.Email)?.Value;

    if (!string.IsNullOrWhiteSpace(upnClaim))
    {
        return (true, upnClaim.Trim(), null);
    }

    var identityName = user.Identity?.Name?.Trim();
    if (string.IsNullOrWhiteSpace(identityName))
    {
        return (false, null, "Aucune identite Windows disponible dans la session.");
    }

    if (identityName.Contains("@", StringComparison.Ordinal))
    {
        return (true, identityName, null);
    }

    var parts = identityName.Split('\\', 2, StringSplitOptions.RemoveEmptyEntries);
    if (parts.Length != 2)
    {
        return (false, null, "Format d'identite Windows non reconnu. Attendu: DOMAINE\\utilisateur ou UPN.");
    }

    var windowsDomain = parts[0];
    var samAccountName = parts[1];

    if (!string.IsNullOrWhiteSpace(allowedWindowsDomain) && !windowsDomain.Equals(allowedWindowsDomain, StringComparison.OrdinalIgnoreCase))
    {
        return (false, null, "Le domaine Windows de la session n'est pas autorise.");
    }

    if (string.IsNullOrWhiteSpace(defaultUpnSuffix))
    {
        return (false, null, "Impossible de construire un UPN depuis l'identite Windows: configurez Enrollment:DefaultUpnSuffix.");
    }

    return (true, $"{samAccountName}@{defaultUpnSuffix}", null);
}

static string RenderError(string rawMessage)
{
    var safe = Encode(rawMessage);
    return $$"""
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Erreur enrollement</title>
  <style>
    body { margin: 0; background: #fff4f4; color: #2b2020; font-family: Bahnschrift, "Segoe UI", sans-serif; padding: 24px; }
    .wrap { max-width: 760px; margin: 0 auto; }
    .card { border: 1px solid #efb7b7; border-radius: 14px; padding: 16px; background: #fff; }
    pre { background: #fff8f8; border: 1px solid #f3d2d2; border-radius: 8px; padding: 10px; white-space: pre-wrap; word-break: break-word; }
    a { display: inline-block; margin-top: 12px; color: #fff; text-decoration: none; background: #9b1c1c; padding: 10px 14px; border-radius: 9px; font-weight: 700; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>Echec de l'operation</h1>
      <pre>{{safe}}</pre>
      <a href="/enroll">Retour au portail</a>
    </section>
  </main>
</body>
</html>
""";
}
