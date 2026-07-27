using System.Diagnostics;

namespace PasswordProtect.Core;

/// <summary>Captured output of a finished child process.</summary>
public sealed record ProcessResult(int ExitCode, string StdOut, string StdErr)
{
    /// <summary>Combined stream text, matching the legacy 7z wrapper which concatenated both.</summary>
    public string Combined => string.Concat(StdErr, StdOut);
}

/// <summary>
/// Centralised native-process launcher. Uses <see cref="ProcessStartInfo.ArgumentList"/>
/// (correct CommandLineToArgvW quoting on Windows), never a shell, and never logs argv —
/// the same guarantees the legacy PowerShell engines provided. Passwords passed in
/// <paramref name="args"/> live only on the child argv, exactly as before.
/// </summary>
public static class NativeProcessRunner
{
    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> args,
        CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        // Read both streams concurrently to avoid pipe-buffer deadlock.
        Task<string> outTask = proc.StandardOutput.ReadToEndAsync();
        Task<string> errTask = proc.StandardError.ReadToEndAsync();

        try
        {
            await proc.WaitForExitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch { /* best effort */ }
            throw;
        }

        string stdout = await outTask.ConfigureAwait(false);
        string stderr = await errTask.ConfigureAwait(false);
        return new ProcessResult(proc.ExitCode, stdout, stderr);
    }
}
