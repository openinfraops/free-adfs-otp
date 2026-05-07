using System.Security.Cryptography;
using FreeAdfsOtp.Core.Contracts;

namespace FreeAdfsOtp.Core.Services;

public sealed class AesSecretProtector : ISecretProtector
{
    private readonly byte[] _masterKey;

    public AesSecretProtector(string base64Key)
    {
        _masterKey = Convert.FromBase64String(base64Key);
        if (_masterKey.Length is not 32)
        {
            throw new InvalidOperationException("SecretProtection:MasterKey must be 32 bytes in base64.");
        }
    }

    public byte[] Protect(byte[] rawSecret, int keyVersion)
    {
        using var aes = Aes.Create();
        aes.Key = _masterKey;
        aes.GenerateIV();

        using var encryptor = aes.CreateEncryptor();
        var cipher = encryptor.TransformFinalBlock(rawSecret, 0, rawSecret.Length);

        var result = new byte[1 + 4 + aes.IV.Length + cipher.Length];
        result[0] = 1;
        BitConverter.GetBytes(keyVersion).CopyTo(result, 1);
        aes.IV.CopyTo(result, 5);
        cipher.CopyTo(result, 5 + aes.IV.Length);
        return result;
    }

    public byte[] Unprotect(byte[] protectedSecret, int keyVersion)
    {
        if (protectedSecret.Length < 5 + 16)
        {
            throw new CryptographicException("Invalid secret payload.");
        }

        var payloadVersion = BitConverter.ToInt32(protectedSecret, 1);
        if (payloadVersion != keyVersion)
        {
            throw new CryptographicException("Secret key version mismatch.");
        }

        var iv = new byte[16];
        Buffer.BlockCopy(protectedSecret, 5, iv, 0, iv.Length);

        var cipherLength = protectedSecret.Length - 5 - iv.Length;
        var cipher = new byte[cipherLength];
        Buffer.BlockCopy(protectedSecret, 5 + iv.Length, cipher, 0, cipherLength);

        using var aes = Aes.Create();
        aes.Key = _masterKey;
        aes.IV = iv;

        using var decryptor = aes.CreateDecryptor();
        return decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
    }
}
