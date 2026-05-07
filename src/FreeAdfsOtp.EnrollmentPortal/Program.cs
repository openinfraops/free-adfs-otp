using System.Net.Http.Json;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient("otp-api", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["OtpApi:BaseUrl"] ?? "https://localhost:7043");
});

var app = builder.Build();

app.MapGet("/", () => Results.Redirect("/enroll"));

app.MapGet("/enroll", () => Results.Content("""
<!doctype html>
<html lang=\"fr\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" />
  <title>Enrollment OTP</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 2rem; max-width: 800px; }
    input, button { padding: .6rem; margin: .3rem 0; width: 100%; }
    .card { border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
    .muted { color: #555; font-size: .9rem; }
    code { word-break: break-all; }
  </style>
</head>
<body>
  <h1>Enrollment OTP</h1>
  <div class=\"card\">
    <h2>1. Provisioning</h2>
    <form method=\"post\" action=\"/enroll/start\">
      <label>UPN</label>
      <input name=\"userPrincipalName\" placeholder=\"user@contoso.com\" required />
      <label>Nom IDP</label>
      <input name=\"idpName\" value=\"freeADFSOtp\" required />
      <label>Nom du compte (affichage mobile)</label>
      <input name=\"accountName\" placeholder=\"user@contoso.com\" />
      <button type=\"submit\">Generer le secret</button>
    </form>
  </div>
  <div class=\"card\">
    <h2>2. Verification</h2>
    <form method=\"post\" action=\"/enroll/verify\">
      <label>UPN</label>
      <input name=\"userPrincipalName\" placeholder=\"user@contoso.com\" required />
      <label>Code OTP</label>
      <input name=\"code\" placeholder=\"123456\" required />
      <button type=\"submit\">Valider enrollment</button>
    </form>
  </div>
</body>
</html>
""", "text/html"));

app.MapPost("/enroll/start", async (HttpContext ctx, IHttpClientFactory factory) =>
{
    var form = await ctx.Request.ReadFormAsync();
    var upn = form["userPrincipalName"].ToString();
  var idpName = form["idpName"].ToString();
  var accountName = form["accountName"].ToString();

    var client = factory.CreateClient("otp-api");
  var response = await client.PostAsJsonAsync("/enrollment/start", new { userPrincipalName = upn, idpName, accountName });
    var payload = await response.Content.ReadAsStringAsync();

  if (!response.IsSuccessStatusCode)
  {
    return Results.Content($"<pre>{System.Net.WebUtility.HtmlEncode(payload)}</pre><p><a href='/enroll'>Retour</a></p>", "text/html");
  }

  using var document = JsonDocument.Parse(payload);
  var root = document.RootElement;
  var qrCodePngBase64 = root.GetProperty("qrCodePngBase64").GetString();

  var html = $"""
<h2>Provisioning OTP</h2>
<p><strong>UPN:</strong> {System.Net.WebUtility.HtmlEncode(root.GetProperty("userPrincipalName").GetString())}</p>
<p><strong>Libelle applique dans le telephone:</strong> {System.Net.WebUtility.HtmlEncode(root.GetProperty("phoneLabel").GetString())}</p>
<p><strong>Secret Base32:</strong> <code>{System.Net.WebUtility.HtmlEncode(root.GetProperty("secretBase32").GetString())}</code></p>
<p><strong>otpauth URI:</strong> <code>{System.Net.WebUtility.HtmlEncode(root.GetProperty("otpAuthUri").GetString())}</code></p>
<p><img alt=\"QR OTP\" src=\"data:image/png;base64,{System.Net.WebUtility.HtmlEncode(qrCodePngBase64)}\" /></p>
<p><a href='/enroll'>Retour</a></p>
""";

  return Results.Content(html, "text/html");
});

app.MapPost("/enroll/verify", async (HttpContext ctx, IHttpClientFactory factory) =>
{
    var form = await ctx.Request.ReadFormAsync();
    var upn = form["userPrincipalName"].ToString();
    var code = form["code"].ToString();

    var client = factory.CreateClient("otp-api");
    var response = await client.PostAsJsonAsync("/enrollment/verify", new { userPrincipalName = upn, code });
    var payload = await response.Content.ReadAsStringAsync();

    return Results.Content($"<pre>{System.Net.WebUtility.HtmlEncode(payload)}</pre><p><a href='/enroll'>Retour</a></p>", "text/html");
});

app.Run();
