using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// Protects Office documents in-kind: the output is a real password-protected
/// .docx/.xlsx/.pptx (native agile encryption via <see cref="OfficeCrypto"/>) that
/// opens directly in Office. Same fail-closed guarantees as the other engines
/// (refuse already-encrypted/locked inputs; temp-then-atomic-rename).
/// </summary>
public sealed class OfficeProtector : IProtector, IPasswordEditor
{
    private sealed class WrongPasswordException : Exception { }

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

    public async Task<ProtectResult> ChangePasswordAsync(
        string input, string output, SecureString? current, SecureString? newPassword,
        PasswordEditMode mode, ProtectOptions options, CancellationToken ct = default)
    {
        if (!File.Exists(input))
            return ProtectResult.Fail(ProtectErrorCode.InputNotFound, "Input not found.");
        if (File.Exists(output) && !options.AllowOverwrite)
            return ProtectResult.Fail(ProtectErrorCode.OutputExists, "Output exists and overwrite is disabled.");

        bool encrypted = OfficeCrypto.IsEncryptedOoxml(input);
        if (mode != PasswordEditMode.Add && !encrypted)
            return ProtectResult.Fail(ProtectErrorCode.NotProtected, "This Office file is not password-protected.");
        if (mode == PasswordEditMode.Add && encrypted)
            return ProtectResult.Fail(ProtectErrorCode.PreEncrypted, "This Office file is already password-protected.");
        if (!FileLock.CanOpenForRead(input))
            return ProtectResult.Fail(ProtectErrorCode.FileLocked, "Input file is in use.");

        string tmpOut = output + ".tmp";
        try
        {
            await Task.Run(() =>
            {
                if (mode == PasswordEditMode.Add)
                {
                    SecurePassword.Use(newPassword!, np => { OfficeCrypto.Encrypt(input, tmpOut, np); return 0; });
                    return;
                }

                string plainTmp = Path.Combine(Path.GetTempPath(), "pp-office-" + Guid.NewGuid().ToString("N"));
                try
                {
                    bool ok = SecurePassword.Use(current!, cur =>
                    {
                        using var fs = File.Create(plainTmp);
                        return OfficeCrypto.TryDecrypt(input, cur, fs);
                    });
                    if (!ok) throw new WrongPasswordException();

                    if (mode == PasswordEditMode.Remove)
                        File.Copy(plainTmp, tmpOut, overwrite: true);
                    else // Change
                        SecurePassword.Use(newPassword!, np => { OfficeCrypto.Encrypt(plainTmp, tmpOut, np); return 0; });
                }
                finally
                {
                    QpdfProtector.TryDelete(plainTmp);
                }
            }, ct).ConfigureAwait(false);
        }
        catch (WrongPasswordException)
        {
            QpdfProtector.TryDelete(tmpOut);
            return ProtectResult.Fail(ProtectErrorCode.WrongPassword, "Wrong current password.");
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
            return ProtectResult.Fail(ProtectErrorCode.EngineFailure, "Operation produced no output.");

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
