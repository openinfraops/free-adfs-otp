namespace FreeAdfsOtp.AdfsAdapter.AdapterRuntime;

public static class AdfsOtpAdapterConstants
{
    public const string AuthenticationMethodClaimType = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod";
    public const string AuthenticationMethodUri = "urn:freeadfsotp:method:totp";
    public const string MultipleAuthnMethodUri = "http://schemas.microsoft.com/claims/multipleauthn";
    public const string UpnClaimType = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn";
}
