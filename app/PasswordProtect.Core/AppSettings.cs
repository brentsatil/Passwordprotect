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
    /// What Office documents (.docx/.xlsx/.pptx) are protected as. Native in-kind
    /// Office encryption is implemented (OfficeProtector) but currently inert due to
    /// an NPOI packaging defect, so this defaults to <see cref="OutputFormat.SevenZip"/>;
    /// once the native path is registered it becomes a per-type choice.
    /// </summary>
    public OutputFormat OfficeFormat { get; set; } = OutputFormat.SevenZip;

    public string NamingTemplate { get; set; } = "{OriginalName}_protected{Ext}";
    public int MaxParallel { get; set; } = 4;

    public ProtectOptions ToProtectOptions() => new()
    {
        AllowOverwrite = AllowOverwrite,
        LongPathPrefix = LongPathPrefix,
    };
}
