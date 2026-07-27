using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// PDF AES-256 encryption via qpdf. Faithful port of the legacy
/// <c>Protect-Pdf</c> (src/Invoke-QPdf.ps1): pre-encrypted and locked inputs are
/// refused; qpdf exit 0 and 3 (warnings) are treated as success while 2 is a
/// failure; output is written to a temp file then atomically renamed.
/// </summary>
public sealed class QpdfProtector : IProtector, IPasswordEditor
{
    private readonly IBinaryProvider _binaries;

    public QpdfProtector(IBinaryProvider binaries) => _binaries = binaries;

    public async Task<bool> IsProtectedAsync(string input, CancellationToken ct = default)
    {
        string qpdf = await _binaries.GetQpdfPathAsync(ct).ConfigureAwait(false);
        // qpdf --is-encrypted exits 0 if encrypted, 2 if not, 3 on error.
        var res = await NativeProcessRunner.RunAsync(qpdf, new[] { "--is-encrypted", "--", input }, ct)
            .ConfigureAwait(false);
        return res.ExitCode == 0;
    }

    public async Task<ProtectResult> ProtectAsync(
        string input, string output, SecureString password, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");

        if (await IsProtectedAsync(input, ct).ConfigureAwait(false))
            return ProtectResult.Fail(ProtectErrorCode.PreEncrypted,
                "Input PDF is already encrypted. Remove existing protection first.");

        if (!FileLock.CanOpenForRead(input))
            return ProtectResult.Fail(ProtectErrorCode.FileLocked,
                "Input file is in use. Close it in Acrobat or Reader and try again.");

        string qpdf = await _binaries.GetQpdfPathAsync(ct).ConfigureAwait(false);
        string inArg = options.LongPathPrefix ? LongPath.AddPrefix(input) : input;
        string tmpOut = output + ".tmp";
        string outArg = options.LongPathPrefix ? LongPath.AddPrefix(tmpOut) : tmpOut;

        // qpdf --encrypt <user> <owner> 256 -- in out  (user == owner; advice docs
        // do not use owner-permission semantics). Password is placed on the child
        // argv only and never logged.
        var args = SecurePassword.Use(password, plain => new List<string>
        {
            "--encrypt", plain, plain, "256", "--", inArg, outArg,
        });

        ProcessResult res;
        try
        {
            res = await NativeProcessRunner.RunAsync(qpdf, args, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.Cancelled, "Cancelled.");
        }

        // Exit 0 = clean, 3 = warnings (output still produced), 2 = error.
        if ((res.ExitCode != 0 && res.ExitCode != 3) || !File.Exists(tmpOut))
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, res.StdErr);
        }

        try
        {
            File.Move(tmpOut, output, overwrite: true);
        }
        catch (Exception ex)
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ex.Message);
        }

        return ProtectResult.Ok(output, res.StdErr);
    }

    public async Task<ProtectResult> ChangePasswordAsync(
        string input, string output, SecureString? current, SecureString? newPassword,
        PasswordEditMode mode, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");

        bool encrypted = await IsProtectedAsync(input, ct).ConfigureAwait(false);
        if (mode != PasswordEditMode.Add && !encrypted)
            return ProtectResult.Fail(ProtectErrorCode.NotProtected, "Input PDF is not password-protected.");
        if (mode == PasswordEditMode.Add && encrypted)
            return ProtectResult.Fail(ProtectErrorCode.PreEncrypted, "Input PDF is already encrypted.");
        if (!FileLock.CanOpenForRead(input))
            return ProtectResult.Fail(ProtectErrorCode.FileLocked, "Input file is in use.");

        string qpdf = await _binaries.GetQpdfPathAsync(ct).ConfigureAwait(false);
        string inArg = options.LongPathPrefix ? LongPath.AddPrefix(input) : input;
        string tmpOut = output + ".tmp";
        string outArg = options.LongPathPrefix ? LongPath.AddPrefix(tmpOut) : tmpOut;

        var args = SecurePassword.UsePair(current, newPassword, (cur, np) => mode switch
        {
            PasswordEditMode.Remove => new List<string> { "--password=" + (cur ?? ""), "--decrypt", "--", inArg, outArg },
            PasswordEditMode.Change => new List<string> { "--password=" + (cur ?? ""), "--encrypt", np ?? "", np ?? "", "256", "--", inArg, outArg },
            _ /* Add */            => new List<string> { "--encrypt", np ?? "", np ?? "", "256", "--", inArg, outArg },
        });

        ProcessResult res;
        try
        {
            res = await NativeProcessRunner.RunAsync(qpdf, args, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.Cancelled, "Cancelled.");
        }

        // For an encrypted input, qpdf exit 2 means the current password was wrong.
        if (res.ExitCode == 2 && encrypted)
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.WrongPassword, "Wrong current password.");
        }
        if ((res.ExitCode != 0 && res.ExitCode != 3) || !File.Exists(tmpOut))
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, res.StdErr);
        }

        try
        {
            File.Move(tmpOut, output, overwrite: true);
        }
        catch (Exception ex)
        {
            TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ex.Message);
        }

        return ProtectResult.Ok(output, res.StdErr);
    }

    internal static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }
}
