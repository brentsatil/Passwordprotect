using System.Text;

namespace PasswordProtect.Core;

/// <summary>
/// Quote a single argument for a Windows CreateProcess command line per the
/// CommandLineToArgvW rules. Ported verbatim from the legacy
/// <c>ConvertTo-NativeArgString</c> (src/Invoke-QPdf.ps1). .NET's
/// <see cref="System.Diagnostics.ProcessStartInfo.ArgumentList"/> performs the
/// same quoting and is what the engines actually use; this is retained as a
/// unit-tested utility and for any place a joined command string is required.
/// </summary>
public static class ArgvQuoting
{
    private static readonly char[] NeedsQuoting = { ' ', '\t', '\n', '\v', '"' };

    public static string Quote(string? arg)
    {
        if (arg is null) return "\"\"";
        if (arg.Length > 0 && arg.IndexOfAny(NeedsQuoting) < 0) return arg;

        var sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char ch in arg)
        {
            if (ch == '\\')
            {
                backslashes++;
            }
            else if (ch == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
            }
            else
            {
                if (backslashes > 0) { sb.Append('\\', backslashes); backslashes = 0; }
                sb.Append(ch);
            }
        }
        if (backslashes > 0) sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    public static string Join(IEnumerable<string> args) =>
        string.Join(' ', args.Select(Quote));
}
