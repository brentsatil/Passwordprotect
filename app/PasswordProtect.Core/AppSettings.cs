namespace PasswordProtect.Core;

/// <summary>
/// User-facing options. Defaults mirror config/settings.default.json from the
/// legacy tool. <see cref="OfficeFormat"/> defaults to .7z in Phase 1 and flips
/// to <see cref="OutputFormat.OfficeNative"/> once native Office encryption ships.
/// </summary>
public sealed class AppSettings
{
    public string OutputSuffix { get; set; } = "_protected";
    public bool LongPathPrefix { get; set; } = true;
    public bool AllowOverwrite { get; set; }

    /// <summary>
    /// What Office documents (.docx/.xlsx/.pptx) are protected as. Defaults to
    /// in-kind native encryption (a real protected .docx that opens in Office);
    /// the user can switch this to <see cref="OutputFormat.SevenZip"/> per the
    /// per-type choice.
    /// </summary>
    public OutputFormat OfficeFormat { get; set; } = OutputFormat.OfficeNative;

    public string NamingTemplate { get; set; } = "{OriginalName}_protected{Ext}";
    public int MaxParallel { get; set; } = 4;

    public ProtectOptions ToProtectOptions() => new()
    {
        AllowOverwrite = AllowOverwrite,
        LongPathPrefix = LongPathPrefix,
    };
}
