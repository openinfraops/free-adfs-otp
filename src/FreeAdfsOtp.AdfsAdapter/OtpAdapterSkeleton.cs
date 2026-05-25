using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace FreeAdfsOtp.AdfsAdapter;

public sealed class OtpAdapterSkeleton
{
    public sealed class ValidationResponse
    {
        public bool IsSuccess { get; set; }
        public bool IsLocked { get; set; }
    }

    private readonly HttpClient _httpClient;
    private readonly Uri _apiBaseUrl;
    private readonly string _adapterApiKey;

    public OtpAdapterSkeleton(Uri apiBaseUrl, HttpClient httpClient = null, string adapterApiKey = null)
    {
        _apiBaseUrl = apiBaseUrl;
        _httpClient = httpClient ?? new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(3)
        };
        _adapterApiKey = adapterApiKey ?? string.Empty;
    }

    public async Task<bool> IsUserEnrolledAsync(string upn)
    {
        var url = new Uri(_apiBaseUrl, $"/otp/enrollment-status/{Uri.EscapeDataString(upn)}");
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        AddAdapterAuthHeader(request);
        using var response = await _httpClient.SendAsync(request).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync().ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            return false;
        }

        return payload.IndexOf("\"isEnrolled\":true", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public async Task<ValidationResponse> ValidateOtpAsync(string upn, string code, string clientIp, string userAgent, Guid? correlationId)
    {
        var url = new Uri(_apiBaseUrl, "/otp/validate");
        var json = "{" +
            $"\"userPrincipalName\":\"{EscapeJson(upn)}\"," +
            $"\"code\":\"{EscapeJson(code)}\"," +
            $"\"clientIp\":\"{EscapeJson(clientIp)}\"," +
            $"\"userAgent\":\"{EscapeJson(userAgent)}\"," +
            (correlationId.HasValue ? $"\"correlationId\":\"{correlationId.Value:D}\"" : "\"correlationId\":null") +
            "}";

        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        AddAdapterAuthHeader(request);
        using var response = await _httpClient.SendAsync(request).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync().ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            return new ValidationResponse { IsSuccess = false, IsLocked = false };
        }

        var isSuccess = payload.IndexOf("\"isSuccess\":true", StringComparison.OrdinalIgnoreCase) >= 0;
        if (isSuccess)
        {
            return new ValidationResponse { IsSuccess = true, IsLocked = false };
        }

        var isLocked = payload.IndexOf("\"failureReason\":2", StringComparison.OrdinalIgnoreCase) >= 0
            || payload.IndexOf("\"failureReason\":\"Locked\"", StringComparison.OrdinalIgnoreCase) >= 0;

        return new ValidationResponse
        {
            IsSuccess = false,
            IsLocked = isLocked
        };
    }

    private static string EscapeJson(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private void AddAdapterAuthHeader(HttpRequestMessage request)
    {
        if (!string.IsNullOrWhiteSpace(_adapterApiKey))
        {
            request.Headers.TryAddWithoutValidation("X-Adapter-ApiKey", _adapterApiKey);
        }
    }
}
