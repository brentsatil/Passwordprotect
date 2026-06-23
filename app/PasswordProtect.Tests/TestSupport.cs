using PasswordProtect.Core;

namespace PasswordProtect.Tests;

/// <summary>Locates the bundled binaries copied next to the test assembly.</summary>
internal static class TestBinaries
{
    public static string NativeBinDir => Path.Combine(AppContext.BaseDirectory, "nativebin");

    /// <summary>Engine round-trips only run on Windows where the .exe payload can execute.</summary>
    public static bool Available =>
        OperatingSystem.IsWindows() && File.Exists(Path.Combine(NativeBinDir, "qpdf.exe"));

    public static IBinaryProvider Provider() => new DirectoryBinaryProvider(NativeBinDir, verify: false);
}

/// <summary>Creates and cleans up unique scratch directories for a test.</summary>
internal sealed class TempDir : IDisposable
{
    public string Path { get; }

    public TempDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "pp-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch { /* best effort */ }
    }
}

/// <summary>Builds a minimal, qpdf-normalised PDF — same recipe as windows-ci.yml.</summary>
internal static class TestPdf
{
    private static readonly string[] RawLines =
    {
        "%PDF-1.4",
        "1 0 obj",
        "<< /Type /Catalog /Pages 2 0 R >>",
        "endobj",
        "2 0 obj",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "endobj",
        "3 0 obj",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>",
        "endobj",
        "4 0 obj",
        "<< /Length 40 >>",
        "stream",
        "BT /F1 24 Tf 72 720 Td (Hello CI) Tj ET",
        "endstream",
        "endobj",
        "trailer",
        "<< /Root 1 0 R >>",
        "%%EOF",
    };

    public static async Task<string> CreateAsync(string qpdfPath, string dir)
    {
        string raw = Path.Combine(dir, "raw.pdf");
        File.WriteAllLines(raw, RawLines, System.Text.Encoding.ASCII);
        string clean = Path.Combine(dir, "clean.pdf");
        var res = await NativeProcessRunner.RunAsync(qpdfPath, new[] { raw, clean });
        if (res.ExitCode == 2 || !File.Exists(clean))
            throw new InvalidOperationException("qpdf could not normalise the test PDF: " + res.StdErr);
        return clean;
    }
}
