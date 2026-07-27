using System.Globalization;
using System.Text.RegularExpressions;

namespace PasswordProtect.Core;

/// <summary>
/// Expands a naming template containing <c>{Token}</c> placeholders. Unknown
/// tokens are left untouched so a typo degrades gracefully rather than vanishing.
/// <c>{Seq:000}</c>-style format specifiers apply .NET numeric formatting.
/// </summary>
public static partial class NameTemplate
{
    [GeneratedRegex(@"\{(?<name>[A-Za-z][A-Za-z0-9]*)(?::(?<fmt>[^}]+))?\}")]
    private static partial Regex TokenRegex();

    public static string Expand(string template, IReadOnlyDictionary<string, string> tokens)
    {
        return TokenRegex().Replace(template, match =>
        {
            string name = match.Groups["name"].Value;
            string? fmt = match.Groups["fmt"].Success ? match.Groups["fmt"].Value : null;

            if (!tokens.TryGetValue(name, out var value))
                return match.Value; // leave unknown token verbatim

            if (fmt != null && int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int n))
                return n.ToString(fmt, CultureInfo.InvariantCulture);

            return value;
        });
    }
}
