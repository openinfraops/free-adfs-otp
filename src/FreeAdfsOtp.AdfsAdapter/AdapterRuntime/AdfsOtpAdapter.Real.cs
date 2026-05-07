#if ADFS_SERVER
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Security.Claims;
using Microsoft.IdentityServer.Web.Authentication.External;

namespace FreeAdfsOtp.AdfsAdapter.AdapterRuntime;

public sealed class FreeAdfsOtpAuthenticationAdapter : IAuthenticationAdapter
{
    private OtpAdapterSkeleton _otpClient;
    private Uri _apiBaseUrl;
    private Uri _enrollmentPortalBaseUrl;

    public FreeAdfsOtpAuthenticationAdapter()
    {
        _apiBaseUrl = new Uri("https://localhost:7043");
        _enrollmentPortalBaseUrl = new Uri("https://localhost:7143/enroll");
        _otpClient = new OtpAdapterSkeleton(_apiBaseUrl);
    }

    public IAuthenticationAdapterMetadata Metadata => new FreeAdfsOtpMetadata();

    public IAdapterPresentation BeginAuthentication(Claim identityClaim, HttpListenerRequest request, IAuthenticationContext authContext)
    {
        var upn = identityClaim?.Value;
        if (string.IsNullOrWhiteSpace(upn))
        {
            return FreeAdfsOtpPresentationForm.Error("Impossible de determiner l'utilisateur (UPN).", _enrollmentPortalBaseUrl);
        }

        var isEnrolled = _otpClient.IsUserEnrolledAsync(upn).GetAwaiter().GetResult();
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
        if (configData == null || string.IsNullOrWhiteSpace(configData.Data))
        {
            return;
        }

        // Expected configData.Data XML example:
        // <Config><ApiBaseUrl>https://otp-api.local/</ApiBaseUrl><EnrollmentPortalBaseUrl>https://otp-enroll.local/enroll</EnrollmentPortalBaseUrl></Config>
        var data = configData.Data;
        var apiBaseUrl = ExtractTagValue(data, "ApiBaseUrl");
        var enrollmentPortal = ExtractTagValue(data, "EnrollmentPortalBaseUrl");

        if (Uri.TryCreate(apiBaseUrl, UriKind.Absolute, out var parsedApiBaseUrl))
        {
            _apiBaseUrl = parsedApiBaseUrl;
        }

        if (Uri.TryCreate(enrollmentPortal, UriKind.Absolute, out var parsedEnrollmentPortal))
        {
            _enrollmentPortalBaseUrl = parsedEnrollmentPortal;
        }

        _otpClient = new OtpAdapterSkeleton(_apiBaseUrl);
    }

    public void OnAuthenticationPipelineUnload()
    {
    }

    public IAdapterPresentation OnError(HttpListenerRequest request, ExternalAuthenticationException ex)
    {
        return FreeAdfsOtpPresentationForm.Error("Une erreur est survenue dans le provider OTP.", _enrollmentPortalBaseUrl);
    }

    public IAdapterPresentation TryEndAuthentication(IAuthenticationContext authContext, IProofData proofData, HttpListenerRequest request, out Claim[] outgoingClaims)
    {
        outgoingClaims = Array.Empty<Claim>();

        var upn = ResolveUpn(authContext, request);
        if (string.IsNullOrWhiteSpace(upn))
        {
            return FreeAdfsOtpPresentationForm.Error("Session invalide: UPN introuvable.", _enrollmentPortalBaseUrl);
        }

        var otpCode = proofData?.Properties != null && proofData.Properties.ContainsKey("otpCode")
            ? proofData.Properties["otpCode"] as string
            : null;

        if (string.IsNullOrWhiteSpace(otpCode))
        {
            return FreeAdfsOtpPresentationForm.Error("Code OTP requis.", BuildEnrollmentUrl(upn));
        }

        var correlationId = Guid.NewGuid();
        var validated = _otpClient.ValidateOtpAsync(
            upn,
            otpCode,
            request?.UserHostAddress ?? string.Empty,
            request?.UserAgent ?? string.Empty,
            correlationId).GetAwaiter().GetResult();

        if (!validated)
        {
            return FreeAdfsOtpPresentationForm.Error("Code OTP invalide ou expiré.", BuildEnrollmentUrl(upn));
        }

        outgoingClaims = new[]
        {
            new Claim(AdfsOtpAdapterConstants.AuthenticationMethodClaimType, AdfsOtpAdapterConstants.AuthenticationMethodUri)
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
            var claim = authContext?.Data?.Identity?.FindFirst(AdfsOtpAdapterConstants.UpnClaimType);
            if (claim != null && !string.IsNullOrWhiteSpace(claim.Value))
            {
                return claim.Value;
            }
        }
        catch
        {
            // Best-effort extraction: fallback below.
        }

        return request?.Params?["upn"];
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

public sealed class FreeAdfsOtpMetadata : IAuthenticationAdapterMetadata
{
    public string AdminName => "freeADFSOtp";

    public string[] AuthenticationMethods => new[] { AdfsOtpAdapterConstants.AuthenticationMethodUri };

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

    private FreeAdfsOtpPresentationForm(string message, string enrollmentUrl, bool showOtpInput)
    {
        _message = message;
        _enrollmentUrl = enrollmentUrl;
        _showOtpInput = showOtpInput;
    }

    public static FreeAdfsOtpPresentationForm Challenge(string upn, string enrollmentUrl)
    {
        return new FreeAdfsOtpPresentationForm("Saisissez votre code OTP.", enrollmentUrl, true);
    }

    public static FreeAdfsOtpPresentationForm NotEnrolled(string upn, string enrollmentUrl)
    {
        return new FreeAdfsOtpPresentationForm("Utilisateur non enrole. Veuillez d'abord activer votre OTP.", enrollmentUrl, false);
    }

    public static FreeAdfsOtpPresentationForm Error(string message, Uri enrollmentPortalBaseUrl)
    {
        return new FreeAdfsOtpPresentationForm(message, enrollmentPortalBaseUrl.ToString(), false);
    }

    public string GetFormHtml(int lcid)
    {
        var otpInputHtml = _showOtpInput
            ? "<label for='otpCode' class='block'>Code OTP</label><input id='otpCode' name='otpCode' type='text' class='text' inputmode='numeric' autocomplete='one-time-code' required />"
            : "";

        return "<div id='loginArea'><form method='post' id='loginForm'>"
            + "<input id='authMethod' type='hidden' name='AuthMethod' value='%AuthMethod%' />"
            + "<input id='context' type='hidden' name='Context' value='%Context%' />"
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
