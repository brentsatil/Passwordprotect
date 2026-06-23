namespace PasswordProtect.Core;

/// <summary>
/// Resolves qpdf/7z from a folder on disk (e.g. a <c>bin\</c> beside the exe, or
/// the repo's <c>bin\</c> in tests). Optionally verifies each binary against a
/// HASHES.txt sitting in the same folder. This is the spiritual successor to the
/// legacy <c>Resolve-Binary</c> bundled-path probe.
/// </summary>
public sealed class DirectoryBinaryProvider : IBinaryProvider
{
    private readonly string _dir;
    private readonly bool _verify;
    private readonly IReadOnlyDictionary<string, string>? _pins;

    public DirectoryBinaryProvider(string dir, bool verify = false)
    {
        _dir = dir;
        _verify = verify;
        string hashes = Path.Combine(dir, "HASHES.txt");
        if (verify && File.Exists(hashes))
            _pins = HashPins.Parse(File.ReadAllText(hashes));
    }

    public Task<string> GetQpdfPathAsync(CancellationToken ct = default) => Task.FromResult(Resolve("qpdf.exe"));
    public Task<string> GetSevenZipPathAsync(CancellationToken ct = default) => Task.FromResult(Resolve("7z.exe"));

    private string Resolve(string name)
    {
        string path = Path.Combine(_dir, name);
        if (!File.Exists(path))
            throw new FileNotFoundException($"{name} not found in '{_dir}'.", path);

        if (_verify && _pins != null && _pins.TryGetValue(name, out var hex) &&
            !BinaryExtractor.VerifyExisting(path, hex))
            throw new InvalidDataException($"{name} failed hash verification against HASHES.txt.");

        return path;
    }
}
