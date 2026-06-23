using System.IO;
using System.Reflection;
using PasswordProtect.Core;

namespace PasswordProtect.App;

/// <summary>
/// Composition root. Wires the embedded-binary provisioner, the per-format
/// protector registry, the batch runner and the naming engine, and turns an
/// input path into a ready-to-run <see cref="ProtectionJob"/> using the current
/// settings (format choice, naming template, overwrite mode).
/// </summary>
public sealed class AppServices
{
    public IBinaryProvider Binaries { get; }
    public ProtectorRegistry Registry { get; }
    public BatchRunner Batch { get; }
    public NamingEngine Naming { get; }
    public AppSettings Settings { get; }

    public AppServices()
    {
        Settings = new AppSettings();

        var asm = Assembly.GetExecutingAssembly();
        string version = asm.GetName().Version?.ToString() ?? "0";
        string cache = EmbeddedBinaryProvisioner.DefaultCacheDir(version);
        Binaries = new EmbeddedBinaryProvisioner(asm, "PPNATIVE.", cache);

        Registry = new ProtectorRegistry()
            .Register(OutputFormat.Pdf, new QpdfProtector(Binaries))
            .Register(OutputFormat.SevenZip, new SevenZipProtector(Binaries));
        // Native Office (OfficeProtector) is implemented but not registered yet:
        // NPOI's agile-encryption builder is unresolvable in the NuGet package, so
        // Office requests fall back to .7z (see BuildJob). Re-register here once the
        // NPOI issue is resolved to enable the in-kind native Office option.

        Batch = new BatchRunner(Registry);
        Naming = new NamingEngine();
    }

    /// <summary>True when the current template uses an in-document detection token.</summary>
    public bool TemplateUsesDetection =>
        Settings.NamingTemplate.Contains("{Detected", StringComparison.OrdinalIgnoreCase);

    /// <summary>Best-effort detection of name/date inside a document (only when the template needs it).</summary>
    public async Task<DetectedFields> DetectAsync(string input, CancellationToken ct = default)
    {
        if (!TemplateUsesDetection) return DetectedFields.None;
        try
        {
            string text = await Task.Run(() => DocumentTextExtractor.Extract(input), ct).ConfigureAwait(false);
            return FieldDetector.Detect(text);
        }
        catch
        {
            return DetectedFields.None;
        }
    }

    /// <summary>Resolve format + smart output name for one input file.</summary>
    public ProtectionJob BuildJob(string input, DetectedFields? detected = null)
    {
        OutputFormat fmt = FormatResolver.Resolve(input, Settings.OfficeFormat);
        if (!Registry.Supports(fmt)) fmt = OutputFormat.SevenZip; // graceful fallback

        string ext = FormatResolver.OutputExtension(input, fmt);

        // Overwrite-in-place only makes sense when the output keeps the same
        // extension (PDF->pdf, Office native->same). When it does, the output IS
        // the original file; otherwise fall back to a new, smartly-named file.
        string inExt = Path.GetExtension(input);
        bool inPlace = Settings.AllowOverwrite && string.Equals(ext, inExt, StringComparison.OrdinalIgnoreCase);

        string outPath;
        if (inPlace)
        {
            outPath = input;
        }
        else
        {
            var ctx = new NamingContext
            {
                InputPath = input,
                OutputExtension = ext,
                Template = Settings.NamingTemplate,
                AllowOverwrite = false, // never silently clobber a different file
                DetectedName = detected?.Name,
                DetectedDate = detected?.Date,
            };
            outPath = Naming.BuildFullPath(ctx);
        }

        return new ProtectionJob { InputPath = input, Format = fmt, OutputPath = outPath };
    }
}
