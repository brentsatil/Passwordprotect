using System.IO.Compression;
using System.Text;
using PasswordProtect.Core;
using Xunit;

namespace PasswordProtect.Tests;

public class PasswordEditTests
{
    private static readonly ProtectOptions Opts = new() { LongPathPrefix = false };

    private static byte[] MakeOoxml()
    {
        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            using var w = new StreamWriter(zip.CreateEntry("word/document.xml").Open(), new UTF8Encoding(false));
            w.Write("<document>secret</document>");
        }
        return ms.ToArray();
    }

    // ---- Office (managed, cross-platform) ----

    [Fact(Skip = "Native Office encryption is inert: NPOI's AgileEncryptionInfoBuilder is unresolvable in the NuGet package (2.6.2/2.7.1); Office falls back to .7z. Re-enable when NPOI is fixed.")]
    public async Task Office_add_change_remove_lifecycle()
    {
        using var dir = new TempDir();
        byte[] payload = MakeOoxml();
        string plainIn = dir.File("in.docx");
        File.WriteAllBytes(plainIn, payload);
        var p = new OfficeProtector();

        // Add p1
        string enc = dir.File("enc.docx");
        Assert.True((await p.ChangePasswordAsync(plainIn, enc, null, SecurePassword.FromString("p1"), PasswordEditMode.Add, Opts)).Success);
        Assert.True(OfficeCrypto.IsEncryptedOoxml(enc));

        // Change p1 -> p2
        string enc2 = dir.File("enc2.docx");
        var chg = await p.ChangePasswordAsync(enc, enc2, SecurePassword.FromString("p1"), SecurePassword.FromString("p2"), PasswordEditMode.Change, Opts);
        Assert.True(chg.Success, chg.Message);
        using (var ms = new MemoryStream()) Assert.False(OfficeCrypto.TryDecrypt(enc2, "p1", ms));
        using (var ms = new MemoryStream()) { Assert.True(OfficeCrypto.TryDecrypt(enc2, "p2", ms)); Assert.Equal(payload, ms.ToArray()); }

        // Wrong current password
        var wrong = await p.ChangePasswordAsync(enc2, dir.File("x.docx"), SecurePassword.FromString("nope"), SecurePassword.FromString("p3"), PasswordEditMode.Change, Opts);
        Assert.Equal(ProtectErrorCode.WrongPassword, wrong.Code);

        // Remove -> plain package back, byte-identical
        string plainOut = dir.File("plain.docx");
        var rem = await p.ChangePasswordAsync(enc2, plainOut, SecurePassword.FromString("p2"), null, PasswordEditMode.Remove, Opts);
        Assert.True(rem.Success, rem.Message);
        Assert.False(OfficeCrypto.IsEncryptedOoxml(plainOut));
        Assert.Equal(payload, File.ReadAllBytes(plainOut));
    }

    [Fact]
    public async Task Office_change_on_unprotected_is_not_protected()
    {
        using var dir = new TempDir();
        string plainIn = dir.File("in.docx");
        File.WriteAllBytes(plainIn, MakeOoxml());
        var p = new OfficeProtector();
        var res = await p.ChangePasswordAsync(plainIn, dir.File("o.docx"), SecurePassword.FromString("x"), SecurePassword.FromString("y"), PasswordEditMode.Change, Opts);
        Assert.Equal(ProtectErrorCode.NotProtected, res.Code);
    }

    // ---- PDF (real qpdf, Windows only) ----

    [Fact]
    public async Task Pdf_change_and_remove_password()
    {
        if (!TestBinaries.Available) return;
        var provider = TestBinaries.Provider();
        string qpdf = await provider.GetQpdfPathAsync();
        using var dir = new TempDir();
        string clean = await TestPdf.CreateAsync(qpdf, dir.Path);
        var p = new QpdfProtector(provider);

        string enc = dir.File("enc.pdf");
        Assert.True((await p.ProtectAsync(clean, enc, SecurePassword.FromString("p1"), Opts)).Success);

        string enc2 = dir.File("enc2.pdf");
        var chg = await p.ChangePasswordAsync(enc, enc2, SecurePassword.FromString("p1"), SecurePassword.FromString("p2"), PasswordEditMode.Change, Opts);
        Assert.True(chg.Success, chg.Message);

        Assert.NotEqual(2, (await NativeProcessRunner.RunAsync(qpdf, new[] { "--password=p2", "--decrypt", enc2, dir.File("d2.pdf") })).ExitCode);
        Assert.Equal(2, (await NativeProcessRunner.RunAsync(qpdf, new[] { "--password=p1", "--decrypt", enc2, dir.File("db.pdf") })).ExitCode);

        var wrong = await p.ChangePasswordAsync(enc2, dir.File("w.pdf"), SecurePassword.FromString("nope"), SecurePassword.FromString("p3"), PasswordEditMode.Change, Opts);
        Assert.Equal(ProtectErrorCode.WrongPassword, wrong.Code);

        string plain = dir.File("plain.pdf");
        var rem = await p.ChangePasswordAsync(enc2, plain, SecurePassword.FromString("p2"), null, PasswordEditMode.Remove, Opts);
        Assert.True(rem.Success, rem.Message);
        Assert.False(await p.IsProtectedAsync(plain));
    }

    // ---- 7z (real, Windows only) ----

    [Fact]
    public async Task SevenZip_change_and_remove_password()
    {
        if (!TestBinaries.Available) return;
        var provider = TestBinaries.Provider();
        string seven = await provider.GetSevenZipPathAsync();
        using var dir = new TempDir();
        string txt = dir.File("n.txt");
        await File.WriteAllTextAsync(txt, "secret data");
        var p = new SevenZipProtector(provider);

        string a = dir.File("a.7z");
        Assert.True((await p.ProtectAsync(txt, a, SecurePassword.FromString("p1"), Opts)).Success);

        string b = dir.File("b.7z");
        var chg = await p.ChangePasswordAsync(a, b, SecurePassword.FromString("p1"), SecurePassword.FromString("p2"), PasswordEditMode.Change, Opts);
        Assert.True(chg.Success, chg.Message);
        Assert.Equal(0, (await NativeProcessRunner.RunAsync(seven, new[] { "t", "-pp2", b })).ExitCode);
        Assert.NotEqual(0, (await NativeProcessRunner.RunAsync(seven, new[] { "t", "-pp1", b })).ExitCode);

        var wrong = await p.ChangePasswordAsync(b, dir.File("w.7z"), SecurePassword.FromString("nope"), SecurePassword.FromString("p3"), PasswordEditMode.Change, Opts);
        Assert.Equal(ProtectErrorCode.WrongPassword, wrong.Code);

        string c = dir.File("c.7z");
        var rem = await p.ChangePasswordAsync(b, c, SecurePassword.FromString("p2"), null, PasswordEditMode.Remove, Opts);
        Assert.True(rem.Success, rem.Message);
        // Unprotected archive lists without a password.
        Assert.Equal(0, (await NativeProcessRunner.RunAsync(seven, new[] { "l", c })).ExitCode);
    }
}
