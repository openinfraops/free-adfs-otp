using System.Security.Cryptography;
using System.Text;
using FreeAdfsOtp.Api.Background;
using FreeAdfsOtp.Api.Contracts;
using FreeAdfsOtp.Api.Data;
using FreeAdfsOtp.Api.Dtos;
using FreeAdfsOtp.Api.Security;
using FreeAdfsOtp.Core.Contracts;
using FreeAdfsOtp.Core.Models;
using FreeAdfsOtp.Core.Services;
using QRCoder;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService();

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.Configure<LocalCacheOptions>(builder.Configuration.GetSection(LocalCacheOptions.SectionName));
builder.Services.Configure<SqlResilienceOptions>(builder.Configuration.GetSection(SqlResilienceOptions.SectionName));

builder.Services.AddSingleton<IClock, SystemClock>();
builder.Services.AddSingleton<RequestThrottleService>();
builder.Services.AddSingleton<SqlAvailabilityState>();
builder.Services.AddSingleton<LocalNodeCacheCipher>();
builder.Services.AddSingleton<LocalOtpCacheStore>();
builder.Services.AddScoped<SqlOtpRepository>();
builder.Services.AddScoped<CachedOtpRepository>();
builder.Services.AddScoped<IOtpRepository>(serviceProvider =>
{
    var cacheOptions = serviceProvider
        .GetRequiredService<Microsoft.Extensions.Options.IOptions<LocalCacheOptions>>()
        .Value;

    return cacheOptions.Enabled
        ? serviceProvider.GetRequiredService<CachedOtpRepository>()
        : serviceProvider.GetRequiredService<SqlOtpRepository>();
});
builder.Services.AddHostedService<PendingEnrollmentCleanupService>();
builder.Services.AddHostedService<LocalCachePeriodicSyncService>();
builder.Services.AddHostedService<SqlAvailabilityProbeService>();

var resolvedMasterKey = SecretValueResolver.ResolveRequired(
    builder.Configuration,
    "SecretProtection:MasterKey",
    "SecretProtection:MasterKeyDpapiFilePath",
    "SecretProtection:MasterKey");

var resolvedAdminApiKey = SecretValueResolver.ResolveOptional(
    builder.Configuration,
    "AdminAuth:ApiKey",
    "AdminAuth:ApiKeyDpapiFilePath");

var resolvedAdapterApiKey = SecretValueResolver.ResolveOptional(
    builder.Configuration,
    "AdapterAuth:ApiKey",
    "AdapterAuth:ApiKeyDpapiFilePath");

builder.Services.AddSingleton<ISecretProtector>(_ =>
{
    return new AesSecretProtector(resolvedMasterKey);
});

builder.Services.AddScoped<OtpValidationService>();

var app = builder.Build();

app.UseSwagger();
app.UseSwaggerUI();

app.MapGet("/health", () => Results.Ok(new { status = "ok", utc = DateTimeOffset.UtcNow }));

app.MapGet("/otp/enrollment-status/{upn}", async (HttpContext httpContext, string upn, IOtpRepository repository, CancellationToken ct) =>
{
    if (!IsAdapterAuthorized(httpContext, resolvedAdapterApiKey))
    {
        return Results.Unauthorized();
    }

    var user = await repository.GetUserByUpnAsync(upn, ct);
    return Results.Ok(new
    {
        userPrincipalName = upn,
        exists = user is not null,
        isEnrolled = user?.IsEnrolled ?? false,
        isActive = user?.IsActive ?? false
    });
});

app.MapPost("/otp/validate", async (
    HttpContext httpContext,
    ValidateOtpDto dto,
    OtpValidationService validationService,
    RequestThrottleService throttle,
    IClock clock,
    IConfiguration configuration,
    CancellationToken ct) =>
{
    if (!IsAdapterAuthorized(httpContext, resolvedAdapterApiKey))
    {
        return Results.Unauthorized();
    }

    var clientIp = GetClientIp(httpContext);
    var now = clock.UtcNow;

    var perIpLimit = configuration.GetValue<int?>("RateLimiting:OtpValidatePerIpLimit") ?? 30;
    var perIpWindowSeconds = configuration.GetValue<int?>("RateLimiting:OtpValidatePerIpWindowSeconds") ?? 60;
    if (!throttle.TryAcquire("otp-validate-ip", clientIp, perIpLimit, TimeSpan.FromSeconds(perIpWindowSeconds), now, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    var perUpnLimit = configuration.GetValue<int?>("RateLimiting:OtpValidatePerUpnLimit") ?? 10;
    var perUpnWindowSeconds = configuration.GetValue<int?>("RateLimiting:OtpValidatePerUpnWindowSeconds") ?? 60;
    if (!throttle.TryAcquire("otp-validate-upn", dto.UserPrincipalName, perUpnLimit, TimeSpan.FromSeconds(perUpnWindowSeconds), now, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    var settings = LoadSettings(configuration);

    var result = await validationService.ValidateAsync(
        new OtpValidationRequest(
            dto.UserPrincipalName,
            dto.Code,
            dto.ClientIp,
            dto.UserAgent,
            dto.CorrelationId,
            dto.AdfsActivityId),
        settings,
        clock.UtcNow,
        ct);

    return Results.Ok(result);
});

app.MapPost("/enrollment/start", async (
    HttpContext httpContext,
    EnrollmentStartDto dto,
    IConfiguration configuration,
    IOtpRepository repository,
    RequestThrottleService throttle,
    IClock clock,
    CancellationToken ct) =>
{
    var clientIp = GetClientIp(httpContext);
    var perIpLimit = configuration.GetValue<int?>("RateLimiting:EnrollmentStartPerIpLimit") ?? 10;
    var perIpWindowSeconds = configuration.GetValue<int?>("RateLimiting:EnrollmentStartPerIpWindowSeconds") ?? 300;
    if (!throttle.TryAcquire("enrollment-start-ip", clientIp, perIpLimit, TimeSpan.FromSeconds(perIpWindowSeconds), clock.UtcNow, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    if (string.IsNullOrWhiteSpace(dto.IdpName))
    {
        return Results.BadRequest(new { error = "IdpName is required." });
    }

    var existingUser = await repository.GetUserByUpnAsync(dto.UserPrincipalName, ct);
    if (existingUser?.IsEnrolled == true)
    {
        return Results.Conflict(new { error = "User is already enrolled." });
    }

    var secretBytes = RandomNumberGenerator.GetBytes(20);
    var secretBase32 = Base32Encoding.ToBase32(secretBytes);
    var accountName = string.IsNullOrWhiteSpace(dto.AccountName) ? dto.UserPrincipalName : dto.AccountName.Trim();
    var issuerName = string.IsNullOrWhiteSpace(dto.IssuerName) ? dto.IdpName.Trim() : dto.IssuerName.Trim();
    var pendingTtlMinutes = configuration.GetValue<int?>("Enrollment:PendingTtlMinutes") ?? 10;
    var expiresUtc = clock.UtcNow.AddMinutes(pendingTtlMinutes);
    await repository.SavePendingEnrollmentAsync(
        new PendingEnrollmentState(dto.UserPrincipalName, secretBase32, issuerName, accountName, expiresUtc),
        ct);

    var phoneLabel = accountName;
    var escapedLabel = Uri.EscapeDataString(phoneLabel);
    var escapedIssuer = Uri.EscapeDataString(issuerName);
    var otpAuthUri = $"otpauth://totp/{escapedLabel}?secret={secretBase32}&issuer={escapedIssuer}&algorithm=SHA1&digits=6&period=30";

    using var qrGenerator = new QRCodeGenerator();
    using var qrCodeData = qrGenerator.CreateQrCode(otpAuthUri, QRCodeGenerator.ECCLevel.Q);
    var pngQrCode = new PngByteQRCode(qrCodeData);
    var qrPngBytes = pngQrCode.GetGraphic(12);
    var qrCodePngBase64 = Convert.ToBase64String(qrPngBytes);

    return Results.Ok(new
    {
        dto.UserPrincipalName,
        idpName = dto.IdpName.Trim(),
    issuerName,
        accountName,
        phoneLabel,
        secretBase32,
        otpAuthUri,
        qrCodePngBase64
    });
});

app.MapPost("/enrollment/verify", async (
    HttpContext httpContext,
    EnrollmentVerifyDto dto,
    IConfiguration configuration,
    ISecretProtector protector,
    IOtpRepository repository,
    RequestThrottleService throttle,
    IClock clock,
    CancellationToken ct) =>
{
    var clientIp = GetClientIp(httpContext);
    var perIpLimit = configuration.GetValue<int?>("RateLimiting:EnrollmentVerifyPerIpLimit") ?? 20;
    var perIpWindowSeconds = configuration.GetValue<int?>("RateLimiting:EnrollmentVerifyPerIpWindowSeconds") ?? 300;
    if (!throttle.TryAcquire("enrollment-verify-ip", clientIp, perIpLimit, TimeSpan.FromSeconds(perIpWindowSeconds), clock.UtcNow, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    var pendingEnrollment = await repository.GetPendingEnrollmentAsync(dto.UserPrincipalName, ct);
    if (pendingEnrollment is null)
    {
        return Results.BadRequest(new { error = "No pending enrollment for this user." });
    }

    if (pendingEnrollment.ExpiresUtc <= clock.UtcNow)
    {
        await repository.DeletePendingEnrollmentAsync(dto.UserPrincipalName, ct);
        return Results.BadRequest(new { error = "Pending enrollment expired." });
    }

    var settings = LoadSettings(configuration);
    var pendingSecretRaw = Base32Encoding.FromBase32(pendingEnrollment.SecretBase32);

    if (!TotpService.ValidateCode(dto.Code, pendingSecretRaw, settings, clock.UtcNow, out _))
    {
        return Results.BadRequest(new { error = "Invalid OTP code." });
    }

    const int keyVersion = 1;
    var encryptedSecret = protector.Protect(pendingSecretRaw, keyVersion);
    await repository.SaveEnrollmentAsync(dto.UserPrincipalName, encryptedSecret, keyVersion, ct);
    await repository.DeletePendingEnrollmentAsync(dto.UserPrincipalName, ct);

    return Results.Ok(new { message = "Enrollment completed." });
});

app.MapPost("/admin/users/{upn}/reset-methods", async (
    HttpContext httpContext,
    string upn,
    AdminActionDto dto,
    IConfiguration configuration,
    RequestThrottleService throttle,
    IClock clock,
    IOtpRepository repository,
    CancellationToken ct) =>
{
    var clientIp = GetClientIp(httpContext);
    var perIpLimit = configuration.GetValue<int?>("RateLimiting:AdminPerIpLimit") ?? 30;
    var perIpWindowSeconds = configuration.GetValue<int?>("RateLimiting:AdminPerIpWindowSeconds") ?? 60;
    if (!throttle.TryAcquire("admin-ip", clientIp, perIpLimit, TimeSpan.FromSeconds(perIpWindowSeconds), clock.UtcNow, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    if (!IsAdminAuthorized(httpContext, resolvedAdminApiKey))
    {
        return Results.Unauthorized();
    }

    await repository.ResetUserMethodsAsync(upn, dto.AdminUpn, dto.Reason, ct);
    return Results.Ok(new { message = "Methods reset and re-enrollment required." });
});

app.MapPost("/admin/users/{upn}/unlock", async (
    HttpContext httpContext,
    string upn,
    AdminActionDto dto,
    IConfiguration configuration,
    RequestThrottleService throttle,
    IClock clock,
    IOtpRepository repository,
    CancellationToken ct) =>
{
    var clientIp = GetClientIp(httpContext);
    var perIpLimit = configuration.GetValue<int?>("RateLimiting:AdminPerIpLimit") ?? 30;
    var perIpWindowSeconds = configuration.GetValue<int?>("RateLimiting:AdminPerIpWindowSeconds") ?? 60;
    if (!throttle.TryAcquire("admin-ip", clientIp, perIpLimit, TimeSpan.FromSeconds(perIpWindowSeconds), clock.UtcNow, out _))
    {
        return Results.StatusCode(StatusCodes.Status429TooManyRequests);
    }

    if (!IsAdminAuthorized(httpContext, resolvedAdminApiKey))
    {
        return Results.Unauthorized();
    }

    await repository.UnlockUserAsync(upn, dto.AdminUpn, dto.Reason, ct);
    return Results.Ok(new { message = "User unlocked." });
});

app.Run();

static OtpSettings LoadSettings(IConfiguration configuration)
{
    return new OtpSettings(
        Digits: configuration.GetValue<int?>("Otp:TotpDigits") ?? 6,
        StepSeconds: configuration.GetValue<int?>("Otp:TotpStepSeconds") ?? 30,
        AllowedSkewSteps: configuration.GetValue<int?>("Otp:TotpAllowedSkewSteps") ?? 1,
        MaxFailedAttempts: configuration.GetValue<int?>("Lockout:MaxFailedAttempts") ?? 5,
        FailedWindowMinutes: configuration.GetValue<int?>("Lockout:FailedWindowMinutes") ?? 10,
        LockoutMinutes: configuration.GetValue<int?>("Lockout:LockoutMinutes") ?? 15);
}

static bool IsAdminAuthorized(HttpContext httpContext, string? expectedApiKey)
{
    if (string.IsNullOrWhiteSpace(expectedApiKey))
    {
        return false;
    }

    if (!httpContext.Request.Headers.TryGetValue("X-Admin-ApiKey", out var providedHeader))
    {
        return false;
    }

    var providedApiKey = providedHeader.ToString();
    var providedBytes = Encoding.UTF8.GetBytes(providedApiKey);
    var expectedBytes = Encoding.UTF8.GetBytes(expectedApiKey);
    if (providedBytes.Length != expectedBytes.Length)
    {
        return false;
    }

    return CryptographicOperations.FixedTimeEquals(providedBytes, expectedBytes);
}

static bool IsAdapterAuthorized(HttpContext httpContext, string? expectedApiKey)
{
    // Backward compatibility: if adapter auth key is not configured, keep current behavior.
    if (string.IsNullOrWhiteSpace(expectedApiKey))
    {
        return true;
    }

    if (!httpContext.Request.Headers.TryGetValue("X-Adapter-ApiKey", out var providedHeader))
    {
        return false;
    }

    var providedApiKey = providedHeader.ToString();
    var providedBytes = Encoding.UTF8.GetBytes(providedApiKey);
    var expectedBytes = Encoding.UTF8.GetBytes(expectedApiKey);
    if (providedBytes.Length != expectedBytes.Length)
    {
        return false;
    }

    return CryptographicOperations.FixedTimeEquals(providedBytes, expectedBytes);
}

static string GetClientIp(HttpContext? context)
{
    return context?.Connection?.RemoteIpAddress?.ToString() ?? "unknown";
}
