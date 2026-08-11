using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace CuroPdfProtect.Launcher
{
    /// <summary>
    /// Loud failure for a windowed process. Uses the user32 MessageBoxW P/Invoke
    /// rather than WinForms/WPF - the same choice src\Show-CuroError.ps1 makes,
    /// for the same reason: it works from any apartment with no assembly to load,
    /// so it cannot itself fail while trying to report a failure.
    ///
    /// Honours CURO_SUPPRESS_UI=1 (the CI seam) exactly as the PowerShell side does.
    /// </summary>
    internal static class ErrorDialog
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_OK = 0x0;
        private const uint MB_ICONERROR = 0x10;
        private const uint MB_TOPMOST = 0x40000;
        private const uint MB_SETFOREGROUND = 0x10000;

        /// <summary>
        /// Matches the PowerShell side EXACTLY: src\Show-CuroError.ps1 tests
        /// -eq '1'. Accepting anything non-empty here would half-suppress a
        /// value like "true" - dialogs gone on one side, still shown on the
        /// other - which is worse than either behaviour on its own.
        /// </summary>
        public static bool UiSuppressed
        {
            get { return Environment.GetEnvironmentVariable("CURO_SUPPRESS_UI") == "1"; }
        }

        public static string ErrorLogPath
        {
            get
            {
                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(local, "CuroPDFProtect", "error.log");
            }
        }

        public static void Show(string message)
        {
            if (UiSuppressed) { Console.Error.WriteLine(message); return; }
            MessageBoxW(IntPtr.Zero, message, "Curo PDF Protector",
                        MB_OK | MB_ICONERROR | MB_TOPMOST | MB_SETFOREGROUND);
        }

        /// <summary>
        /// Build the message shown when the PowerShell child exits non-zero.
        /// Detects the script-blocked signature specifically, because that is an
        /// IT policy problem the tool cannot fix and staff should not be told to
        /// "try again" - see docs\DECISIONS.md #14.
        /// </summary>
        public static string BuildFailureMessage(int exitCode, string stderr)
        {
            var sb = new StringBuilder();

            if (LooksScriptBlocked(stderr))
            {
                sb.AppendLine("Windows is blocking PowerShell scripts on this machine, so the tool");
                sb.AppendLine("cannot start. This is a Group Policy / AppLocker setting, not a fault");
                sb.AppendLine("in the tool, and it cannot be fixed from here.");
                sb.AppendLine();
                sb.AppendLine("Send this to whoever set the tool up. They can either allow the");
                sb.AppendLine("scripts or supply a code-signing certificate.");
                sb.AppendLine();
                sb.AppendLine("Run 'PasswordProtect.exe --diagnose' and include the output - it");
                sb.AppendLine("identifies which policy is responsible.");
            }
            else
            {
                sb.AppendLine("Curo PDF Protector could not complete (exit code " + exitCode + ").");
                sb.AppendLine();
                sb.AppendLine("A diagnostic report, if one was written, is here:");
                sb.AppendLine("  " + ErrorLogPath);
                sb.AppendLine();
                sb.AppendLine("Send that file to whoever set this up.");
            }

            if (!string.IsNullOrWhiteSpace(stderr))
            {
                sb.AppendLine();
                sb.AppendLine("Details:");
                sb.AppendLine(Truncate(stderr.Trim(), 1200));
            }
            return sb.ToString();
        }

        private static bool LooksScriptBlocked(string stderr)
        {
            if (string.IsNullOrEmpty(stderr)) return false;
            string s = stderr.ToLowerInvariant();
            // NB: deliberately no bare "unauthorizedaccess" token. PowerShell tags
            // the policy error FullyQualifiedErrorId : UnauthorizedAccess, but a
            // genuine file-permission UnauthorizedAccessException prints the same
            // word, and telling staff "IT policy is blocking scripts" for an ACL
            // problem sends the admin down the wrong path. The phrases below match
            // the ExecutionPolicy and AppLocker/SRP block messages specifically.
            return s.Contains("running scripts is disabled")
                || s.Contains("executionpolicy")
                || s.Contains("cannot be loaded because running scripts")
                || s.Contains("blocked by software restriction policies")
                || s.Contains("blocked by group policy");
        }

        private static string Truncate(string s, int max)
        {
            return s.Length <= max ? s : s.Substring(0, max) + Environment.NewLine + "... (truncated)";
        }
    }
}
