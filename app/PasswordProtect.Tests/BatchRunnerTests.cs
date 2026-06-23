using Xunit;
using System.Security;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

public class BatchRunnerTests
{
    private sealed class FakeProtector : IProtector
    {
        private readonly Func<string, ProtectResult> _onProtect;
        public FakeProtector(Func<string, ProtectResult> onProtect) => _onProtect = onProtect;

        public Task<bool> IsProtectedAsync(string input, CancellationToken ct = default) => Task.FromResult(false);

        public Task<ProtectResult> ProtectAsync(
            string input, string output, SecureString password, ProtectOptions options, CancellationToken ct = default)
            => Task.FromResult(_onProtect(input));
    }

    private static ProtectionJob Job(string input) =>
        new() { InputPath = input, Format = OutputFormat.SevenZip, OutputPath = input + ".7z" };

    [Fact]
    public async Task Runs_all_jobs_and_captures_per_file_outcome()
    {
        var registry = new ProtectorRegistry().Register(OutputFormat.SevenZip,
            new FakeProtector(input => input.Contains("bad")
                ? ProtectResult.Fail(ProtectErrorCode.EngineFailure, "boom")
                : ProtectResult.Ok(input + ".7z")));

        var jobs = new[] { Job("good1"), Job("bad"), Job("good2") };
        var seen = new List<int>();
        var progress = new Progress<BatchProgress>(p => { lock (seen) seen.Add(p.Completed); });

        await new BatchRunner(registry).RunAsync(
            jobs, SecurePassword.FromString("pw"), new ProtectOptions(), maxParallel: 2, progress);

        Assert.Equal(JobStatus.Succeeded, jobs[0].Status);
        Assert.Equal(JobStatus.Failed, jobs[1].Status);
        Assert.Equal(JobStatus.Succeeded, jobs[2].Status);
        Assert.Equal(ProtectErrorCode.EngineFailure, jobs[1].Code);
    }

    [Fact]
    public async Task One_failing_job_does_not_abort_the_batch()
    {
        var registry = new ProtectorRegistry().Register(OutputFormat.SevenZip,
            new FakeProtector(input => throw new InvalidOperationException("kaboom")));

        var jobs = new[] { Job("a"), Job("b") };
        await new BatchRunner(registry).RunAsync(
            jobs, SecurePassword.FromString("pw"), new ProtectOptions(), maxParallel: 4);

        Assert.All(jobs, j => Assert.Equal(JobStatus.Failed, j.Status));
        Assert.All(jobs, j => Assert.Contains("kaboom", j.Message));
    }

    [Fact]
    public async Task Cancellation_is_observed()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var registry = new ProtectorRegistry().Register(OutputFormat.SevenZip,
            new FakeProtector(_ => ProtectResult.Ok("x")));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new BatchRunner(registry).RunAsync(
                new[] { Job("a") }, SecurePassword.FromString("pw"), new ProtectOptions(),
                maxParallel: 1, progress: null, ct: cts.Token));
    }
}
