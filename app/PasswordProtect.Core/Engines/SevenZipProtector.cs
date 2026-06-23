using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// AES-256 .7z creation via 7z. Faithful port of the legacy
/// <c>Protect-WithSevenZip</c> (src/Invoke-SevenZip.ps1):
/// <c>a -t7z -mhe=on -mx=5 -y -p&lt;pw&gt;</c>, header encryption on so a wrong
/// password fails <c>7z t</c>; temp-then-atomic-rename; exit 0 = success.
/// </summary>
public sealed class SevenZipProtector : IProtector
{
    private readonly IBinaryProvider _binaries;

    public SevenZipProtector(IBinaryProvider binaries) => _binaries = binaries;

    /// <summary>
    /// For the apply flow the input is an ordinary document (not an archive), so
    /// this is false. Detection/editing of existing encrypted archives is handled
    /// by the password-edit path; we conservatively report "not protected" here.
    /// </summary>
    public Task<bool> IsProtectedAsync(string input, CancellationToken ct = default) => Task.FromResult(false);

    public async Task<ProtectResult> ProtectAsync(
        string input, string output, SecureString password, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");

        if (!FileLock.CanOpenForRead(input))
            return ProtectResult.Fail(ProtectErrorCode.FileLocked, "Input file is in use.");

        string sevenZip = await _binaries.GetSevenZipPathAsync(ct).ConfigureAwait(false);
        string tmpOut = output + ".tmp";

        var args = SecurePassword.Use(password, plain => new List<string>
        {
            "a", "-t7z", "-mhe=on", "-mx=5", "-y", "-p" + plain, tmpOut, input,
        });

        ProcessResult res;
        try
        {
            res = await NativeProcessRunner.RunAsync(sevenZip, args, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.Cancelled, "Cancelled.");
        }

        if (res.ExitCode != 0 || !File.Exists(tmpOut))
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, res.Combined);
        }

        try
        {
            File.Move(tmpOut, output, overwrite: true);
        }
        catch (Exception ex)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ex.Message);
        }

        return ProtectResult.Ok(output, res.Combined);
    }
}
