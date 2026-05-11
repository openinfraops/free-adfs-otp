#if ADFS_SERVER
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Data;
using System.Data.SqlClient;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityServer.Web.Authentication.External;

namespace FreeAdfsOtp.AdfsAdapter.AdapterRuntime;

public sealed class FreeAdfsOtpAuthenticationAdapter : IAuthenticationAdapter
{
    private IOtpRuntimeBackend _backend;
    private Uri _apiBaseUrl;
    private Uri _enrollmentPortalBaseUrl;
    private string _sqlConnectionString;
    private string _secretMasterKeyBase64;
    private string _backendMode;

    public FreeAdfsOtpAuthenticationAdapter()
    {
        _apiBaseUrl = new Uri("https://localhost:7043");
        _enrollmentPortalBaseUrl = new Uri("https://localhost:7143/enroll");
        _backendMode = "Api";
        _sqlConnectionString = string.Empty;
        _secretMasterKeyBase64 = string.Empty;
        _backend = new ApiOtpRuntimeBackend(new OtpAdapterSkeleton(_apiBaseUrl));
    }

    public IAuthenticationAdapterMetadata Metadata => new FreeAdfsOtpMetadata();

    public IAdapterPresentation BeginAuthentication(Claim identityClaim, HttpListenerRequest request, IAuthenticationContext authContext)
    {
        var upn = identityClaim?.Value;
        if (string.IsNullOrWhiteSpace(upn))
        {
            return FreeAdfsOtpPresentationForm.Error("Impossible de determiner l'utilisateur (UPN).", _enrollmentPortalBaseUrl.ToString());
        }

        PersistUpnInAuthenticationContext(authContext, upn);

        var isEnrolled = _backend.IsUserEnrolled(upn);
        if (!isEnrolled)
        {
            var enrollmentUrl = BuildEnrollmentUrl(upn);
            return FreeAdfsOtpPresentationForm.NotEnrolled(upn, enrollmentUrl);
        }

        return FreeAdfsOtpPresentationForm.Challenge(upn, _enrollmentPortalBaseUrl.ToString());
    }

    public bool IsAvailableForUser(Claim identityClaim, IAuthenticationContext authContext)
    {
        return true;
    }

    public void OnAuthenticationPipelineLoad(IAuthenticationMethodConfigData configData)
    {
        if (configData == null || configData.Data == null)
        {
            return;
        }

        if (configData.Data.CanSeek)
        {
            configData.Data.Position = 0;
        }

        string data;
        using (var reader = new StreamReader(configData.Data, Encoding.UTF8, true, 1024, true))
        {
            data = reader.ReadToEnd();
        }

        if (string.IsNullOrWhiteSpace(data))
        {
            return;
        }

        // Supports both API and SQL direct mode.
        var mode = ExtractTagValue(data, "Mode");
        var apiBaseUrl = ExtractTagValue(data, "ApiBaseUrl");
        var enrollmentPortal = ExtractTagValue(data, "EnrollmentPortalBaseUrl");
        var sqlConnectionString = ExtractTagValue(data, "SqlConnectionString");
        var secretMasterKeyBase64 = ExtractTagValue(data, "SecretMasterKeyBase64");

        if (!string.IsNullOrWhiteSpace(mode))
        {
            _backendMode = mode.Trim();
        }

        if (Uri.TryCreate(apiBaseUrl, UriKind.Absolute, out var parsedApiBaseUrl))
        {
            _apiBaseUrl = parsedApiBaseUrl;
        }

        if (Uri.TryCreate(enrollmentPortal, UriKind.Absolute, out var parsedEnrollmentPortal))
        {
            _enrollmentPortalBaseUrl = parsedEnrollmentPortal;
        }

        if (!string.IsNullOrWhiteSpace(sqlConnectionString))
        {
            _sqlConnectionString = sqlConnectionString.Trim();
        }

        if (!string.IsNullOrWhiteSpace(secretMasterKeyBase64))
        {
            _secretMasterKeyBase64 = secretMasterKeyBase64.Trim();
        }

        if (_backendMode.Equals("SqlDirect", StringComparison.OrdinalIgnoreCase))
        {
            _backend = new SqlDirectOtpRuntimeBackend(_sqlConnectionString, _secretMasterKeyBase64);
        }
        else
        {
            _backend = new ApiOtpRuntimeBackend(new OtpAdapterSkeleton(_apiBaseUrl));
        }
    }

    public void OnAuthenticationPipelineUnload()
    {
    }

    public IAdapterPresentation OnError(HttpListenerRequest request, ExternalAuthenticationException ex)
    {
        return FreeAdfsOtpPresentationForm.Error("Une erreur est survenue dans le provider OTP.", _enrollmentPortalBaseUrl.ToString());
    }

    public IAdapterPresentation TryEndAuthentication(IAuthenticationContext authContext, IProofData proofData, HttpListenerRequest request, out Claim[] outgoingClaims)
    {
        outgoingClaims = new Claim[0];

        var upn = ResolveUpn(authContext, request);
        if (string.IsNullOrWhiteSpace(upn))
        {
            upn = ResolveUpnFromProofData(proofData);
        }

        if (string.IsNullOrWhiteSpace(upn))
        {
            return FreeAdfsOtpPresentationForm.Error("Session invalide: UPN introuvable.", _enrollmentPortalBaseUrl.ToString());
        }

        PersistUpnInAuthenticationContext(authContext, upn);

        var otpCode = proofData?.Properties != null && proofData.Properties.ContainsKey("otpCode")
            ? proofData.Properties["otpCode"] as string
            : null;

        if (string.IsNullOrWhiteSpace(otpCode))
        {
            return FreeAdfsOtpPresentationForm.Challenge(upn, BuildEnrollmentUrl(upn), "Code OTP requis.");
        }

        var correlationId = Guid.NewGuid();
        var validation = _backend.ValidateOtp(
            upn,
            otpCode,
            request?.UserHostAddress ?? string.Empty,
            request?.UserAgent ?? string.Empty,
            correlationId);

        if (!validation.IsSuccess)
        {
            if (validation.IsLocked)
            {
                return FreeAdfsOtpPresentationForm.Error("Les essais OTP ne sont plus disponibles pour ce compte. Merci de contacter un administrateur.", BuildEnrollmentUrl(upn));
            }

            return FreeAdfsOtpPresentationForm.Challenge(upn, BuildEnrollmentUrl(upn), "Code OTP invalide ou expiré.");
        }

        outgoingClaims = new[]
        {
            new Claim(AdfsOtpAdapterConstants.AuthenticationMethodClaimType, AdfsOtpAdapterConstants.MultipleAuthnMethodUri)
        };

        return null;
    }

    private string BuildEnrollmentUrl(string upn)
    {
        var separator = _enrollmentPortalBaseUrl.Query?.Length > 0 ? "&" : "?";
        return _enrollmentPortalBaseUrl + separator + "userPrincipalName=" + Uri.EscapeDataString(upn);
    }

    private static string ResolveUpn(IAuthenticationContext authContext, HttpListenerRequest request)
    {
        try
        {
            if (authContext?.Data != null)
            {
                var upnKeys = new[]
                {
                    AdfsOtpAdapterConstants.UpnClaimType,
                    "upn",
                    "userPrincipalName"
                };

                foreach (var key in upnKeys)
                {
                    if (authContext.Data.TryGetValue(key, out var value) && value != null)
                    {
                        var text = Convert.ToString(value);
                        if (!string.IsNullOrWhiteSpace(text))
                        {
                            return text;
                        }
                    }
                }
            }
        }
        catch
        {
            // Best-effort extraction: fallback below.
        }

        return request?.QueryString?["upn"];
    }

    private static string ResolveUpnFromProofData(IProofData proofData)
    {
        try
        {
            if (proofData?.Properties == null)
            {
                return null;
            }

            var upnKeys = new[]
            {
                AdfsOtpAdapterConstants.UpnClaimType,
                "upn",
                "userPrincipalName"
            };

            foreach (var key in upnKeys)
            {
                if (proofData.Properties.ContainsKey(key) && proofData.Properties[key] != null)
                {
                    var text = Convert.ToString(proofData.Properties[key]);
                    if (!string.IsNullOrWhiteSpace(text))
                    {
                        return text;
                    }
                }
            }
        }
        catch
        {
            // Best-effort extraction.
        }

        return null;
    }

    private static void PersistUpnInAuthenticationContext(IAuthenticationContext authContext, string upn)
    {
        if (string.IsNullOrWhiteSpace(upn) || authContext?.Data == null)
        {
            return;
        }

        SetAuthenticationContextValue(authContext.Data, AdfsOtpAdapterConstants.UpnClaimType, upn);
        SetAuthenticationContextValue(authContext.Data, "upn", upn);
        SetAuthenticationContextValue(authContext.Data, "userPrincipalName", upn);
    }

    private static void SetAuthenticationContextValue(IDictionary<string, object> data, string key, string value)
    {
        if (data.ContainsKey(key))
        {
            data[key] = value;
            return;
        }

        data.Add(key, value);
    }

    private static string ExtractTagValue(string xml, string tagName)
    {
        var startTag = "<" + tagName + ">";
        var endTag = "</" + tagName + ">";
        var start = xml.IndexOf(startTag, StringComparison.OrdinalIgnoreCase);
        if (start < 0)
        {
            return string.Empty;
        }

        start += startTag.Length;
        var end = xml.IndexOf(endTag, start, StringComparison.OrdinalIgnoreCase);
        if (end < 0)
        {
            return string.Empty;
        }

        return xml.Substring(start, end - start).Trim();
    }
}

internal interface IOtpRuntimeBackend
{
    bool IsUserEnrolled(string upn);
    OtpRuntimeValidationResult ValidateOtp(string upn, string code, string clientIp, string userAgent, Guid correlationId);
}

internal sealed class OtpRuntimeValidationResult
{
    public bool IsSuccess { get; set; }
    public bool IsLocked { get; set; }
}

internal sealed class ApiOtpRuntimeBackend : IOtpRuntimeBackend
{
    private readonly OtpAdapterSkeleton _client;

    public ApiOtpRuntimeBackend(OtpAdapterSkeleton client)
    {
        _client = client;
    }

    public bool IsUserEnrolled(string upn)
    {
        return _client.IsUserEnrolledAsync(upn).GetAwaiter().GetResult();
    }

    public OtpRuntimeValidationResult ValidateOtp(string upn, string code, string clientIp, string userAgent, Guid correlationId)
    {
        var result = _client.ValidateOtpAsync(upn, code, clientIp, userAgent, correlationId).GetAwaiter().GetResult();
        return new OtpRuntimeValidationResult
        {
            IsSuccess = result.IsSuccess,
            IsLocked = result.IsLocked
        };
    }
}

internal sealed class SqlDirectOtpRuntimeBackend : IOtpRuntimeBackend
{
    private readonly string _connectionString;
    private readonly byte[] _masterKey;
    private readonly int _digits = 6;
    private readonly int _stepSeconds = 30;
    private readonly int _allowedSkewSteps = 1;
    private readonly int _maxFailedAttempts = 5;
    private readonly int _failedWindowMinutes = 10;
    private readonly int _lockoutMinutes = 15;

    public SqlDirectOtpRuntimeBackend(string connectionString, string secretMasterKeyBase64)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException("SqlConnectionString must be configured for SqlDirect mode.");
        }

        if (string.IsNullOrWhiteSpace(secretMasterKeyBase64))
        {
            throw new InvalidOperationException("SecretMasterKeyBase64 must be configured for SqlDirect mode.");
        }

        _connectionString = connectionString;
        _masterKey = Convert.FromBase64String(secretMasterKeyBase64);
        if (_masterKey.Length != 32)
        {
            throw new InvalidOperationException("SecretMasterKeyBase64 must decode to 32 bytes (AES-256). ");
        }
    }

    public bool IsUserEnrolled(string upn)
    {
        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var cmd = new SqlCommand("SELECT TOP 1 IsEnrolled, IsActive FROM otp.Users WHERE UserPrincipalName = @Upn", connection))
            {
                cmd.Parameters.AddWithValue("@Upn", upn);
                using (var reader = cmd.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return false;
                    }

                    return reader.GetBoolean(0) && reader.GetBoolean(1);
                }
            }
        }
    }

    public OtpRuntimeValidationResult ValidateOtp(string upn, string code, string clientIp, string userAgent, Guid correlationId)
    {
        var now = DateTime.UtcNow;
        var record = GetOtpRecord(upn);
        if (record == null)
        {
            LogAttempt(null, upn, null, false, "NOT_ENROLLED", clientIp, userAgent, correlationId);
            return new OtpRuntimeValidationResult { IsSuccess = false, IsLocked = false };
        }

        if (!record.IsActive || !record.IsEnrolled || !record.MethodEnabled)
        {
            LogAttempt(record.UserId, upn, record.MethodType, false, "NOT_ENROLLED", clientIp, userAgent, correlationId);
            return new OtpRuntimeValidationResult { IsSuccess = false, IsLocked = false };
        }

        var lockout = GetOrCreateLockout(record.UserId);
        if (lockout.LockedUntilUtc.HasValue && lockout.LockedUntilUtc.Value > now)
        {
            LogAttempt(record.UserId, upn, record.MethodType, false, "LOCKED", clientIp, userAgent, correlationId);
            return new OtpRuntimeValidationResult { IsSuccess = false, IsLocked = true };
        }

        var rawSecret = UnprotectSecret(record.SecretCiphertext, record.SecretKeyVersion);
        long matchedStep;
        if (!ValidateTotp(code, rawSecret, now, out matchedStep))
        {
            RegisterFailure(record.UserId, lockout, now);
            LogAttempt(record.UserId, upn, record.MethodType, false, "INVALID_CODE", clientIp, userAgent, correlationId);
            return new OtpRuntimeValidationResult { IsSuccess = false, IsLocked = false };
        }

        if (record.LastAcceptedTimeStep.HasValue && matchedStep <= record.LastAcceptedTimeStep.Value)
        {
            LogAttempt(record.UserId, upn, record.MethodType, false, "REPLAY", clientIp, userAgent, correlationId);
            return new OtpRuntimeValidationResult { IsSuccess = false, IsLocked = false };
        }

        MarkSuccess(record.MethodId, record.UserId, matchedStep);
        LogAttempt(record.UserId, upn, record.MethodType, true, null, clientIp, userAgent, correlationId);
        return new OtpRuntimeValidationResult { IsSuccess = true, IsLocked = false };
    }

    private OtpRecord GetOtpRecord(string upn)
    {
        const string sql = @"
SELECT TOP 1
    u.UserId,
    u.IsEnrolled,
    u.IsActive,
    m.MethodId,
    m.MethodType,
    m.IsEnabled,
    s.SecretCiphertext,
    s.SecretKeyVersion,
    s.LastAcceptedTimeStep
FROM otp.Users u
LEFT JOIN otp.OtpMethods m ON m.UserId = u.UserId AND m.IsPrimaryMethod = 1
LEFT JOIN otp.OtpSecrets s ON s.MethodId = m.MethodId
WHERE u.UserPrincipalName = @Upn
ORDER BY m.EnrolledUtc DESC;";

        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var cmd = new SqlCommand(sql, connection))
            {
                cmd.Parameters.AddWithValue("@Upn", upn);
                using (var reader = cmd.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    if (reader.IsDBNull(3) || reader.IsDBNull(6))
                    {
                        return new OtpRecord
                        {
                            UserId = reader.GetGuid(0),
                            IsEnrolled = reader.GetBoolean(1),
                            IsActive = reader.GetBoolean(2),
                            MethodEnabled = false,
                            MethodType = null
                        };
                    }

                    return new OtpRecord
                    {
                        UserId = reader.GetGuid(0),
                        IsEnrolled = reader.GetBoolean(1),
                        IsActive = reader.GetBoolean(2),
                        MethodId = reader.GetGuid(3),
                        MethodType = reader.GetString(4),
                        MethodEnabled = reader.GetBoolean(5),
                        SecretCiphertext = (byte[])reader[6],
                        SecretKeyVersion = reader.GetInt32(7),
                        LastAcceptedTimeStep = reader.IsDBNull(8) ? (long?)null : reader.GetInt64(8)
                    };
                }
            }
        }
    }

    private LockoutState GetOrCreateLockout(Guid userId)
    {
        const string readSql = @"
SELECT TOP 1 FailedAttemptsInWindow, WindowStartUtc, LockedUntilUtc
FROM otp.UserLockouts
WHERE UserId = @UserId;";

        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var readCmd = new SqlCommand(readSql, connection))
            {
                readCmd.Parameters.AddWithValue("@UserId", userId);
                using (var reader = readCmd.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        return new LockoutState
                        {
                            FailedAttemptsInWindow = reader.GetInt32(0),
                            WindowStartUtc = reader.IsDBNull(1) ? (DateTime?)null : reader.GetDateTime(1),
                            LockedUntilUtc = reader.IsDBNull(2) ? (DateTime?)null : reader.GetDateTime(2)
                        };
                    }
                }
            }

            using (var createCmd = new SqlCommand("INSERT INTO otp.UserLockouts (UserId, FailedAttemptsInWindow, UpdatedUtc) VALUES (@UserId, 0, SYSUTCDATETIME())", connection))
            {
                createCmd.Parameters.AddWithValue("@UserId", userId);
                createCmd.ExecuteNonQuery();
            }
        }

        return new LockoutState();
    }

    private void RegisterFailure(Guid userId, LockoutState lockout, DateTime nowUtc)
    {
        var attempts = lockout.FailedAttemptsInWindow;
        var windowStart = lockout.WindowStartUtc;
        if (!windowStart.HasValue || windowStart.Value.AddMinutes(_failedWindowMinutes) < nowUtc)
        {
            attempts = 0;
            windowStart = nowUtc;
        }

        attempts += 1;
        DateTime? lockedUntil = null;
        if (attempts >= _maxFailedAttempts)
        {
            lockedUntil = nowUtc.AddMinutes(_lockoutMinutes);
            attempts = 0;
            windowStart = nowUtc;
        }

        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var cmd = new SqlCommand(@"
UPDATE otp.UserLockouts
SET FailedAttemptsInWindow = @Attempts,
    WindowStartUtc = @WindowStartUtc,
    LockedUntilUtc = @LockedUntilUtc,
    LastFailureUtc = @NowUtc,
    UpdatedUtc = SYSUTCDATETIME()
WHERE UserId = @UserId", connection))
            {
                cmd.Parameters.AddWithValue("@UserId", userId);
                cmd.Parameters.AddWithValue("@Attempts", attempts);
                cmd.Parameters.AddWithValue("@WindowStartUtc", (object)windowStart ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@LockedUntilUtc", (object)lockedUntil ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@NowUtc", nowUtc);
                cmd.ExecuteNonQuery();
            }
        }
    }

    private void MarkSuccess(Guid methodId, Guid userId, long matchedStep)
    {
        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var cmd = new SqlCommand(@"
UPDATE otp.OtpSecrets SET LastAcceptedTimeStep = @Step WHERE MethodId = @MethodId;
UPDATE otp.UserLockouts
SET FailedAttemptsInWindow = 0,
    WindowStartUtc = NULL,
    LockedUntilUtc = NULL,
    LastFailureUtc = NULL,
    UpdatedUtc = SYSUTCDATETIME()
WHERE UserId = @UserId;", connection))
            {
                cmd.Parameters.AddWithValue("@MethodId", methodId);
                cmd.Parameters.AddWithValue("@UserId", userId);
                cmd.Parameters.AddWithValue("@Step", matchedStep);
                cmd.ExecuteNonQuery();
            }
        }
    }

    private void LogAttempt(Guid? userId, string upn, string methodType, bool isSuccess, string failureReason, string clientIp, string userAgent, Guid correlationId)
    {
        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var cmd = new SqlCommand(@"
INSERT INTO otp.OtpAttempts (UserId, UserPrincipalName, MethodType, IsSuccess, FailureReason, ClientIp, UserAgent, CorrelationId)
VALUES (@UserId, @Upn, @MethodType, @IsSuccess, @FailureReason, @ClientIp, @UserAgent, @CorrelationId)", connection))
            {
                cmd.Parameters.AddWithValue("@UserId", (object)userId ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@Upn", upn);
                cmd.Parameters.AddWithValue("@MethodType", (object)methodType ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@IsSuccess", isSuccess);
                cmd.Parameters.AddWithValue("@FailureReason", (object)failureReason ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@ClientIp", (object)clientIp ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@UserAgent", (object)userAgent ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@CorrelationId", correlationId);
                cmd.ExecuteNonQuery();
            }
        }
    }

    private byte[] UnprotectSecret(byte[] payload, int expectedKeyVersion)
    {
        if (payload == null || payload.Length < 21)
        {
            throw new CryptographicException("Invalid encrypted secret payload.");
        }

        var keyVersion = BitConverter.ToInt32(payload, 1);
        if (keyVersion != expectedKeyVersion)
        {
            throw new CryptographicException("Secret key version mismatch.");
        }

        var iv = new byte[16];
        Buffer.BlockCopy(payload, 5, iv, 0, 16);
        var cipher = new byte[payload.Length - 21];
        Buffer.BlockCopy(payload, 21, cipher, 0, cipher.Length);

        using (var aes = Aes.Create())
        {
            aes.Key = _masterKey;
            aes.IV = iv;
            using (var decryptor = aes.CreateDecryptor())
            {
                return decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
            }
        }
    }

    private bool ValidateTotp(string code, byte[] secret, DateTime nowUtc, out long matchedStep)
    {
        matchedStep = -1;
        if (string.IsNullOrWhiteSpace(code) || code.Length != _digits)
        {
            return false;
        }

        for (var i = 0; i < code.Length; i++)
        {
            if (!char.IsDigit(code[i]))
            {
                return false;
            }
        }

        var unixEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var currentStep = (long)(nowUtc.ToUniversalTime().Subtract(unixEpoch).TotalSeconds) / _stepSeconds;
        for (var skew = -_allowedSkewSteps; skew <= _allowedSkewSteps; skew++)
        {
            var step = currentStep + skew;
            var expected = ComputeTotp(secret, step, _digits);
            if (FixedTimeEquals(code, expected))
            {
                matchedStep = step;
                return true;
            }
        }

        return false;
    }

    private static string ComputeTotp(byte[] secret, long step, int digits)
    {
        var stepBytes = BitConverter.GetBytes(step);
        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(stepBytes);
        }

        byte[] hash;
        using (var hmac = new HMACSHA1(secret))
        {
            hash = hmac.ComputeHash(stepBytes);
        }

        var offset = hash[hash.Length - 1] & 0x0F;
        var binaryCode = ((hash[offset] & 0x7F) << 24)
            | ((hash[offset + 1] & 0xFF) << 16)
            | ((hash[offset + 2] & 0xFF) << 8)
            | (hash[offset + 3] & 0xFF);

        var otp = binaryCode % (int)Math.Pow(10, digits);
        return otp.ToString(CultureInfo.InvariantCulture).PadLeft(digits, '0');
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        var length = leftBytes.Length < rightBytes.Length ? leftBytes.Length : rightBytes.Length;
        var diff = leftBytes.Length ^ rightBytes.Length;
        for (var i = 0; i < length; i++)
        {
            diff |= leftBytes[i] ^ rightBytes[i];
        }

        return diff == 0;
    }

    private sealed class OtpRecord
    {
        public Guid UserId;
        public bool IsEnrolled;
        public bool IsActive;
        public Guid MethodId;
        public string MethodType;
        public bool MethodEnabled;
        public byte[] SecretCiphertext;
        public int SecretKeyVersion;
        public long? LastAcceptedTimeStep;
    }

    private sealed class LockoutState
    {
        public int FailedAttemptsInWindow;
        public DateTime? WindowStartUtc;
        public DateTime? LockedUntilUtc;
    }
}

public sealed class FreeAdfsOtpMetadata : IAuthenticationAdapterMetadata
{
    public string AdminName => "freeADFSOtp";

    public string[] AuthenticationMethods => new[]
    {
        AdfsOtpAdapterConstants.AuthenticationMethodUri,
        AdfsOtpAdapterConstants.MultipleAuthnMethodUri
    };

    public int[] AvailableLcids => new[] { new CultureInfo("en-US").LCID, new CultureInfo("fr-FR").LCID };

    public Dictionary<int, string> FriendlyNames => new()
    {
        [new CultureInfo("en-US").LCID] = "freeADFSOtp",
        [new CultureInfo("fr-FR").LCID] = "freeADFSOtp"
    };

    public Dictionary<int, string> Descriptions => new()
    {
        [new CultureInfo("en-US").LCID] = "OTP validation using freeADFSOtp backend.",
        [new CultureInfo("fr-FR").LCID] = "Validation OTP via le backend freeADFSOtp."
    };

    public string[] IdentityClaims => new[] { AdfsOtpAdapterConstants.UpnClaimType };

    public bool RequiresIdentity => true;
}

public sealed class FreeAdfsOtpPresentationForm : IAdapterPresentationForm
{
    private readonly string _message;
    private readonly string _enrollmentUrl;
    private readonly bool _showOtpInput;
    private readonly string _upn;

    private FreeAdfsOtpPresentationForm(string message, string enrollmentUrl, bool showOtpInput, string upn)
    {
        _message = message;
        _enrollmentUrl = enrollmentUrl;
        _showOtpInput = showOtpInput;
        _upn = upn;
    }

    public static FreeAdfsOtpPresentationForm Challenge(string upn, string enrollmentUrl, string message = "Saisissez votre code OTP.")
    {
        return new FreeAdfsOtpPresentationForm(message, enrollmentUrl, true, upn);
    }

    public static FreeAdfsOtpPresentationForm NotEnrolled(string upn, string enrollmentUrl)
    {
        return new FreeAdfsOtpPresentationForm("Utilisateur non enrole. Veuillez d'abord activer votre OTP.", enrollmentUrl, false, upn);
    }

    public static FreeAdfsOtpPresentationForm Error(string message, string enrollmentUrl)
    {
        return new FreeAdfsOtpPresentationForm(message, enrollmentUrl, false, string.Empty);
    }

    public string GetFormHtml(int lcid)
    {
        var otpInputHtml = _showOtpInput
            ? "<label for='otpCode' class='block'>Code OTP</label><input id='otpCode' name='otpCode' type='text' class='text' inputmode='numeric' autocomplete='one-time-code' required />"
            : "";

        return "<div id='loginArea'><form method='post' id='loginForm'>"
            + "<input id='authMethod' type='hidden' name='AuthMethod' value='%AuthMethod%' />"
            + "<input id='context' type='hidden' name='Context' value='%Context%' />"
            + "<input id='upn' type='hidden' name='upn' value='" + WebUtility.HtmlEncode(_upn) + "' />"
            + "<p>" + WebUtility.HtmlEncode(_message) + "</p>"
            + otpInputHtml
            + "<div id='submissionArea' class='submitMargin'><input id='submitButton' type='submit' name='Submit' value='Valider' /></div>"
            + "<p><a href='" + WebUtility.HtmlEncode(_enrollmentUrl) + "' target='_blank' rel='noopener'>Aller vers l'enrollement OTP</a></p>"
            + "</form></div>";
    }

    public string GetFormPreRenderHtml(int lcid)
    {
        return null;
    }

    public string GetPageTitle(int lcid)
    {
        return "freeADFSOtp";
    }
}
#endif
