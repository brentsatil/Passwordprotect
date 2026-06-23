using System.Globalization;
using System.Text.RegularExpressions;

namespace PasswordProtect.Core;

/// <summary>Best-effort fields detected inside a document; null when not found.</summary>
public sealed record DetectedFields(string? Name, string? Date)
{
    public static readonly DetectedFields None = new(null, null);
}

/// <summary>
/// Pure, best-effort extraction of a candidate name and date from document text.
/// Deliberately conservative: it only returns a name when it sits next to an
/// explicit label (Name:/Client:/Prepared for:/…) and only returns a date it can
/// actually parse, normalised to yyyy-MM-dd. No text means no fields.
/// </summary>
public static partial class FieldDetector
{
    private static readonly string[] MonthNames =
    {
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    };

    [GeneratedRegex(@"\b(\d{4})-(\d{2})-(\d{2})\b")]
    private static partial Regex IsoDate();

    // dd/MM/yyyy, dd-MM-yyyy, dd.MM.yyyy (UK-style day-first; advice docs).
    [GeneratedRegex(@"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})\b")]
    private static partial Regex NumericDate();

    // "1 March 1970" / "01 March 1970".
    [GeneratedRegex(@"\b(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})\b")]
    private static partial Regex DayMonthYear();

    [GeneratedRegex(@"(?:Name|Client|Client name|Prepared for|Account holder|Policyholder)\s*[:\-]\s*([A-Z][\p{L}'’.\-]+(?:\s+[A-Z][\p{L}'’.\-]+){0,3})")]
    private static partial Regex NameLabel();

    public static DetectedFields Detect(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return DetectedFields.None;
        return new DetectedFields(DetectName(text), DetectDate(text));
    }

    public static string? DetectName(string text)
    {
        Match m = NameLabel().Match(text);
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }

    public static string? DetectDate(string text)
    {
        Match iso = IsoDate().Match(text);
        if (iso.Success && TryDate(int.Parse(iso.Groups[3].Value), int.Parse(iso.Groups[2].Value), int.Parse(iso.Groups[1].Value), out string isoOut))
            return isoOut;

        Match dmy = DayMonthYear().Match(text);
        if (dmy.Success)
        {
            int month = Array.IndexOf(MonthNames, dmy.Groups[2].Value.ToLowerInvariant()) + 1;
            if (month >= 1 &&
                TryDate(int.Parse(dmy.Groups[1].Value), month, int.Parse(dmy.Groups[3].Value), out string dmyOut))
                return dmyOut;
        }

        Match num = NumericDate().Match(text);
        if (num.Success &&
            TryDate(int.Parse(num.Groups[1].Value), int.Parse(num.Groups[2].Value), int.Parse(num.Groups[3].Value), out string numOut))
            return numOut;

        return null;
    }

    private static bool TryDate(int day, int month, int year, out string normalized)
    {
        normalized = "";
        if (year < 1900 || year > 9999 || month < 1 || month > 12 || day < 1 || day > 31) return false;
        try
        {
            var d = new DateTime(year, month, day);
            normalized = d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            return true;
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }
    }
}
