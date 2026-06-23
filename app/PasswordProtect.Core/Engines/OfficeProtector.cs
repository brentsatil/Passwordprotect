using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// Protects Office documents in-kind: the output is a real password-protected
/// .docx/.xlsx/.pptx (native agile encryption via <see cref="OfficeCrypto"/>) that
/// opens directly in Office. Same fail-closed guarantees as the other engines
/// (refuse already-encrypted/locked inputs; temp-then-atomic-rename).
/// </summary>
public sealed class OfficeProtector : IProtector
{
    public Task<bool> IsProtectedAsync(string input, CancellationToken ct = default) =>
        Task.FromResult(OfficeCrypto.IsEncryptedOoxml(input));

    public async Task<ProtectResult> ProtectAsync(
        string input, string output, SecureString password, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");
        if (OfficeCrypto.IsEncryptedOoxml(input))
            return ProtectResult.Fail(ProtectErrorCode.PreEncrypted,
                "This Office file is already password-protected. Remove existing protection first.");
        if (!FileLock.CanOpenForRead(input))
            return ProtectResult.Fail(ProtectErrorCode.FileLocked,
                "Input file is in use. Close it in Office and try again.");

        string tmpOut = output + ".tmp";
        try
        {
            await Task.Run(() => SecurePassword.Use(password, plain =>
            {
                OfficeCrypto.Encrypt(input, tmpOut, plain);
                return 0;
            }), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.Cancelled, "Cancelled.");
        }
        catch (Exception ex)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ex.Message);
        }

        if (!File.Exists(tmpOut))
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, "Encryption produced no output.");

        try
        {
            File.Move(tmpOut, output, overwrite: true);
        }
        catch (Exception ex)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, ex.Message);
        }

        return ProtectResult.Ok(output);
    }
}
