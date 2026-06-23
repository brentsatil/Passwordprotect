namespace PasswordProtect.Core;

/// <summary>The encryption form a given file is sent through.</summary>
public enum OutputFormat
{
    /// <summary>Native PDF AES-256 via qpdf.</summary>
    Pdf,
    /// <summary>Native ECMA-376 agile encryption (real protected .docx/.xlsx/.pptx).</summary>
    OfficeNative,
    /// <summary>Wrapped in an AES-256 .7z archive.</summary>
    SevenZip,
}

/// <summary>
/// Decides which <see cref="OutputFormat"/> handles an input, and what extension
/// the protected output should carry. Generalises the legacy <c>Get-OutputPath</c>
/// rule (".pdf keeps its extension; everything else becomes .7z") into a
/// user-configurable per-type choice for Office documents.
/// </summary>
public static class FormatResolver
{
    private static readonly HashSet<string> OfficeExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".docx", ".xlsx", ".pptx" };

    public static bool IsOffice(string path) => OfficeExtensions.Contains(Path.GetExtension(path));

    public static OutputFormat Resolve(string inputPath, OutputFormat officeChoice)
    {
        string ext = Path.GetExtension(inputPath);
        if (ext.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return OutputFormat.Pdf;
        if (OfficeExtensions.Contains(ext)) return officeChoice; // OfficeNative or SevenZip
        return OutputFormat.SevenZip;
    }

    /// <summary>Extension (with leading dot) of the protected output for a given format.</summary>
    public static string OutputExtension(string inputPath, OutputFormat format) => format switch
    {
        OutputFormat.SevenZip => ".7z",
        _ => Path.GetExtension(inputPath), // Pdf and OfficeNative keep the original extension
    };
}
