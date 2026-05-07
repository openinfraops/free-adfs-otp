using System.Globalization;
using System.Security.Cryptography;
using FreeAdfsOtp.Core.Models;

namespace FreeAdfsOtp.Core.Services;

public static class TotpService
{
    public static bool ValidateCode(string code, byte[] secret, OtpSettings settings, DateTimeOffset utcNow, out long matchedTimeStep)
    {
        matchedTimeStep = -1;
        if (!IsNumericCode(code, settings.Digits))
        {
            return false;
        }

        var currentStep = utcNow.ToUnixTimeSeconds() / settings.StepSeconds;
        for (var skew = -settings.AllowedSkewSteps; skew <= settings.AllowedSkewSteps; skew++)
        {
            var step = currentStep + skew;
            var expected = ComputeCode(secret, step, settings.Digits);
            if (FixedTimeEquals(code, expected))
            {
                matchedTimeStep = step;
                return true;
            }
        }

        return false;
    }

    public static string ComputeCode(byte[] secret, long timeStep, int digits)
    {
        Span<byte> stepBytes = stackalloc byte[8];
        var networkStep = BitConverter.IsLittleEndian
            ? BitConverter.GetBytes(timeStep).Reverse().ToArray()
            : BitConverter.GetBytes(timeStep);

        networkStep.CopyTo(stepBytes);

        using var hmac = new HMACSHA1(secret);
        var hash = hmac.ComputeHash(stepBytes.ToArray());
        var offset = hash[^1] & 0x0F;

        var binaryCode = ((hash[offset] & 0x7F) << 24)
            | ((hash[offset + 1] & 0xFF) << 16)
            | ((hash[offset + 2] & 0xFF) << 8)
            | (hash[offset + 3] & 0xFF);

        var otp = binaryCode % (int)Math.Pow(10, digits);
        return otp.ToString(CultureInfo.InvariantCulture).PadLeft(digits, '0');
    }

    private static bool IsNumericCode(string code, int digits)
    {
        return code.Length == digits && code.All(char.IsDigit);
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = System.Text.Encoding.UTF8.GetBytes(left);
        var rightBytes = System.Text.Encoding.UTF8.GetBytes(right);
        return CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }
}
