namespace PasswordProtect.App;

public enum CliVerb { None, Protect, Register, Unregister }

/// <summary>Parses the command line. Bare file paths (e.g. from the right-click
/// <c>--protect "%1"</c> verb or a drag-onto-exe) become the initial queue.</summary>
public sealed class CliOptions
{
    public CliVerb Verb { get; init; }
    public IReadOnlyList<string> Files { get; init; } = Array.Empty<string>();

    public static CliOptions Parse(string[] args)
    {
        var files = new List<string>();
        CliVerb verb = CliVerb.None;

        foreach (string a in args)
        {
            switch (a.ToLowerInvariant())
            {
                case "--register-context-menu":
                case "--register":
                    verb = CliVerb.Register;
                    break;
                case "--unregister-context-menu":
                case "--unregister":
                    verb = CliVerb.Unregister;
                    break;
                case "--protect":
                    if (verb == CliVerb.None) verb = CliVerb.Protect;
                    break;
                default:
                    if (!a.StartsWith("--", StringComparison.Ordinal)) files.Add(a);
                    break;
            }
        }

        if (files.Count > 0 && verb == CliVerb.None) verb = CliVerb.Protect;
        return new CliOptions { Verb = verb, Files = files };
    }
}
