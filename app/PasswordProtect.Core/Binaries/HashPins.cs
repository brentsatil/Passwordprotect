using System.Security.Cryptography;

namespace PasswordProtect.Core;

/// <summary>
/// Parse and verify the sha256sum-style pins in bin/HASHES.txt
/// (lines: <c>&lt;64-hex&gt; *&lt;filename&gt;</c>, with <c>#</c> comments).
/// </summary>
public static class HashPins
{
    public static IReadOnlyDictionary<string, string> Parse(string content)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in content.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            int sp = line.IndexOf(' ');
            if (sp <= 0) continue;

            string hex = line[..sp].Trim();
            string rest = line[(sp + 1)..].Trim();
            if (rest.StartsWith('*')) rest = rest[1..];
            rest = rest.Trim();

            if (hex.Length == 64 && rest.Length > 0)
                map[Path.GetFileName(rest)] = hex.ToLowerInvariant();
        }
        return map;
    }

    public static string Sha256Hex(string filePath)
    {
        using var fs = File.OpenRead(filePath);
        return Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant();
    }

    public static string Sha256HexOfBytes(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}
