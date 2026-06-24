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
    /// Office encryption is implemented (OfficeProtector) but inert pending a working
    /// backend (NPOI's agile write path is broken on .NET), so this defaults to
    /// <see cref="OutputFormat.SevenZip"/>; it becomes a per-type choice once native
    /// Office is re-enabled.
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
