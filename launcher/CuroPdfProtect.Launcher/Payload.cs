using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace CuroPdfProtect.Launcher
{
    /// <summary>One embedded payload file and where it lands on disk.</summary>
    internal sealed class PayloadItem
    {
        public string ResourceName;
        public string RelativePath;   // e.g. "src\Config.psm1" or "PasswordProtect.ps1"
        public long Length;
        public string Sha256;         // lowercase hex of the embedded bytes
    }

    /// <summary>
    /// Embeds the PowerShell tool and extracts it to a per-user cache keyed by a
    /// hash of the payload itself, so a new exe version lands in a new folder and
    /// no upgrade logic is needed.
    ///
    /// Mirrors the embed -> hash-verify -> atomic temp-then-move pattern that
    /// app\PasswordProtect.Core\Binaries\BinaryExtractor.cs already uses, but is
    /// written against .NET Framework 4.8 (no Convert.ToHexString, no
    /// SHA256.HashData - both are .NET Core-only).
    /// </summary>
    internal static class Payload
    {
        private const string Prefix = "PPAYLOAD.";
        private const string MarkerName = ".payload-complete";

        /// <summary>Enumerate the embedded payload, hashing each entry.</summary>
        public static List<PayloadItem> GetItems()
        {
            Assembly asm = typeof(Payload).Assembly;
            var items = new List<PayloadItem>();

            foreach (string name in asm.GetManifestResourceNames())
            {
                if (!name.StartsWith(Prefix, StringComparison.Ordinal)) continue;

                // "<dir>.<filename>"; the filename may itself contain dots.
                string rest = name.Substring(Prefix.Length);
                int dot = rest.IndexOf('.');
                if (dot <= 0 || dot == rest.Length - 1) continue;

                string dir = rest.Substring(0, dot);
                string file = rest.Substring(dot + 1);
                string rel = string.Equals(dir, "root", StringComparison.Ordinal)
                    ? file
                    : Path.Combine(dir, file);

                byte[] bytes = ReadResource(asm, name);
                items.Add(new PayloadItem
                {
                    ResourceName = name,
                    RelativePath = rel,
                    Length = bytes.LongLength,
                    Sha256 = Sha256Hex(bytes),
                });
            }

            items.Sort((a, b) => string.CompareOrdinal(a.RelativePath, b.RelativePath));
            return items;
        }

        /// <summary>
        /// Stable identity of the whole payload: SHA-256 over the sorted
        /// "relativePath:sha256" manifest. Same tool bytes -> same cache folder.
        /// </summary>
        public static string ComputeId(List<PayloadItem> items)
        {
            var sb = new StringBuilder();
            foreach (PayloadItem it in items)
            {
                sb.Append(it.RelativePath.Replace('\\', '/'));
                sb.Append(':');
                sb.Append(it.Sha256);
                sb.Append('\n');
            }
            return Sha256Hex(Encoding.UTF8.GetBytes(sb.ToString())).Substring(0, 16);
        }

        public static string CacheRoot(string payloadId)
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "CuroPDFProtect", "app", payloadId);
        }

        /// <summary>
        /// Ensure the payload is present at its cache folder and return that path.
        /// Skips work when the completion marker matches and every file is present
        /// at the expected size. <paramref name="fullVerify"/> forces a re-hash of
        /// everything on disk.
        /// </summary>
        public static string EnsureExtracted(bool fullVerify, out bool extracted)
        {
            List<PayloadItem> items = GetItems();
            if (items.Count == 0)
                throw new InvalidOperationException("This build contains no embedded payload.");

            string id = ComputeId(items);
            string root = CacheRoot(id);
            string marker = Path.Combine(root, MarkerName);

            if (IsIntact(root, marker, id, items, fullVerify))
            {
                extracted = false;
                return root;
            }

            Assembly asm = typeof(Payload).Assembly;
            Directory.CreateDirectory(root);

            foreach (PayloadItem it in items)
            {
                string dest = Path.Combine(root, it.RelativePath);
                string destDir = Path.GetDirectoryName(dest);
                if (!string.IsNullOrEmpty(destDir)) Directory.CreateDirectory(destDir);

                byte[] bytes = ReadResource(asm, it.ResourceName);

                // Verify what we are about to write, then move it into place
                // atomically so a half-written file can never be picked up.
                string actual = Sha256Hex(bytes);
                if (!string.Equals(actual, it.Sha256, StringComparison.Ordinal))
                    throw new InvalidDataException("Embedded payload failed verification: " + it.RelativePath);

                string tmp = dest + ".tmp";
                File.WriteAllBytes(tmp, bytes);
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(tmp, dest);
            }

            File.WriteAllText(marker, id, new UTF8Encoding(false));
            PruneOldCaches(root);
            extracted = true;
            return root;
        }

        /// <summary>
        /// Remove payload caches from previous exe versions. Each build lands in
        /// its own hash-named folder, so without this every update leaves another
        /// ~7.5 MB copy behind per user, forever. Best-effort: a locked file just
        /// means the folder survives to be cleaned next time.
        /// </summary>
        private static void PruneOldCaches(string keep)
        {
            try
            {
                string parent = Path.GetDirectoryName(keep);
                if (string.IsNullOrEmpty(parent) || !Directory.Exists(parent)) return;
                foreach (string dir in Directory.GetDirectories(parent))
                {
                    if (string.Equals(dir, keep, StringComparison.OrdinalIgnoreCase)) continue;
                    try { Directory.Delete(dir, true); } catch { /* in use; next time */ }
                }
            }
            catch { /* pruning must never stop the tool from running */ }
        }

        private static bool IsIntact(string root, string marker, string id,
                                     List<PayloadItem> items, bool fullVerify)
        {
            try
            {
                if (!File.Exists(marker)) return false;
                if (!string.Equals(File.ReadAllText(marker).Trim(), id, StringComparison.Ordinal)) return false;

                foreach (PayloadItem it in items)
                {
                    string p = Path.Combine(root, it.RelativePath);
                    var fi = new FileInfo(p);
                    if (!fi.Exists || fi.Length != it.Length) return false;
                    if (fullVerify && !string.Equals(Sha256HexOfFile(p), it.Sha256, StringComparison.Ordinal))
                        return false;
                }
                return true;
            }
            catch
            {
                return false;   // unreadable cache -> re-extract
            }
        }

        private static byte[] ReadResource(Assembly asm, string name)
        {
            using (Stream s = asm.GetManifestResourceStream(name))
            {
                if (s == null) throw new InvalidOperationException("Missing embedded resource: " + name);
                using (var ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    return ms.ToArray();
                }
            }
        }

        public static string Sha256Hex(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return ToHex(sha.ComputeHash(data));
            }
        }

        public static string Sha256HexOfFile(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream fs = File.OpenRead(path))
            {
                return ToHex(sha.ComputeHash(fs));
            }
        }

        private static string ToHex(byte[] hash)
        {
            var sb = new StringBuilder(hash.Length * 2);
            for (int i = 0; i < hash.Length; i++) sb.Append(hash[i].ToString("x2"));
            return sb.ToString();
        }
    }
}
