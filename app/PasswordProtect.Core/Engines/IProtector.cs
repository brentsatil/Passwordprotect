using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// A per-format encryption engine. Each implementation wraps a native tool or
/// library and preserves the legacy fail-closed guarantees (refuse already-
/// protected or locked inputs, temp-then-atomic-rename, never log the password).
/// </summary>
public interface IProtector
{
    /// <summary>True if the input already carries password protection.</summary>
    Task<bool> IsProtectedAsync(string input, CancellationToken ct = default);

    /// <summary>Produce a protected copy of <paramref name="input"/> at <paramref name="output"/>.</summary>
    Task<ProtectResult> ProtectAsync(
        string input, string output, SecureString password, ProtectOptions options, CancellationToken ct = default);
}

/// <summary>
/// Adds, changes or removes the password on an already-handled file. Implemented
/// by engines that support editing existing protection (qpdf, 7z, Office).
/// </summary>
public interface IPasswordEditor
{
    /// <param name="current">The file's current password (ignored for <see cref="PasswordEditMode.Add"/>).</param>
    /// <param name="newPassword">The new password (null/ignored for <see cref="PasswordEditMode.Remove"/>).</param>
    Task<ProtectResult> ChangePasswordAsync(
        string input, string output, SecureString? current, SecureString? newPassword,
        PasswordEditMode mode, ProtectOptions options, CancellationToken ct = default);
}

/// <summary>Maps an <see cref="OutputFormat"/> to the engine that handles it.</summary>
public sealed class ProtectorRegistry
{
    private readonly Dictionary<OutputFormat, IProtector> _map = new();

    public ProtectorRegistry Register(OutputFormat format, IProtector protector)
    {
        _map[format] = protector;
        return this;
    }

    public bool Supports(OutputFormat format) => _map.ContainsKey(format);

    public IProtector Resolve(OutputFormat format) =>
        _map.TryGetValue(format, out var p)
            ? p
            : throw new NotSupportedException($"No protector registered for {format}.");

    public IPasswordEditor ResolveEditor(OutputFormat format) =>
        Resolve(format) as IPasswordEditor
        ?? throw new NotSupportedException($"{format} does not support password editing.");
}
