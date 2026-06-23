namespace PasswordProtect.Core;

/// <summary>
/// Outcome categories for a protect / edit operation. Mirrors the ErrorCode
/// strings the legacy PowerShell engine returned (PRE_ENCRYPTED, FILE_LOCKED,
/// QPDF_FAIL, ...) so behaviour and logging stay equivalent.
/// </summary>
public enum ProtectErrorCode
{
    Ok,
    InputNotFound,
    OutputExists,
    PreEncrypted,
    FileLocked,
    EngineFailure,
    WrongPassword,
    NotProtected,
    Cancelled,
    Unsupported,
}

/// <summary>Result of protecting or editing a single file. Never carries the password.</summary>
public sealed record ProtectResult(bool Success, ProtectErrorCode Code, string? OutputPath, string Message)
{
    public static ProtectResult Ok(string outputPath, string message = "") =>
        new(true, ProtectErrorCode.Ok, outputPath, message);

    public static ProtectResult Fail(ProtectErrorCode code, string message) =>
        new(false, code, null, message);
}

/// <summary>Per-operation switches. Defaults match config/settings.default.json in the legacy tool.</summary>
public sealed record ProtectOptions
{
    /// <summary>Allow writing over an existing output file (overwrite-in-place opt-in).</summary>
    public bool AllowOverwrite { get; init; }

    /// <summary>Apply the \\?\ long-path prefix when invoking native binaries.</summary>
    public bool LongPathPrefix { get; init; } = true;
}

/// <summary>How an existing password should be changed.</summary>
public enum PasswordEditMode
{
    /// <summary>Add protection to a file that has none.</summary>
    Add,
    /// <summary>Replace the existing password with a new one.</summary>
    Change,
    /// <summary>Strip protection entirely.</summary>
    Remove,
}
