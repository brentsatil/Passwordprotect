using System.Security;

namespace PasswordProtect.Core;

public enum JobStatus { Pending, Running, Succeeded, Failed, Skipped }

/// <summary>One unit of work in a bulk run. Mutable so the UI can bind to live status.</summary>
public sealed class ProtectionJob
{
    public required string InputPath { get; init; }
    public required OutputFormat Format { get; init; }
    public required string OutputPath { get; set; }

    public JobStatus Status { get; set; } = JobStatus.Pending;
    public string Message { get; set; } = "";
    public ProtectErrorCode? Code { get; set; }
}

/// <summary>Progress notification emitted after each job settles.</summary>
public sealed record BatchProgress(ProtectionJob Job, int Completed, int Total);

/// <summary>
/// Runs a list of <see cref="ProtectionJob"/> through the registered engines with
/// bounded parallelism and cooperative cancellation. A single engine failure never
/// throws out of the batch — it is captured on the job — so one bad file does not
/// abort the rest (mirrors the legacy <c>Invoke-ProtectOne</c> contract).
/// </summary>
public sealed class BatchRunner
{
    private readonly ProtectorRegistry _registry;

    public BatchRunner(ProtectorRegistry registry) => _registry = registry;

    public async Task RunAsync(
        IReadOnlyList<ProtectionJob> jobs,
        SecureString password,
        ProtectOptions options,
        int maxParallel,
        IProgress<BatchProgress>? progress = null,
        CancellationToken ct = default)
    {
        using var sem = new SemaphoreSlim(Math.Max(1, maxParallel));
        int completed = 0;

        var tasks = jobs.Select(async job =>
        {
            await sem.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                ct.ThrowIfCancellationRequested();
                job.Status = JobStatus.Running;

                IProtector protector = _registry.Resolve(job.Format);
                ProtectResult res = await protector
                    .ProtectAsync(job.InputPath, job.OutputPath, password, options, ct)
                    .ConfigureAwait(false);

                job.Code = res.Code;
                job.Status = res.Success ? JobStatus.Succeeded : JobStatus.Failed;
                job.Message = res.Message;
                if (res.Success && res.OutputPath != null) job.OutputPath = res.OutputPath;
            }
            catch (OperationCanceledException)
            {
                job.Status = JobStatus.Skipped;
                job.Message = "Cancelled";
            }
            catch (Exception ex)
            {
                job.Status = JobStatus.Failed;
                job.Message = ex.Message;
            }
            finally
            {
                int done = Interlocked.Increment(ref completed);
                progress?.Report(new BatchProgress(job, done, jobs.Count));
                sem.Release();
            }
        }).ToList();

        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>Bulk add/change/remove of passwords, same parallelism/cancellation contract as <see cref="RunAsync"/>.</summary>
    public async Task RunEditAsync(
        IReadOnlyList<ProtectionJob> jobs,
        SecureString? current,
        SecureString? newPassword,
        PasswordEditMode mode,
        ProtectOptions options,
        int maxParallel,
        IProgress<BatchProgress>? progress = null,
        CancellationToken ct = default)
    {
        using var sem = new SemaphoreSlim(Math.Max(1, maxParallel));
        int completed = 0;

        var tasks = jobs.Select(async job =>
        {
            await sem.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                ct.ThrowIfCancellationRequested();
                job.Status = JobStatus.Running;

                IPasswordEditor editor = _registry.ResolveEditor(job.Format);
                ProtectResult res = await editor
                    .ChangePasswordAsync(job.InputPath, job.OutputPath, current, newPassword, mode, options, ct)
                    .ConfigureAwait(false);

                job.Code = res.Code;
                job.Status = res.Success ? JobStatus.Succeeded : JobStatus.Failed;
                job.Message = res.Message;
                if (res.Success && res.OutputPath != null) job.OutputPath = res.OutputPath;
            }
            catch (OperationCanceledException)
            {
                job.Status = JobStatus.Skipped;
                job.Message = "Cancelled";
            }
            catch (Exception ex)
            {
                job.Status = JobStatus.Failed;
                job.Message = ex.Message;
            }
            finally
            {
                int done = Interlocked.Increment(ref completed);
                progress?.Report(new BatchProgress(job, done, jobs.Count));
                sem.Release();
            }
        }).ToList();

        await Task.WhenAll(tasks).ConfigureAwait(false);
    }
}
