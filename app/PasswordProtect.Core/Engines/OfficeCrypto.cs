using NPOI.POIFS.Crypt;
using NPOI.POIFS.FileSystem;

namespace PasswordProtect.Core;

/// <summary>
/// Native ECMA-376 Agile Encryption for OOXML documents, via NPOI. An encrypted
/// Office file is an OLE/CFB compound document (magic D0 CF 11 E0 …) whose
/// EncryptedPackage stream holds the AES-256 encrypted .docx/.xlsx/.pptx zip and
/// whose EncryptionInfo stream describes the agile parameters (AES-256 + SHA-512).
/// The result opens directly in Office with no extra tooling.
/// </summary>
public static class OfficeCrypto
{
    private static readonly byte[] CfbMagic = { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

    private static byte[] RandomBytes(int count)
    {
        var bytes = new byte[count];
        System.Security.Cryptography.RandomNumberGenerator.Fill(bytes);
        return bytes;
    }

    static OfficeCrypto()
    {
        // NPOI's EncryptionInfo(EncryptionMode.Agile) resolves its builder by scanning
        // the ALREADY-LOADED assemblies for NPOI.POIFS.Crypt.Agile.AgileEncryptionInfoBuilder
        // (which lives in NPOI.OOXML) and throws "Not found type" if that assembly has not
        // been loaded yet. A discarded `typeof(...)` reference is optimized away in Release,
        // so we actually instantiate the builder here to guarantee NPOI.OOXML is loaded
        // before any encryption call.
        _ = new NPOI.POIFS.Crypt.Agile.AgileEncryptionInfoBuilder();
    }

    /// <summary>True if the file is an encrypted OOXML (CFB container) rather than a plain zip.</summary>
    public static bool IsEncryptedOoxml(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            Span<byte> head = stackalloc byte[8];
            if (fs.Read(head) < 8) return false;
            for (int i = 0; i < CfbMagic.Length; i++)
                if (head[i] != CfbMagic[i]) return false;
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Encrypt an OOXML package with agile encryption.</summary>
    public static void Encrypt(string inputOoxml, string outputPath, string password)
    {
        var info = new EncryptionInfo(EncryptionMode.Agile);
        Encryptor enc = info.Encryptor;

        // NPOI's convenience ConfirmPassword(string) overload forwards
        // verifier/verifierSalt in the wrong order, which NREs the agile encryptor.
        // Call the full overload directly with correctly-ordered, randomly generated
        // material (the path NPOI's own TestEncryptor uses). Sizes are the agile
        // AES-256 / SHA-512 defaults: 32-byte package key, 16-byte salts/verifier,
        // 64-byte integrity (HMAC) key.
        enc.ConfirmPassword(
            password,
            RandomBytes(32),  // keySpec  (AES-256 package key)
            RandomBytes(16),  // keySalt
            RandomBytes(16),  // verifier (verifierHashInput)
            RandomBytes(16),  // verifierSalt
            RandomBytes(64)); // integritySalt (SHA-512 HMAC key)

        var poifs = new POIFSFileSystem(); // not IDisposable in NPOI — Close() in finally
        try
        {
            using (Stream os = enc.GetDataStream(poifs))
            using (Stream input = File.OpenRead(inputOoxml))
            {
                input.CopyTo(os);
            }
            using Stream outFile = File.Create(outputPath);
            poifs.WriteFileSystem(outFile);
        }
        finally
        {
            poifs.Close();
        }
    }

    /// <summary>
    /// Verify the password and, if correct, write the decrypted OOXML package to
    /// <paramref name="destination"/>. Returns false (writing nothing) on a wrong password.
    /// </summary>
    public static bool TryDecrypt(string encryptedPath, string password, Stream destination)
    {
        using var fileIn = File.OpenRead(encryptedPath);
        var poifs = new POIFSFileSystem(fileIn);
        try
        {
            var info = new EncryptionInfo(poifs);
            Decryptor dec = Decryptor.GetInstance(info);
            if (!dec.VerifyPassword(password)) return false;

            using Stream data = dec.GetDataStream(poifs);
            data.CopyTo(destination);
            return true;
        }
        finally
        {
            poifs.Close();
        }
    }
}
