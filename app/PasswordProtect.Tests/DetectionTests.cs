using System.IO.Compression;
using System.Text;
using PasswordProtect.Core;
using Xunit;

namespace PasswordProtect.Tests;

public class DetectionTests
{
    [Theory]
    [InlineData("Report dated 2026-03-01 for review", "2026-03-01")]
    [InlineData("Signed on 01/03/2026 by client", "2026-03-01")]
    [InlineData("Date of birth: 1 March 1970", "1970-03-01")]
    [InlineData("no date here", null)]
    public void DetectDate_normalises_to_iso(string text, string? expected)
    {
        Assert.Equal(expected, FieldDetector.DetectDate(text));
    }

    [Theory]
    [InlineData("Client: Jane Doe\nAccount 123", "Jane Doe")]
    [InlineData("Prepared for: John A. Smith", "John A. Smith")]
    [InlineData("just some text", null)]
    public void DetectName_uses_labels(string text, string? expected)
    {
        Assert.Equal(expected, FieldDetector.DetectName(text));
    }

    [Fact]
    public void Detect_empty_text_returns_none()
    {
        Assert.Equal(DetectedFields.None, FieldDetector.Detect(""));
        Assert.Equal(DetectedFields.None, FieldDetector.Detect(null));
    }

    [Fact]
    public void Extractor_reads_docx_text_and_feeds_detection()
    {
        using var dir = new TempDir();
        string docx = dir.File("advice.docx");
        WriteDocx(docx, "Client: Jane Doe — review meeting 1 March 1970 follow-up");

        string text = DocumentTextExtractor.Extract(docx);
        Assert.Contains("Jane Doe", text);

        DetectedFields fields = FieldDetector.Detect(text);
        Assert.Equal("Jane Doe", fields.Name);
        Assert.Equal("1970-03-01", fields.Date);
    }

    [Fact]
    public void Extractor_returns_empty_for_unsupported_or_unreadable()
    {
        using var dir = new TempDir();
        string txt = dir.File("a.txt");
        File.WriteAllText(txt, "anything");
        Assert.Equal("", DocumentTextExtractor.Extract(txt));
        Assert.Equal("", DocumentTextExtractor.Extract(dir.File("missing.pdf")));
    }

    private static void WriteDocx(string path, string bodyText)
    {
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        ZipArchiveEntry entry = zip.CreateEntry("word/document.xml");
        using var w = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        w.Write($"<?xml version=\"1.0\"?><w:document><w:body><w:p><w:r><w:t>{bodyText}</w:t></w:r></w:p></w:body></w:document>");
    }
}
