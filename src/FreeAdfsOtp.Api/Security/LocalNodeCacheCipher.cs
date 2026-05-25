using System.Security.Cryptography;
using System.Text;

namespace FreeAdfsOtp.Api.Security;

public sealed class LocalNodeCacheCipher
{
    private readonly byte[] _key;

    public LocalNodeCacheCipher(IConfiguration configuration)
    {
        var base64MasterKey = SecretValueResolver.ResolveRequired(
            configuration,
            "SecretProtection:MasterKey",
            "SecretProtection:MasterKeyDpapiFilePath",
            "SecretProtection:MasterKey");

        var masterKey = Convert.FromBase64String(base64MasterKey);
        if (masterKey.Length is not 32)
        {
            throw new InvalidOperationException("SecretProtection:MasterKey must be 32 bytes in base64.");
        }

        var nodeSalt = configuration["LocalCache:NodeKeySalt"] ?? string.Empty;
        var nodeMaterial = Encoding.UTF8.GetBytes($"{Environment.MachineName}|{nodeSalt}");
        _key = HMACSHA256.HashData(masterKey, nodeMaterial);
    }

    public byte[] EncryptBytes(byte[] plainBytes)
    {
        using var aes = Aes.Create();
        aes.Key = _key;
        aes.GenerateIV();

        using var encryptor = aes.CreateEncryptor();
        var cipher = encryptor.TransformFinalBlock(plainBytes, 0, plainBytes.Length);

        var payload = new byte[1 + aes.IV.Length + cipher.Length];
        payload[0] = 1;
        aes.IV.CopyTo(payload, 1);
        cipher.CopyTo(payload, 1 + aes.IV.Length);
        return payload;
    }

    public byte[] DecryptBytes(byte[] payload)
    {
        if (payload.Length < 1 + 16)
        {
            throw new CryptographicException("Invalid local cache payload.");
        }

        var iv = new byte[16];
        Buffer.BlockCopy(payload, 1, iv, 0, iv.Length);

        var cipher = new byte[payload.Length - 1 - iv.Length];
        Buffer.BlockCopy(payload, 1 + iv.Length, cipher, 0, cipher.Length);

        using var aes = Aes.Create();
        aes.Key = _key;
        aes.IV = iv;

        using var decryptor = aes.CreateDecryptor();
        return decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
    }

    public string EncryptString(string plainText)
    {
        var encrypted = EncryptBytes(Encoding.UTF8.GetBytes(plainText));
        return Convert.ToBase64String(encrypted);
    }

    public string DecryptString(string cipherTextBase64)
    {
        var decrypted = DecryptBytes(Convert.FromBase64String(cipherTextBase64));
        return Encoding.UTF8.GetString(decrypted);
    }
}
