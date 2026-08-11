using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace CuroPdfProtect.Launcher
{
    /// <summary>
    /// Extracts the embedded PowerShell tool to a per-user cache and hands off to
    /// it, mirroring what PasswordProtect.cmd does today:
    ///   powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ... [files]
    ///
    /// Exit codes are relayed from the child unchanged, so the tool's contract
    /// (0 ok, 3 input-not-found, 4 encrypt-failed, 5 ESCROW_OFFLINE, ...) survives.
    /// The launcher itself uses 2 for its own failures, matching the tool's
    /// "2 = other/config/crash-in-shim" convention.
    /// </summary>
    internal static class Program
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int dwProcessId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();
        private const int ATTACH_PARENT_PROCESS = -1;

        private static bool _hasConsole;
        private static bool _allocatedConsole;

        [STAThread]
        private static int Main(string[] args)
        {
            SetUpConsole();
            try
            {
                return Run(args);
            }
            catch (Exception ex)
            {
                string msg = "Curo PDF Protector could not start." + Environment.NewLine
                           + Environment.NewLine + ex.Message;
                if (_hasConsole) Console.Error.WriteLine(msg); else ErrorDialog.Show(msg);
                return 2;
            }
            finally
            {
                // A console we created ourselves dies with the process, taking the
                // output with it. Hold it open so the operator can actually read.
                if (_allocatedConsole && !ErrorDialog.UiSuppressed)
                {
                    Console.Out.WriteLine();
                    Console.Out.Write("Press Enter to close...");
                    try { Console.In.ReadLine(); } catch { }
                }
            }
        }

        private static int Run(string[] args)
        {
            string verb = args.Length > 0 ? args[0] : string.Empty;

            // Any --verb is a console interaction: it either prints a report or
            // (setup) prompts for input. Double-clicked from Explorer there is no
            // console to use, so make one. The plain protect flow deliberately
            // does NOT do this - it must stay windowless behind the WPF dialogs.
            if (verb.StartsWith("-", StringComparison.Ordinal) || verb == "/?")
                EnsureConsole();

            if (Eq(verb, "--help") || Eq(verb, "-h") || Eq(verb, "/?"))
            {
                WriteLine(HelpText());
                return 0;
            }

            if (Eq(verb, "--version"))
            {
                List<PayloadItem> items = Payload.GetItems();
                WriteLine("Curo PDF Protector launcher");
                WriteLine("payload-id : " + Payload.ComputeId(items));
                WriteLine("files      : " + items.Count);
                WriteLine("cache      : " + Payload.CacheRoot(Payload.ComputeId(items)));
                return 0;
            }

            // --diagnose answers "why are scripts blocked here?". It deliberately
            // runs via -EncodedCommand rather than -File: ExecutionPolicy governs
            // script FILES, so inline script text still runs on exactly the
            // machines where the tool itself will not start.
            if (Eq(verb, "--diagnose"))
                return RunEncoded(DiagnosticScript());

            bool extractOnly = Eq(verb, "--extract-only");
            bool verify = Eq(verb, "--verify");

            bool extracted;
            string root = Payload.EnsureExtracted(verify, out extracted);

            if (extractOnly || verify)
            {
                WriteLine(root);
                WriteLine(extracted ? "extracted" : "cached");
                return 0;
            }

            // Everything else is a hand-off to a script in the extracted payload.
            string script;
            IEnumerable<string> forward;
            bool echo;
            if (Eq(verb, "--setup"))
            {
                script = Path.Combine(root, "setup.ps1");
                forward = Slice(args, 1);
                echo = true;                  // setup reports progress and prompts
            }
            else
            {
                script = Path.Combine(root, "PasswordProtect.ps1");
                forward = args;               // bare paths = files to protect
                echo = _hasConsole;           // silent behind the WPF dialogs otherwise
            }

            if (!File.Exists(script))
                throw new FileNotFoundException("Extracted payload is missing " + Path.GetFileName(script) + ".", script);

            return RunScript(script, forward, echo);
        }

        // ---------------------------------------------------------------- child

        private static string PowerShellExe()
        {
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                     "WindowsPowerShell", "v1.0", "powershell.exe");
            return File.Exists(ps) ? ps : "powershell.exe";
        }

        private static int RunScript(string scriptPath, IEnumerable<string> forwarded, bool echo)
        {
            var sb = new StringBuilder();
            sb.Append("-NoProfile -ExecutionPolicy Bypass -STA -File ").Append(Quote(scriptPath));
            foreach (string a in forwarded) sb.Append(' ').Append(Quote(a));
            return Launch(sb.ToString(), echo);
        }

        private static int RunEncoded(string script)
        {
            string b64 = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            return Launch("-NoProfile -EncodedCommand " + b64, true);
        }

        /// <summary>
        /// Start powershell.exe and relay its exit code.
        ///
        /// When <paramref name="echo"/>, the child's streams are redirected and
        /// pumped to ours asynchronously. Relying on handle inheritance instead
        /// does NOT work here: this is a GUI-subsystem exe, so it has no console
        /// of its own, and a child's output can miss the pipe our caller is
        /// capturing. Pumping is deterministic, and being async keeps prompts
        /// (setup's Read-Host) appearing live rather than after the child exits.
        /// stdin is deliberately left inherited so those prompts can be answered.
        /// </summary>
        private static int Launch(string arguments, bool echo)
        {
            var psi = new ProcessStartInfo
            {
                FileName = PowerShellExe(),
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = echo,
                RedirectStandardError = true,
            };

            var errBuf = new StringBuilder();
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                if (echo)
                {
                    p.OutputDataReceived += (s, e) => { if (e.Data != null) SafeWrite(Console.Out, e.Data); };
                    p.ErrorDataReceived += (s, e) =>
                    {
                        if (e.Data == null) return;
                        errBuf.AppendLine(e.Data);
                        SafeWrite(Console.Error, e.Data);
                    };
                }
                else
                {
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) errBuf.AppendLine(e.Data); };
                }

                p.Start();
                if (echo) p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();

                int rc = p.ExitCode;
                if (rc != 0 && !_hasConsole)
                    ErrorDialog.Show(ErrorDialog.BuildFailureMessage(rc, errBuf.ToString()));
                return rc;
            }
        }

        private static void SafeWrite(System.IO.TextWriter w, string line)
        {
            try { w.WriteLine(line); } catch { /* no stream to write to */ }
        }

        // ----------------------------------------------------------- diagnostic

        private static string DiagnosticScript()
        {
            // Kept ASCII and defensive: every probe is individually guarded so one
            // unavailable cmdlet cannot abort the report.
            //
            // The probe list mirrors src\Config.psm1 Get-CuroConfigPath exactly,
            // including the legacy <tool root>\config\settings.json location -
            // which for THIS exe means inside the extracted payload cache. That
            // path is computable without extracting anything, so inject it as a
            // single-quoted PowerShell literal (quotes doubled).
            string legacyCfg = null;
            try
            {
                legacyCfg = Path.Combine(
                    Payload.CacheRoot(Payload.ComputeId(Payload.GetItems())),
                    "config", "settings.json");
            }
            catch { /* diagnostics must never fail over this */ }
            string legacyRow = legacyCfg == null
                ? "    @{ n='legacy (extracted payload)'; p=$null }"
                : "    @{ n='legacy (extracted payload)'; p='" + legacyCfg.Replace("'", "''") + "' }";

            return string.Join(Environment.NewLine, new[]
            {
                "$ErrorActionPreference = 'Continue'",
                "Write-Output '===== Curo PDF Protector diagnostics ====='",
                "Write-Output ('PSVersion     : ' + $PSVersionTable.PSVersion)",
                "Write-Output ('LanguageMode  : ' + $ExecutionContext.SessionState.LanguageMode)",
                "Write-Output ('OS            : ' + [System.Environment]::OSVersion.VersionString)",
                "Write-Output ''",
                "Write-Output '--- ExecutionPolicy by scope (MachinePolicy/UserPolicy = set by GPO) ---'",
                "try { Get-ExecutionPolicy -List | Out-String | Write-Output } catch { Write-Output ('  failed: ' + $_.Exception.Message) }",
                "Write-Output '--- AppLocker script rules ---'",
                "try {",
                "  $ap = Get-AppLockerPolicy -Effective -ErrorAction Stop",
                "  $xml = $ap.ToXml()",
                "  if ($xml -match 'Type=\"Script\"') { Write-Output '  AppLocker HAS Script rules - these can block .ps1 regardless of ExecutionPolicy.' }",
                "  else { Write-Output '  No AppLocker Script rules found.' }",
                "} catch { Write-Output ('  AppLocker not configured or unreadable: ' + $_.Exception.Message) }",
                "Write-Output '--- WDAC / Device Guard ---'",
                "try {",
                "  $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\\Microsoft\\Windows\\DeviceGuard -ErrorAction Stop",
                "  Write-Output ('  CodeIntegrityPolicyEnforcementStatus: ' + $dg.CodeIntegrityPolicyEnforcementStatus)",
                "} catch { Write-Output ('  Not available: ' + $_.Exception.Message) }",
                "Write-Output ''",
                "Write-Output '--- Which settings.json is live (probe order) ---'",
                "try {",
                "  $probe = @(",
                "    @{ n='CURO_SETTINGS_PATH'; p=$env:CURO_SETTINGS_PATH },",
                "    @{ n='per-user (LOCALAPPDATA)'; p=(Join-Path $env:LOCALAPPDATA 'CuroPDFProtect\\settings.json') },",
                "    @{ n='machine-wide (ProgramData)'; p=(Join-Path $env:ProgramData 'CuroPDFProtect\\settings.json') },",
                legacyRow,
                "  )",
                "  $live = $null",
                "  foreach ($e in $probe) {",
                "    if (-not $e.p) { Write-Output ('  [ - ] ' + $e.n + ': not set'); continue }",
                "    $exists = Test-Path -LiteralPath $e.p",
                "    $mark = if ($exists -and -not $live) { 'LIVE' } elseif ($exists) { 'shadowed' } else { ' - ' }",
                "    if ($exists -and -not $live) { $live = $e.p }",
                "    Write-Output ('  [' + $mark + '] ' + $e.n + ': ' + $e.p)",
                "  }",
                "  if (-not $live) { Write-Output '  No settings.json found - run: PasswordProtect.exe --setup' }",
                "} catch { Write-Output ('  failed: ' + $_.Exception.Message) }",
                "Write-Output '  (A folder deployment (PasswordProtect.cmd) probes its own <folder>\\config\\settings.json too.)'",
                "Write-Output ''",
                "Write-Output 'If LanguageMode is not FullLanguage, or MachinePolicy/UserPolicy is not'",
                "Write-Output 'Undefined, or AppLocker has Script rules, then IT policy is blocking the'",
                "Write-Output 'scripts. An exe cannot work around that - the fix is signing the scripts'",
                "Write-Output 'or an allowlist. Send this whole report to whoever set the tool up.'",
                "exit 0",
            });
        }

        // --------------------------------------------------------------- helpers

        private static string HelpText()
        {
            return string.Join(Environment.NewLine, new[]
            {
                "Curo PDF Protector - portable launcher",
                "",
                "  PasswordProtect.exe                 open the drop window",
                "  PasswordProtect.exe <file> [...]    protect the given PDFs",
                "  PasswordProtect.exe --setup [args]  run first-time setup on this machine",
                "  PasswordProtect.exe --diagnose      report why scripts may be blocked here",
                "  PasswordProtect.exe --verify        re-extract and hash-verify the payload",
                "  PasswordProtect.exe --extract-only  extract the payload, print its path",
                "  PasswordProtect.exe --version       payload id and cache location",
                "",
                "You can also drag PDFs onto the exe.",
                "",
                "Note: --setup prompts for the escrow .pfx password rather than taking it",
                "as an argument. A password on a command line is visible in the process",
                "list, which is precisely what this tool's design forbids elsewhere.",
            });
        }

        private static void SetUpConsole()
        {
            try
            {
                if (Console.IsOutputRedirected) { _hasConsole = true; return; }
                if (AttachConsole(ATTACH_PARENT_PROCESS)) { RebindStreams(); _hasConsole = true; }
            }
            catch { _hasConsole = false; }
        }

        /// <summary>Create a console if this process has none, for verb output/prompts.</summary>
        private static void EnsureConsole()
        {
            if (_hasConsole || ErrorDialog.UiSuppressed) return;
            try
            {
                if (AllocConsole())
                {
                    RebindStreams();
                    _hasConsole = true;
                    _allocatedConsole = true;
                }
            }
            catch { /* fall back to dialogs */ }
        }

        private static void RebindStreams()
        {
            var so = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
            Console.SetOut(so);
            var se = new StreamWriter(Console.OpenStandardError()) { AutoFlush = true };
            Console.SetError(se);
            Console.SetIn(new StreamReader(Console.OpenStandardInput()));
        }

        private static void WriteLine(string s)
        {
            if (_hasConsole) Console.Out.WriteLine(s); else ErrorDialog.Show(s);
        }

        private static bool Eq(string a, string b)
        {
            return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }

        private static IEnumerable<string> Slice(string[] args, int start)
        {
            for (int i = start; i < args.Length; i++) yield return args[i];
        }

        /// <summary>
        /// Windows command-line quoting. .NET Framework has no
        /// ProcessStartInfo.ArgumentList, so arguments must be quoted by hand -
        /// the same constraint the PS 5.1 side lives with.
        /// </summary>
        private static string Quote(string arg)
        {
            if (arg == null) arg = string.Empty;
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;

            var sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
                sb.Append('\\', slashes); slashes = 0;
                sb.Append(c);
            }
            sb.Append('\\', slashes * 2).Append('"');
            return sb.ToString();
        }
    }
}
