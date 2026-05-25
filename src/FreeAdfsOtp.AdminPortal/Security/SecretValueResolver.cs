using System.Security.Cryptography;
using System.Text;

namespace FreeAdfsOtp.AdminPortal.Security;

internal static class SecretValueResolver
{
    public static string? ResolveOptional(IConfiguration configuration, string directValueKey, string dpapiFilePathKey)
    {
        var directValue = configuration[directValueKey]?.Trim();
        if (!string.IsNullOrWhiteSpace(directValue))
        {
            return directValue;
        }

        var dpapiFilePath = configuration[dpapiFilePathKey]?.Trim();
        if (string.IsNullOrWhiteSpace(dpapiFilePath))
        {
            return null;
        }

        return ReadDpapiSecretFromFile(dpapiFilePath);
    }

    private static string ReadDpapiSecretFromFile(string filePath)
    {
        var expandedPath = Environment.ExpandEnvironmentVariables(filePath);
        if (!Path.IsPathRooted(expandedPath))
        {
            expandedPath = Path.GetFullPath(expandedPath);
        }

        if (!File.Exists(expandedPath))
        {
            throw new FileNotFoundException($"DPAPI secret file not found: {expandedPath}");
        }

        var protectedPayloadBase64 = File.ReadAllText(expandedPath).Trim();
        if (string.IsNullOrWhiteSpace(protectedPayloadBase64))
        {
            throw new InvalidOperationException($"DPAPI secret file is empty: {expandedPath}");
        }

        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("DPAPI secret files are supported only on Windows.");
        }

        var protectedPayload = Convert.FromBase64String(protectedPayloadBase64);
        var rawSecret = ProtectedData.Unprotect(protectedPayload, null, DataProtectionScope.LocalMachine);
        return Encoding.UTF8.GetString(rawSecret).Trim();
    }
}
