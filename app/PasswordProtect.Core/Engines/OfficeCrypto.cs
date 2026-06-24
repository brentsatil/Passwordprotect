using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using OpenMcdf;

namespace PasswordProtect.Core;

/// <summary>
/// Native ECMA-376 Agile Encryption for OOXML documents (MS-OFFCRYPTO), implemented
/// directly with <see cref="System.Security.Cryptography"/> + OpenMcdf — no NPOI,
/// whose agile write path is broken on .NET. An encrypted Office file is an OLE/CFB
/// compound document (magic D0 CF 11 E0 …) with two root streams: <c>EncryptionInfo</c>
/// (a version header + UTF-8 XML descriptor) and <c>EncryptedPackage</c> (an 8-byte
/// little-endian plaintext length followed by the AES-256-CBC encrypted .docx/.xlsx/
/// .pptx zip, in 4096-byte segments). Parameters are Office's defaults: AES-256,
/// SHA-512, 16-byte salts, spinCount 100000. The result opens directly in Office.
/// </summary>
public static class OfficeCrypto
{
    private static readonly byte[] CfbMagic = { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

    private const int SaltSize = 16;
    private const int BlockSize = 16;          // AES block / IV size
    private const int KeyBytes = 32;           // AES-256
    private const int HashSize = 64;           // SHA-512
    private const int SpinCount = 100_000;
    private const int SegmentSize = 4096;

    // Block keys (MS-OFFCRYPTO §2.3.4.10 / §2.3.4.13-15) — fixed 8-byte constants.
    private static readonly byte[] BlockVerifierInput = { 0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79 };
    private static readonly byte[] BlockVerifierValue = { 0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e };
    private static readonly byte[] BlockKeyValue = { 0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6 };
    private static readonly byte[] BlockHmacKey = { 0x5f, 0xb2, 0xad, 0x01, 0x0c, 0xb9, 0xe1, 0xf6 };
    private static readonly byte[] BlockHmacValue = { 0xa0, 0x67, 0x7f, 0x02, 0xb2, 0x2c, 0x84, 0x33 };

    private const string NsEnc = "http://schemas.microsoft.com/office/2006/encryption";
    private const string NsPwd = "http://schemas.microsoft.com/office/2006/keyEncryptor/password";

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
        byte[] package = File.ReadAllBytes(inputOoxml);

        byte[] keyDataSalt = RandomBytes(SaltSize);
        byte[] pwSalt = RandomBytes(SaltSize);
        byte[] packageKey = RandomBytes(KeyBytes);

        // Encrypt the package (8-byte length prefix + AES-CBC segments keyed by the package key).
        byte[] encryptedPackage = EncryptPackage(package, packageKey, keyDataSalt);

        // Data integrity: HMAC-SHA512 over the EncryptedPackage stream, with the HMAC key
        // and value themselves AES-encrypted under the package key.
        byte[] hmacKey = RandomBytes(HashSize);
        byte[] encHmacKey = AesCbc(packageKey, Hash(keyDataSalt, BlockHmacKey, BlockSize), Pad(hmacKey), encrypt: true);
        byte[] hmacValue;
        using (var hmac = new HMACSHA512(hmacKey))
            hmacValue = hmac.ComputeHash(encryptedPackage);
        byte[] encHmacValue = AesCbc(packageKey, Hash(keyDataSalt, BlockHmacValue, BlockSize), Pad(hmacValue), encrypt: true);

        // Password key derivation and the password-encrypted verifier + package key.
        byte[] pwHash = DerivePasswordHash(password, pwSalt, SpinCount);
        byte[] iv = Fit(pwSalt, BlockSize);

        byte[] verifierInput = RandomBytes(SaltSize);
        byte[] verifierHash = SHA512.HashData(verifierInput);
        byte[] encVerifierInput = AesCbc(DeriveBlockKey(pwHash, BlockVerifierInput), iv, Pad(verifierInput), encrypt: true);
        byte[] encVerifierValue = AesCbc(DeriveBlockKey(pwHash, BlockVerifierValue), iv, Pad(verifierHash), encrypt: true);
        byte[] encKeyValue = AesCbc(DeriveBlockKey(pwHash, BlockKeyValue), iv, Pad(packageKey), encrypt: true);

        byte[] xml = Encoding.UTF8.GetBytes(BuildXml(
            keyDataSalt, pwSalt, encVerifierInput, encVerifierValue, encKeyValue, encHmacKey, encHmacValue));

        // EncryptionInfo stream: version 4.4, fAgile flag (0x40), then the UTF-8 XML.
        byte[] encryptionInfo = new byte[8 + xml.Length];
        encryptionInfo[0] = 0x04; encryptionInfo[2] = 0x04; encryptionInfo[4] = 0x40;
        Buffer.BlockCopy(xml, 0, encryptionInfo, 8, xml.Length);

        using var cf = new CompoundFile();
        cf.RootStorage.AddStream("EncryptionInfo").SetData(encryptionInfo);
        cf.RootStorage.AddStream("EncryptedPackage").SetData(encryptedPackage);
        cf.Save(outputPath);
    }

    /// <summary>
    /// Verify the password and, if correct, write the decrypted OOXML package to
    /// <paramref name="destination"/>. Returns false (writing nothing) on a wrong password.
    /// </summary>
    public static bool TryDecrypt(string encryptedPath, string password, Stream destination)
    {
        byte[] encryptionInfo;
        byte[] encryptedPackage;
        using (var cf = new CompoundFile(encryptedPath))
        {
            encryptionInfo = cf.RootStorage.GetStream("EncryptionInfo").GetData();
            encryptedPackage = cf.RootStorage.GetStream("EncryptedPackage").GetData();
        }

        Agile p = ParseEncryptionInfo(encryptionInfo);
        byte[] pwHash = DerivePasswordHash(password, p.PwSalt, p.SpinCount);
        byte[] iv = Fit(p.PwSalt, BlockSize);

        // Verify the password: decrypt the verifier input and its hash, and compare.
        byte[] verifierInput = AesCbc(DeriveBlockKey(pwHash, BlockVerifierInput), iv, p.EncVerifierInput, encrypt: false);
        byte[] verifierValue = AesCbc(DeriveBlockKey(pwHash, BlockVerifierValue), iv, p.EncVerifierValue, encrypt: false);
        byte[] expected = SHA512.HashData(verifierInput);
        if (!CryptographicOperations.FixedTimeEquals(expected, verifierValue.AsSpan(0, HashSize)))
            return false;

        byte[] packageKey = AesCbc(DeriveBlockKey(pwHash, BlockKeyValue), iv, p.EncKeyValue, encrypt: false);
        Array.Resize(ref packageKey, KeyBytes);

        byte[] package = DecryptPackage(encryptedPackage, packageKey, p.KeyDataSalt);
        destination.Write(package, 0, package.Length);
        return true;
    }

    // ---- package segment encryption ----

    private static byte[] EncryptPackage(byte[] package, byte[] key, byte[] keyDataSalt)
    {
        using var outMs = new MemoryStream();
        Span<byte> len = stackalloc byte[8];
        BinaryPrimitives.WriteInt64LittleEndian(len, package.Length);
        outMs.Write(len);

        for (int offset = 0, seg = 0; offset < package.Length; offset += SegmentSize, seg++)
        {
            int n = Math.Min(SegmentSize, package.Length - offset);
            byte[] plain = Pad(package.AsSpan(offset, n).ToArray());
            byte[] iv = Hash(keyDataSalt, LE32(seg), BlockSize);
            byte[] enc = AesCbc(key, iv, plain, encrypt: true);
            outMs.Write(enc);
        }
        return outMs.ToArray();
    }

    private static byte[] DecryptPackage(byte[] encryptedPackage, byte[] key, byte[] keyDataSalt)
    {
        long total = BinaryPrimitives.ReadInt64LittleEndian(encryptedPackage.AsSpan(0, 8));
        using var outMs = new MemoryStream();
        for (int pos = 8, seg = 0; pos < encryptedPackage.Length; seg++)
        {
            int n = Math.Min(SegmentSize, encryptedPackage.Length - pos);
            byte[] cipher = encryptedPackage.AsSpan(pos, n).ToArray();
            byte[] iv = Hash(keyDataSalt, LE32(seg), BlockSize);
            outMs.Write(AesCbc(key, iv, cipher, encrypt: false));
            pos += n;
        }
        byte[] all = outMs.ToArray();
        if (all.Length > total) Array.Resize(ref all, (int)total);
        return all;
    }

    // ---- key derivation ----

    private static byte[] DerivePasswordHash(string password, byte[] salt, int spinCount)
    {
        using var sha = SHA512.Create();
        byte[] h = sha.ComputeHash(Concat(salt, Encoding.Unicode.GetBytes(password))); // UTF-16LE
        byte[] buf = new byte[4 + h.Length];
        for (int i = 0; i < spinCount; i++)
        {
            BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(0, 4), i);
            Buffer.BlockCopy(h, 0, buf, 4, h.Length);
            h = sha.ComputeHash(buf);
        }
        return h;
    }

    private static byte[] DeriveBlockKey(byte[] pwHash, byte[] blockKey) =>
        Fit(SHA512.HashData(Concat(pwHash, blockKey)), KeyBytes);

    // ---- EncryptionInfo XML ----

    private static string BuildXml(
        byte[] keyDataSalt, byte[] pwSalt, byte[] encVerifierInput, byte[] encVerifierValue,
        byte[] encKeyValue, byte[] encHmacKey, byte[] encHmacValue)
    {
        string B(byte[] b) => Convert.ToBase64String(b);
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            $"<encryption xmlns=\"{NsEnc}\" xmlns:p=\"{NsPwd}\" " +
            "xmlns:c=\"http://schemas.microsoft.com/office/2006/keyEncryptor/certificate\">" +
            "<keyData saltSize=\"16\" blockSize=\"16\" keyBits=\"256\" hashSize=\"64\" " +
            "cipherAlgorithm=\"AES\" cipherChaining=\"ChainingModeCBC\" hashAlgorithm=\"SHA512\" " +
            $"saltValue=\"{B(keyDataSalt)}\"/>" +
            $"<dataIntegrity encryptedHmacKey=\"{B(encHmacKey)}\" encryptedHmacValue=\"{B(encHmacValue)}\"/>" +
            $"<keyEncryptors><keyEncryptor uri=\"{NsPwd}\">" +
            "<p:encryptedKey spinCount=\"100000\" saltSize=\"16\" blockSize=\"16\" keyBits=\"256\" hashSize=\"64\" " +
            "cipherAlgorithm=\"AES\" cipherChaining=\"ChainingModeCBC\" hashAlgorithm=\"SHA512\" " +
            $"saltValue=\"{B(pwSalt)}\" encryptedVerifierHashInput=\"{B(encVerifierInput)}\" " +
            $"encryptedVerifierHashValue=\"{B(encVerifierValue)}\" encryptedKeyValue=\"{B(encKeyValue)}\"/>" +
            "</keyEncryptor></keyEncryptors></encryption>";
    }

    private sealed class Agile
    {
        public byte[] KeyDataSalt = [];
        public byte[] PwSalt = [];
        public int SpinCount;
        public byte[] EncVerifierInput = [];
        public byte[] EncVerifierValue = [];
        public byte[] EncKeyValue = [];
    }

    private static Agile ParseEncryptionInfo(byte[] encryptionInfo)
    {
        var doc = new XmlDocument();
        using (var ms = new MemoryStream(encryptionInfo, 8, encryptionInfo.Length - 8))
            doc.Load(ms);
        var ns = new XmlNamespaceManager(doc.NameTable);
        ns.AddNamespace("e", NsEnc);
        ns.AddNamespace("p", NsPwd);

        var keyData = (XmlElement)doc.SelectSingleNode("/e:encryption/e:keyData", ns)!;
        var ek = (XmlElement)doc.SelectSingleNode(
            "/e:encryption/e:keyEncryptors/e:keyEncryptor/p:encryptedKey", ns)!;

        return new Agile
        {
            KeyDataSalt = Convert.FromBase64String(keyData.GetAttribute("saltValue")),
            PwSalt = Convert.FromBase64String(ek.GetAttribute("saltValue")),
            SpinCount = int.Parse(ek.GetAttribute("spinCount")),
            EncVerifierInput = Convert.FromBase64String(ek.GetAttribute("encryptedVerifierHashInput")),
            EncVerifierValue = Convert.FromBase64String(ek.GetAttribute("encryptedVerifierHashValue")),
            EncKeyValue = Convert.FromBase64String(ek.GetAttribute("encryptedKeyValue")),
        };
    }

    // ---- primitives ----

    private static byte[] AesCbc(byte[] key, byte[] iv, byte[] data, bool encrypt)
    {
        using var aes = Aes.Create();
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.None; // agile uses zero-padding + stored lengths, not PKCS7
        aes.Key = key;
        aes.IV = Fit(iv, BlockSize);
        using ICryptoTransform t = encrypt ? aes.CreateEncryptor() : aes.CreateDecryptor();
        return t.TransformFinalBlock(data, 0, data.Length);
    }

    private static byte[] Hash(byte[] salt, byte[] block, int size) =>
        Fit(SHA512.HashData(Concat(salt, block)), size);

    private static byte[] RandomBytes(int count)
    {
        byte[] b = new byte[count];
        RandomNumberGenerator.Fill(b);
        return b;
    }

    private static byte[] LE32(int value)
    {
        byte[] b = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(b, value);
        return b;
    }

    /// <summary>Zero-pad to a multiple of the AES block size (agile requires no PKCS7).</summary>
    private static byte[] Pad(byte[] data)
    {
        int rem = data.Length % BlockSize;
        if (rem == 0) return data;
        byte[] p = new byte[data.Length + (BlockSize - rem)];
        Buffer.BlockCopy(data, 0, p, 0, data.Length);
        return p;
    }

    /// <summary>Truncate to <paramref name="size"/>, or pad with 0x36 if shorter (per spec).</summary>
    private static byte[] Fit(byte[] data, int size)
    {
        if (data.Length == size) return data;
        byte[] r = new byte[size];
        if (data.Length > size)
        {
            Buffer.BlockCopy(data, 0, r, 0, size);
        }
        else
        {
            Buffer.BlockCopy(data, 0, r, 0, data.Length);
            for (int i = data.Length; i < size; i++) r[i] = 0x36;
        }
        return r;
    }

    private static byte[] Concat(byte[] a, byte[] b)
    {
        byte[] r = new byte[a.Length + b.Length];
        Buffer.BlockCopy(a, 0, r, 0, a.Length);
        Buffer.BlockCopy(b, 0, r, a.Length, b.Length);
        return r;
    }
}
