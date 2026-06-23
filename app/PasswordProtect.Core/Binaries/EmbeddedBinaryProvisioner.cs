using System.Reflection;
using System.Text;

namespace PasswordProtect.Core;

/// <summary>
/// Production binary provider for the single-file portable exe. On first use it
/// extracts the embedded qpdf/7z payload (and the qpdf runtime DLLs) into a
/// per-version cache directory, verifying every file against the embedded
/// HASHES.txt pins, then refuses to hand back any path whose on-disk hash does
/// not match. A named mutex guards concurrent first-runs from a shared drive.
///
/// Resource layout: each payload file is embedded with the logical name
/// <c>{prefix}{filename}</c>, plus <c>{prefix}HASHES.txt</c>.
/// </summary>
public sealed class EmbeddedBinaryProvisioner : IBinaryProvider
{
    private readonly Assembly _asm;
    private readonly string _prefix;
    private readonly string _cacheDir;
    private readonly Lazy<Task> _ensure;

    public EmbeddedBinaryProvisioner(Assembly asm, string prefix, string cacheDir)
    {
        _asm = asm;
        _prefix = prefix;
        _cacheDir = cacheDir;
        _ensure = new Lazy<Task>(() => Task.Run(Provision));
    }

    /// <summary>Default cache location: %LOCALAPPDATA%\PasswordProtect\bin\&lt;version&gt;\.</summary>
    public static string DefaultCacheDir(string version)
    {
        string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "PasswordProtect", "bin", version);
    }

    public async Task<string> GetQpdfPathAsync(CancellationToken ct = default)
    {
        await _ensure.Value.ConfigureAwait(false);
        return Path.Combine(_cacheDir, "qpdf.exe");
    }

    public async Task<string> GetSevenZipPathAsync(CancellationToken ct = default)
    {
        await _ensure.Value.ConfigureAwait(false);
        return Path.Combine(_cacheDir, "7z.exe");
    }

    private void Provision()
    {
        Directory.CreateDirectory(_cacheDir);

        using var mutex = new Mutex(false, @"Global\PasswordProtect.Provision." + Slug(_cacheDir));
        bool held = false;
        try
        {
            try { held = mutex.WaitOne(TimeSpan.FromMinutes(2)); }
            catch (AbandonedMutexException) { held = true; }

            string hashesText = Encoding.UTF8.GetString(
                BinaryExtractor.ReadResource(_asm, _prefix + "HASHES.txt"));
            var pins = HashPins.Parse(hashesText);
            if (pins.Count == 0)
                throw new InvalidOperationException("Embedded HASHES.txt contained no pins.");

            foreach (var (name, hex) in pins)
            {
                string dest = Path.Combine(_cacheDir, name);
                if (BinaryExtractor.VerifyExisting(dest, hex)) continue; // already good
                BinaryExtractor.ExtractResource(_asm, _prefix + name, dest, hex);
            }
        }
        finally
        {
            if (held) mutex.ReleaseMutex();
        }
    }

    private static string Slug(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
        // Mutex names are limited to 260 chars; keep the tail (most-specific part).
        string slug = sb.ToString();
        return slug.Length <= 200 ? slug : slug[^200..];
    }
}
