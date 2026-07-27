using System.Globalization;

namespace PasswordProtect.Core;

/// <summary>Inputs for building one output file name.</summary>
public sealed class NamingContext
{
    public required string InputPath { get; init; }

    /// <summary>Extension (with dot) for the protected output, from <see cref="FormatResolver.OutputExtension"/>.</summary>
    public required string OutputExtension { get; init; }

    public string Template { get; init; } = "{OriginalName}_protected{Ext}";
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.Now;
    public int Sequence { get; init; } = 1;

    /// <summary>Best-effort field detected inside the document (Phase 4); empty when unknown.</summary>
    public string? DetectedName { get; init; }
    public string? DetectedDate { get; init; }

    /// <summary>Output folder; defaults to the input's folder when null.</summary>
    public string? TargetDirectory { get; init; }

    /// <summary>When true (overwrite-in-place), collisions are not auto-renamed.</summary>
    public bool AllowOverwrite { get; init; }
}

/// <summary>
/// Turns a <see cref="NamingContext"/> into a concrete, sanitized, collision-safe
/// output path. Token values are computed deterministically from the context so
/// naming is fully unit-testable without touching the clock or the filesystem.
/// </summary>
public sealed class NamingEngine
{
    public string BuildName(NamingContext ctx)
    {
        var tokens = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["OriginalName"] = Path.GetFileNameWithoutExtension(ctx.InputPath),
            ["Ext"] = ctx.OutputExtension,
            ["Date"] = ctx.Timestamp.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["DDMMYYYY"] = ctx.Timestamp.ToString("ddMMyyyy", CultureInfo.InvariantCulture),
            ["YYYYMMDD"] = ctx.Timestamp.ToString("yyyyMMdd", CultureInfo.InvariantCulture),
            ["Seq"] = ctx.Sequence.ToString(CultureInfo.InvariantCulture),
            ["DetectedName"] = ctx.DetectedName ?? "",
            ["DetectedDate"] = ctx.DetectedDate ?? "",
        };

        string expanded = NameTemplate.Expand(ctx.Template, tokens);
        return FilenameSanitizer.SanitizeFileName(expanded);
    }

    public string BuildFullPath(NamingContext ctx, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        string name = BuildName(ctx);
        string dir = ctx.TargetDirectory ?? Path.GetDirectoryName(ctx.InputPath) ?? ".";
        string full = Path.Combine(dir, name);
        return ctx.AllowOverwrite ? full : ResolveCollision(full, exists);
    }

    /// <summary>Append " (2)", " (3)", ... before the extension until a free name is found.</summary>
    public static string ResolveCollision(string path, Func<string, bool> exists)
    {
        if (!exists(path)) return path;

        string dir = Path.GetDirectoryName(path) ?? ".";
        string stem = Path.GetFileNameWithoutExtension(path);
        string ext = Path.GetExtension(path);
        for (int i = 2; i < 100_000; i++)
        {
            string candidate = Path.Combine(dir, $"{stem} ({i}){ext}");
            if (!exists(candidate)) return candidate;
        }
        throw new IOException("Could not find a free output filename.");
    }
}
