using System.Text;

namespace PasswordProtect.Core;

/// <summary>Make an arbitrary string safe to use as a Windows file name.</summary>
public static class FilenameSanitizer
{
    public static string SanitizeFileName(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "_";

        char[] invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(name.Length);
        foreach (char c in name)
            sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);

        // Windows forbids trailing dots/spaces on a file name component.
        string cleaned = sb.ToString().Trim().TrimEnd('.', ' ');
        return cleaned.Length == 0 ? "_" : cleaned;
    }
}
