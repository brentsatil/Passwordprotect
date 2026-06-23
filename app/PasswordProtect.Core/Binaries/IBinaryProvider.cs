namespace PasswordProtect.Core;

/// <summary>
/// Supplies on-disk paths to the bundled qpdf and 7z executables. Implementations
/// decide where the binaries come from (a folder, or hash-verified extraction of
/// embedded resources). The first call may provision; later calls are cheap.
/// </summary>
public interface IBinaryProvider
{
    Task<string> GetQpdfPathAsync(CancellationToken ct = default);
    Task<string> GetSevenZipPathAsync(CancellationToken ct = default);
}
