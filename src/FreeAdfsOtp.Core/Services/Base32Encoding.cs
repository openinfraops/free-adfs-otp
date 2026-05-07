namespace FreeAdfsOtp.Core.Services;

public static class Base32Encoding
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string ToBase32(byte[] data)
    {
        if (data.Length == 0)
        {
            return string.Empty;
        }

        var output = new char[(int)Math.Ceiling(data.Length / 5d) * 8];
        var bitBuffer = 0;
        var bitBufferLength = 0;
        var outputIndex = 0;

        foreach (var b in data)
        {
            bitBuffer = (bitBuffer << 8) | b;
            bitBufferLength += 8;

            while (bitBufferLength >= 5)
            {
                var index = (bitBuffer >> (bitBufferLength - 5)) & 0x1F;
                output[outputIndex++] = Alphabet[index];
                bitBufferLength -= 5;
            }
        }

        if (bitBufferLength > 0)
        {
            var index = (bitBuffer << (5 - bitBufferLength)) & 0x1F;
            output[outputIndex++] = Alphabet[index];
        }

        while (outputIndex % 8 != 0)
        {
            output[outputIndex++] = '=';
        }

        return new string(output, 0, outputIndex);
    }

    public static byte[] FromBase32(string input)
    {
        var sanitized = input.Trim().TrimEnd('=').ToUpperInvariant();
        if (sanitized.Length == 0)
        {
            return Array.Empty<byte>();
        }

        var bytes = new List<byte>();
        var bitBuffer = 0;
        var bitBufferLength = 0;

        foreach (var c in sanitized)
        {
            var index = Alphabet.IndexOf(c);
            if (index < 0)
            {
                throw new FormatException("Invalid Base32 character.");
            }

            bitBuffer = (bitBuffer << 5) | index;
            bitBufferLength += 5;

            if (bitBufferLength >= 8)
            {
                bytes.Add((byte)((bitBuffer >> (bitBufferLength - 8)) & 0xFF));
                bitBufferLength -= 8;
            }
        }

        return bytes.ToArray();
    }
}
