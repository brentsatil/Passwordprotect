using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;

namespace PasswordProtect.Core;

/// <summary>
/// Best-effort plain-text extraction for detection. Bounded (first few PDF pages,
/// capped characters) and fail-soft: any error (encrypted/corrupt/unsupported)
/// yields an empty string so detection simply finds nothing.
/// </summary>
public static partial class DocumentTextExtractor
{
    private const int MaxChars = 20_000;
    private const int MaxPdfPages = 5;

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex XmlTags();

    public static string Extract(string path)
    {
        try
        {
            return Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".pdf" => ExtractPdf(path),
                ".docx" or ".xlsx" or ".pptx" => ExtractOoxml(path),
                _ => "",
            };
        }
        catch
        {
            return "";
        }
    }

    private static string ExtractPdf(string path)
    {
        var sb = new StringBuilder();
        using var doc = PdfDocument.Open(path);
        int pages = Math.Min(doc.NumberOfPages, MaxPdfPages);
        for (int i = 1; i <= pages && sb.Length < MaxChars; i++)
            sb.Append(doc.GetPage(i).Text).Append('\n');
        return Cap(sb.ToString());
    }

    private static string ExtractOoxml(string path)
    {
        var sb = new StringBuilder();
        using ZipArchive zip = ZipFile.OpenRead(path);
        foreach (ZipArchiveEntry entry in zip.Entries)
        {
            if (sb.Length >= MaxChars) break;
            string name = entry.FullName;
            bool wanted = (name.StartsWith("word/", StringComparison.Ordinal)
                           || name.StartsWith("xl/", StringComparison.Ordinal)
                           || name.StartsWith("ppt/", StringComparison.Ordinal))
                          && name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase);
            if (!wanted) continue;

            using var reader = new StreamReader(entry.Open());
            string xml = reader.ReadToEnd();
            sb.Append(XmlTags().Replace(xml, " ")).Append('\n');
        }
        return Cap(sb.ToString());
    }

    private static string Cap(string s) => s.Length <= MaxChars ? s : s[..MaxChars];
}
