using Xunit;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

public class NamingTests
{
    private static readonly DateTimeOffset Fixed =
        new(2026, 3, 1, 9, 30, 0, TimeSpan.Zero); // 01 Mar 2026

    private static string InDir(string fileName) => Path.Combine(Path.GetTempPath(), fileName);

    [Fact]
    public void Template_expands_known_tokens()
    {
        var tokens = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["OriginalName"] = "Statement",
            ["Ext"] = ".pdf",
            ["DDMMYYYY"] = "01032026",
        };
        Assert.Equal("Statement_01032026.pdf",
            NameTemplate.Expand("{OriginalName}_{DDMMYYYY}{Ext}", tokens));
    }

    [Fact]
    public void Template_applies_numeric_format_to_seq()
    {
        var tokens = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Seq"] = "7" };
        Assert.Equal("007", NameTemplate.Expand("{Seq:000}", tokens));
    }

    [Fact]
    public void Template_leaves_unknown_tokens_verbatim()
    {
        var tokens = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        Assert.Equal("{Nope}", NameTemplate.Expand("{Nope}", tokens));
    }

    [Fact]
    public void Engine_default_template_matches_legacy_suffix()
    {
        var engine = new NamingEngine();
        var ctx = new NamingContext
        {
            InputPath = InDir("Statement.pdf"),
            OutputExtension = ".pdf",
            Timestamp = Fixed,
        };
        Assert.Equal("Statement_protected.pdf", engine.BuildName(ctx));
    }

    [Fact]
    public void Engine_fills_detection_and_date_tokens()
    {
        var engine = new NamingEngine();
        var ctx = new NamingContext
        {
            InputPath = InDir("scan001.pdf"),
            OutputExtension = ".pdf",
            Template = "{DetectedName}_{Date}{Ext}",
            DetectedName = "Jane Doe",
            Timestamp = Fixed,
        };
        Assert.Equal("Jane Doe_2026-03-01.pdf", engine.BuildName(ctx));
    }

    [Fact]
    public void Sanitizer_collapses_blank_to_placeholder()
    {
        Assert.Equal("_", FilenameSanitizer.SanitizeFileName("   "));
    }

    [Fact]
    public void Sanitizer_replaces_platform_invalid_chars()
    {
        // Build a name containing whatever this platform deems invalid, plus a known-bad set.
        string bad = "a\0b" + new string(Path.GetInvalidFileNameChars());
        string cleaned = FilenameSanitizer.SanitizeFileName(bad);
        Assert.DoesNotContain('\0', cleaned);
        foreach (char c in Path.GetInvalidFileNameChars())
            Assert.DoesNotContain(c, cleaned);
    }

    [Fact]
    public void ResolveCollision_appends_sequence()
    {
        string baseName = InDir("f.7z");
        string two = InDir("f (2).7z");
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { baseName, two };

        string result = NamingEngine.ResolveCollision(baseName, p => taken.Contains(p));
        Assert.Equal(InDir("f (3).7z"), result);
    }

    [Theory]
    [InlineData("a.pdf", OutputFormat.Pdf)]
    [InlineData("a.txt", OutputFormat.SevenZip)]
    public void FormatResolver_picks_format(string fileName, OutputFormat expected)
    {
        Assert.Equal(expected, FormatResolver.Resolve(InDir(fileName), OutputFormat.SevenZip));
    }

    [Fact]
    public void FormatResolver_honours_office_choice()
    {
        Assert.Equal(OutputFormat.OfficeNative, FormatResolver.Resolve(InDir("a.docx"), OutputFormat.OfficeNative));
        Assert.Equal(OutputFormat.SevenZip, FormatResolver.Resolve(InDir("a.docx"), OutputFormat.SevenZip));
    }

    [Fact]
    public void FormatResolver_output_extension()
    {
        Assert.Equal(".pdf", FormatResolver.OutputExtension(InDir("a.pdf"), OutputFormat.Pdf));
        Assert.Equal(".7z", FormatResolver.OutputExtension(InDir("a.docx"), OutputFormat.SevenZip));
        Assert.Equal(".docx", FormatResolver.OutputExtension(InDir("a.docx"), OutputFormat.OfficeNative));
    }
}
