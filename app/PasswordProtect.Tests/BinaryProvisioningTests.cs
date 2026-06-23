using Xunit;
using System.Reflection;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

public class BinaryProvisioningTests
{
    // SHA-256 of TestResources/sample.bin (44 bytes, embedded as PPTEST.sample.bin).
    private const string SampleSha256 = "b9cdd935782a40d4db30b91e5aa700a1179ed23d012d7ab696b0576d43359f2a";
    private const string SampleResource = "PPTEST.sample.bin";

    [Fact]
    public void HashPins_parses_sha256sum_style_lines()
    {
        const string content = """
            # a comment
            c14dd98df81c1bdfaaf16bf9f8804eb88e4c643ee55a7e5fdc21454dd88cab54 *qpdf.exe
            b0cfdeaf429f5cc53f85123dd8f5a5feb92c19d31aa34df257edf9a26be05f95 *7z.exe

            """;
        var pins = HashPins.Parse(content);
        Assert.Equal(2, pins.Count);
        Assert.Equal("c14dd98df81c1bdfaaf16bf9f8804eb88e4c643ee55a7e5fdc21454dd88cab54", pins["qpdf.exe"]);
        Assert.True(pins.ContainsKey("7z.exe"));
    }

    [Fact]
    public void Extractor_writes_file_when_hash_matches()
    {
        using var dir = new TempDir();
        string dest = dir.File("sample.bin");
        BinaryExtractor.ExtractResource(Asm, SampleResource, dest, SampleSha256);

        Assert.True(File.Exists(dest));
        Assert.True(BinaryExtractor.VerifyExisting(dest, SampleSha256));
    }

    [Fact]
    public void Extractor_refuses_on_hash_mismatch()
    {
        using var dir = new TempDir();
        string dest = dir.File("sample.bin");
        string wrong = new string('0', 64);

        Assert.Throws<InvalidDataException>(() =>
            BinaryExtractor.ExtractResource(Asm, SampleResource, dest, wrong));
        Assert.False(File.Exists(dest)); // never left a usable file behind
    }

    [Fact]
    public void VerifyExisting_false_for_missing_file()
    {
        Assert.False(BinaryExtractor.VerifyExisting(Path.Combine(Path.GetTempPath(), "nope.bin"), SampleSha256));
    }

    private static Assembly Asm => typeof(BinaryProvisioningTests).Assembly;
}
