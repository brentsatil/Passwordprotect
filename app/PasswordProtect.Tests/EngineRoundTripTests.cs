using Xunit;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

/// <summary>
/// Real encryption round-trips against the bundled qpdf/7z. These execute only on
/// Windows (where the .exe payload runs); on other hosts they no-op so the suite
/// stays green in a Linux dev container. CI runs them for real on windows-latest.
/// </summary>
public class EngineRoundTripTests
{
    private const string Password = "01031970";

    // Mirror the proven windows-ci smoke-test path (no \\?\ prefix). Long-path
    // prefixing itself is covered by LongPathTests.
    private static readonly ProtectOptions Opts = new() { LongPathPrefix = false };

    [Fact]
    public async Task Pdf_protect_then_verify_and_reject_wrong_password()
    {
        if (!TestBinaries.Available) return;

        var provider = TestBinaries.Provider();
        string qpdf = await provider.GetQpdfPathAsync();
        using var dir = new TempDir();
        string clean = await TestPdf.CreateAsync(qpdf, dir.Path);

        var protector = new QpdfProtector(provider);
        string outPath = dir.File("clean_protected.pdf");
        var res = await protector.ProtectAsync(clean, outPath, SecurePassword.FromString(Password), Opts);

        Assert.True(res.Success, res.Message);
        Assert.True(File.Exists(outPath));
        Assert.True(await protector.IsProtectedAsync(outPath));

        // Correct password decrypts (qpdf exit 0/3 ok, 2 = rejected).
        var dec = await NativeProcessRunner.RunAsync(qpdf,
            new[] { "--password=" + Password, "--decrypt", outPath, dir.File("dec.pdf") });
        Assert.NotEqual(2, dec.ExitCode);
        Assert.True(File.Exists(dir.File("dec.pdf")));

        // Wrong password is rejected with exit 2.
        var bad = await NativeProcessRunner.RunAsync(qpdf,
            new[] { "--password=WRONGPASS", "--decrypt", outPath, dir.File("bad.pdf") });
        Assert.Equal(2, bad.ExitCode);
    }

    [Fact]
    public async Task Pdf_already_encrypted_is_refused()
    {
        if (!TestBinaries.Available) return;

        var provider = TestBinaries.Provider();
        string qpdf = await provider.GetQpdfPathAsync();
        using var dir = new TempDir();
        string clean = await TestPdf.CreateAsync(qpdf, dir.Path);

        var protector = new QpdfProtector(provider);
        string first = dir.File("first.pdf");
        Assert.True((await protector.ProtectAsync(clean, first, SecurePassword.FromString(Password), Opts)).Success);

        // Protecting an already-encrypted PDF must fail closed.
        var second = await protector.ProtectAsync(first, dir.File("second.pdf"), SecurePassword.FromString(Password), Opts);
        Assert.False(second.Success);
        Assert.Equal(ProtectErrorCode.PreEncrypted, second.Code);
    }

    [Fact]
    public async Task SevenZip_protect_then_verify_and_reject_wrong_password()
    {
        if (!TestBinaries.Available) return;

        var provider = TestBinaries.Provider();
        string seven = await provider.GetSevenZipPathAsync();
        using var dir = new TempDir();
        string txt = dir.File("notes.txt");
        await File.WriteAllTextAsync(txt, "hello secret");

        var protector = new SevenZipProtector(provider);
        string outPath = dir.File("notes_protected.7z");
        var res = await protector.ProtectAsync(txt, outPath, SecurePassword.FromString(Password), Opts);

        Assert.True(res.Success, res.Message);
        Assert.True(File.Exists(outPath));

        var ok = await NativeProcessRunner.RunAsync(seven, new[] { "t", "-p" + Password, outPath });
        Assert.Equal(0, ok.ExitCode);

        // Header encryption is on (-mhe=on), so a wrong password fails the test.
        var bad = await NativeProcessRunner.RunAsync(seven, new[] { "t", "-pWRONGPASS", outPath });
        Assert.NotEqual(0, bad.ExitCode);
    }

    [Fact]
    public async Task Output_exists_without_overwrite_is_refused()
    {
        if (!TestBinaries.Available) return;

        var provider = TestBinaries.Provider();
        string seven = await provider.GetSevenZipPathAsync();
        using var dir = new TempDir();
        string txt = dir.File("a.txt");
        await File.WriteAllTextAsync(txt, "x");
        string outPath = dir.File("a.7z");
        await File.WriteAllTextAsync(outPath, "pre-existing");

        var protector = new SevenZipProtector(provider);
        var res = await protector.ProtectAsync(txt, outPath, SecurePassword.FromString(Password), new ProtectOptions { AllowOverwrite = false, LongPathPrefix = false });
        Assert.False(res.Success);
        Assert.Equal(ProtectErrorCode.OutputExists, res.Code);
    }
}
