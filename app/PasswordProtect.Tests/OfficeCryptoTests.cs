using System.IO.Compression;
using PasswordProtect.Core;
using Xunit;

namespace PasswordProtect.Tests;

/// <summary>
/// Native Office agile-encryption round-trips. NPOI is fully managed, so these
/// run on every OS (no Windows guard needed). "Opens in real Office" is a manual
/// checklist item; here we prove the crypto round-trips and rejects bad passwords.
/// </summary>
public class OfficeCryptoTests
{
    private static byte[] MakeFakeOoxmlPackage()
    {
        // A real .docx is a zip; for the crypto round-trip any zip payload works.
        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            ZipArchiveEntry entry = zip.CreateEntry("word/document.xml");
            using var w = new StreamWriter(entry.Open());
            w.Write("<document>hello</document>");
        }
        return ms.ToArray();
    }

    [Fact]
    public void Encrypt_then_decrypt_roundtrips_and_rejects_wrong_password()
    {
        using var dir = new TempDir();
        string docx = dir.File("doc.docx");
        byte[] payload = MakeFakeOoxmlPackage();
        File.WriteAllBytes(docx, payload);

        string enc = dir.File("doc_protected.docx");
        OfficeCrypto.Encrypt(docx, enc, "secret");

        Assert.True(OfficeCrypto.IsEncryptedOoxml(enc));   // CFB container
        Assert.False(OfficeCrypto.IsEncryptedOoxml(docx)); // plain zip

        using (var ok = new MemoryStream())
        {
            Assert.True(OfficeCrypto.TryDecrypt(enc, "secret", ok));
            Assert.Equal(payload, ok.ToArray());
        }

        using (var bad = new MemoryStream())
        {
            Assert.False(OfficeCrypto.TryDecrypt(enc, "wrong", bad));
            Assert.Empty(bad.ToArray());
        }
    }

    [Fact]
    public async Task OfficeProtector_protects_and_refuses_preencrypted()
    {
        using var dir = new TempDir();
        string docx = dir.File("d.docx");
        File.WriteAllBytes(docx, MakeFakeOoxmlPackage());

        var protector = new OfficeProtector();
        string outPath = dir.File("d_protected.docx");

        var res = await protector.ProtectAsync(
            docx, outPath, SecurePassword.FromString("pw"), new ProtectOptions { LongPathPrefix = false });
        Assert.True(res.Success, res.Message);
        Assert.True(await protector.IsProtectedAsync(outPath));

        // Re-protecting an already-encrypted Office file fails closed.
        var second = await protector.ProtectAsync(
            outPath, dir.File("again.docx"), SecurePassword.FromString("pw"), new ProtectOptions { LongPathPrefix = false });
        Assert.False(second.Success);
        Assert.Equal(ProtectErrorCode.PreEncrypted, second.Code);
    }
}
