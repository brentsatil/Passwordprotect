using System.Reflection;

namespace PasswordProtect.Core;

/// <summary>
/// Extract an embedded native binary to disk with SHA-256 verification.
/// Fail-closed: a hash mismatch throws and never leaves a usable file in place.
/// Uses temp-then-atomic-move, matching the legacy engines' write pattern.
/// </summary>
public static class BinaryExtractor
{
    public static byte[] ReadResource(Assembly asm, string resourceName)
    {
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new FileNotFoundException($"Embedded resource not found: {resourceName}");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.ToArray();
    }

    public static void ExtractResource(Assembly asm, string resourceName, string destPath, string expectedHex)
    {
        byte[] data = ReadResource(asm, resourceName);
        string actual = HashPins.Sha256HexOfBytes(data);
        if (!string.Equals(actual, expectedHex, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException(
                $"Hash mismatch for '{resourceName}': expected {expectedHex}, got {actual}. Refusing to extract.");

        string dir = Path.GetDirectoryName(destPath)!;
        Directory.CreateDirectory(dir);
        string tmp = destPath + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, destPath, overwrite: true);
    }

    /// <summary>True when the file already exists on disk and its hash matches the pin.</summary>
    public static bool VerifyExisting(string path, string expectedHex) =>
        File.Exists(path) &&
        string.Equals(HashPins.Sha256Hex(path), expectedHex, StringComparison.OrdinalIgnoreCase);
}
