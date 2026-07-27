using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// AES-256 .7z creation via 7z. Faithful port of the legacy
/// <c>Protect-WithSevenZip</c> (src/Invoke-SevenZip.ps1):
/// <c>a -t7z -mhe=on -mx=5 -y -p&lt;pw&gt;</c>, header encryption on so a wrong
/// password fails <c>7z t</c>; temp-then-atomic-rename; exit 0 = success.
/// </summary>
public sealed class SevenZipProtector : IProtector, IPasswordEditor
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

    /// <summary>
    /// Editing a .7z means re-keying the archive: extract with the current password
    /// to a temp dir, then re-create it (with the new password for Change, or with
    /// no password for Remove). A failed extract = wrong current password.
    /// </summary>
    public async Task<ProtectResult> ChangePasswordAsync(
        string input, string output, SecureString? current, SecureString? newPassword,
        PasswordEditMode mode, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");

        // Adding protection to a plain file is just the normal protect path.
        if (mode == PasswordEditMode.Add)
            return await ProtectAsync(input, output, newPassword!, options, ct).ConfigureAwait(false);

        string sevenZip = await _binaries.GetSevenZipPathAsync(ct).ConfigureAwait(false);
        string workDir = Path.Combine(Path.GetTempPath(), "pp-7z-edit-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDir);
        string tmpOut = output + ".tmp";
        try
        {
            var extractArgs = SecurePassword.Use(current!, cur =>
                new List<string> { "x", "-p" + cur, "-o" + workDir, "-y", "--", input });
            ProcessResult ex = await NativeProcessRunner.RunAsync(sevenZip, extractArgs, ct).ConfigureAwait(false);
            if (ex.ExitCode != 0)
                return ProtectResult.Fail(ProtectErrorCode.WrongPassword,
                    "Wrong current password or the archive could not be read.");

            string[] entries = Directory.GetFileSystemEntries(workDir);
            if (entries.Length == 0)
                return ProtectResult.Fail(ProtectErrorCode.EngineFailure, "Archive was empty.");

            List<string> addArgs = mode == PasswordEditMode.Remove
                ? new List<string> { "a", "-t7z", "-mx=5", "-y", tmpOut }
                : SecurePassword.Use(newPassword!, np =>
                    new List<string> { "a", "-t7z", "-mhe=on", "-mx=5", "-y", "-p" + np, tmpOut });
            addArgs.AddRange(entries);

            ProcessResult ar = await NativeProcessRunner.RunAsync(sevenZip, addArgs, ct).ConfigureAwait(false);
            if (ar.ExitCode != 0 || !File.Exists(tmpOut))
            {
                QpdfProtector.TryDelete(tmpOut);
                return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ar.Combined);
            }

            File.Move(tmpOut, output, overwrite: true);
            return ProtectResult.Ok(output, ar.Combined);
        }
        catch (OperationCanceledException)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.Cancelled, "Cancelled.");
        }
        catch (Exception e)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, e.Message);
        }
        finally
        {
            try { Directory.Delete(workDir, recursive: true); } catch { /* best effort */ }
        }
    }
}
