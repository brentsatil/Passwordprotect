using Microsoft.Win32;

namespace PasswordProtect.App;

/// <summary>
/// Registers / removes the "Protect with password" Explorer right-click verb
/// under HKCU (no admin needed). Uses
/// <c>HKCU\Software\Classes\SystemFileAssociations\&lt;ext&gt;\shell</c> so it adds a
/// verb without hijacking the file type's default open action. The verb's command
/// points at this exe with <c>--protect "%1"</c>.
/// </summary>
public static class ContextMenuRegistrar
{
    public const string VerbKey = "PasswordProtect";
    public const string Label = "Protect with password";

    public static readonly string[] Extensions = { ".pdf", ".docx", ".xlsx", ".pptx" };

    private static string KeyPath(string ext) =>
        $@"Software\Classes\SystemFileAssociations\{ext}\shell\{VerbKey}";

    public static void Register(string exePath)
    {
        foreach (string ext in Extensions)
        {
            using RegistryKey shell = Registry.CurrentUser.CreateSubKey(KeyPath(ext));
            shell.SetValue(null, Label);
            shell.SetValue("Icon", exePath);
            using RegistryKey command = shell.CreateSubKey("command");
            command.SetValue(null, $"\"{exePath}\" --protect \"%1\"");
        }
    }

    public static void Unregister()
    {
        foreach (string ext in Extensions)
        {
            try
            {
                Registry.CurrentUser.DeleteSubKeyTree(KeyPath(ext), throwOnMissingSubKey: false);
            }
            catch
            {
                // best effort — a missing key is success for our purposes
            }
        }
    }

    public static bool IsRegistered()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(KeyPath(Extensions[0]));
        return key is not null;
    }
}
