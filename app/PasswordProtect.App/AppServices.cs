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
            .Register(OutputFormat.SevenZip, new SevenZipProtector(Binaries))
            .Register(OutputFormat.OfficeNative, new OfficeProtector());

        Batch = new BatchRunner(Registry);
        Naming = new NamingEngine();
    }

    /// <summary>Resolve format + smart output name for one input file.</summary>
    public ProtectionJob BuildJob(string input)
    {
        OutputFormat fmt = FormatResolver.Resolve(input, Settings.OfficeFormat);
        if (!Registry.Supports(fmt)) fmt = OutputFormat.SevenZip; // graceful fallback

        string ext = FormatResolver.OutputExtension(input, fmt);
        var ctx = new NamingContext
        {
            InputPath = input,
            OutputExtension = ext,
            Template = Settings.NamingTemplate,
            AllowOverwrite = Settings.AllowOverwrite,
        };
        string outPath = Naming.BuildFullPath(ctx);
        return new ProtectionJob { InputPath = input, Format = fmt, OutputPath = outPath };
    }
}
