using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
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

enroll.MapGet("", (HttpContext ctx, IConfiguration config) =>
{
    var resolve = ResolveUpn(ctx.User, config, null);
    var identityName = Encode(ctx.User.Identity?.Name ?? "inconnu");
    var idpName = Encode(config["Enrollment:IdpName"] ?? "freeADFSOtp");
    var accountName = Encode(resolve.Upn ?? string.Empty);

    var status = resolve.Ok
        ? $"<p class='pill success'>Utilisateur detecte: <strong>{Encode(resolve.Upn!)}</strong></p>"
        : $"<p class='pill error'>{Encode(resolve.ErrorMessage ?? "Impossible de determiner le compte utilisateur")}</p>";

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
        <span class="chip">IDP: {{idpName}}</span>
      </div>
      {{status}}
    </section>

    <section class="grid">
      <article class="card col-7">
        <div class="step">Etape 1</div>
        <h2>Generer le secret OTP</h2>
        <form method="post" action="/enroll/start">
          <label>Compte utilisateur</label>
          <input class="readonly" name="userPrincipalName" value="{{accountName}}" readonly />
          <label>Libelle dans l'application mobile</label>
          <input name="accountName" value="{{accountName}}" placeholder="prenom.nom@domaine" />
          <button class="btn" type="submit" {{(resolve.Ok ? string.Empty : "disabled")}}>Generer le QR code</button>
        </form>
        <p class="hint">Le secret est genere cote serveur puis associe au compte detecte automatiquement.</p>
      </article>

      <article class="card col-5">
        <div class="step">Etape 2</div>
        <h2>Verifier et activer</h2>
        <form method="post" action="/enroll/verify">
          <label>Compte utilisateur</label>
          <input class="readonly" name="userPrincipalName" value="{{accountName}}" readonly />
          <label>Code OTP (6 chiffres)</label>
          <input name="code" placeholder="123456" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required />
          <button class="btn alt" type="submit" {{(resolve.Ok ? string.Empty : "disabled")}}>Valider l'enrollement</button>
        </form>
        <p class="hint">Apres validation, la MFA OTP est activee pour votre compte.</p>
      </article>

      <article class="card col-12">
        <div class="step">Securite</div>
        <h2>Protections actives</h2>
        <ul class="list">
          <li>Authentification Windows integree obligatoire pour acceder au portail.</li>
          <li>Utilisateur cible derive de l'identite Windows et non d'une saisie libre.</li>
          <li>Entetes HTTP de durcissement: HSTS, CSP, X-Frame-Options, X-Content-Type-Options.</li>
        </ul>
      </article>
    </section>
  </main>
</body>
</html>
""";

    return Results.Content(html, "text/html");
});

enroll.MapPost("/start", async (HttpContext ctx, IHttpClientFactory factory, IConfiguration config) =>
{
    var form = await ctx.Request.ReadFormAsync();
    var resolve = ResolveUpn(ctx.User, config, form["userPrincipalName"].ToString());
    if (!resolve.Ok)
    {
        return Results.Content(RenderError(resolve.ErrorMessage ?? "Impossible de resoudre le compte utilisateur"), "text/html", Encoding.UTF8, 400);
    }

    var upn = resolve.Upn!;
    var idpName = config["Enrollment:IdpName"] ?? "freeADFSOtp";
    var accountName = form["accountName"].ToString();
    if (string.IsNullOrWhiteSpace(accountName))
    {
        accountName = upn;
    }

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync("/enrollment/start", new { userPrincipalName = upn, idpName, accountName });
    var payload = await response.Content.ReadAsStringAsync();

    if (!response.IsSuccessStatusCode)
    {
        return Results.Content(RenderError(payload), "text/html", Encoding.UTF8, (int)response.StatusCode);
    }

    using var document = JsonDocument.Parse(payload);
    var root = document.RootElement;
    var qrCodePngBase64 = root.GetProperty("qrCodePngBase64").GetString();

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
      <p><strong>UPN:</strong> {{Encode(root.GetProperty("userPrincipalName").GetString())}}</p>
      <p><strong>Libelle mobile:</strong> {{Encode(root.GetProperty("phoneLabel").GetString())}}</p>
      <p><strong>Secret Base32:</strong><br /><span class="mono">{{Encode(root.GetProperty("secretBase32").GetString())}}</span></p>
      <p><strong>URI otpAuth:</strong><br /><span class="mono">{{Encode(root.GetProperty("otpAuthUri").GetString())}}</span></p>
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

enroll.MapPost("/verify", async (HttpContext ctx, IHttpClientFactory factory, IConfiguration config) =>
{
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
