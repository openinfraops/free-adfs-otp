using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace FreeAdfsOtp.AdfsAdapter;

public sealed class OtpAdapterSkeleton
{
    private readonly HttpClient _httpClient;
    private readonly Uri _apiBaseUrl;

    public OtpAdapterSkeleton(Uri apiBaseUrl, HttpClient httpClient = null)
    {
        _apiBaseUrl = apiBaseUrl;
        _httpClient = httpClient ?? new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(3)
        };
    }

    public async Task<bool> IsUserEnrolledAsync(string upn)
    {
        var url = new Uri(_apiBaseUrl, $"/otp/enrollment-status/{Uri.EscapeDataString(upn)}");
        using var response = await _httpClient.GetAsync(url).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync().ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            return false;
        }

        return payload.IndexOf("\"isEnrolled\":true", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public async Task<bool> ValidateOtpAsync(string upn, string code, string clientIp, string userAgent, Guid? correlationId)
    {
        var url = new Uri(_apiBaseUrl, "/otp/validate");
        var json = "{" +
            $"\"userPrincipalName\":\"{EscapeJson(upn)}\"," +
            $"\"code\":\"{EscapeJson(code)}\"," +
            $"\"clientIp\":\"{EscapeJson(clientIp)}\"," +
            $"\"userAgent\":\"{EscapeJson(userAgent)}\"," +
            (correlationId.HasValue ? $"\"correlationId\":\"{correlationId.Value:D}\"" : "\"correlationId\":null") +
            "}";

        using var content = new StringContent(json, Encoding.UTF8, "application/json");
        using var response = await _httpClient.PostAsync(url, content).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync().ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            return false;
        }

        return payload.IndexOf("\"isSuccess\":true", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string EscapeJson(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
