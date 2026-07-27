namespace PasswordProtect.Core;

/// <summary>Ported from the legacy <c>Add-LongPathPrefix</c> (src/Invoke-QPdf.ps1).</summary>
public static class LongPath
{
    public static string AddPrefix(string path)
    {
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
        if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.TrimStart('\\');
        return @"\\?\" + path;
    }
}
