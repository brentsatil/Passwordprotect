namespace PasswordProtect.Core;

/// <summary>
/// Fail-closed lock check ported from the legacy engines: open the input with
/// FileShare.None; if it is held by another process (e.g. open in Acrobat or
/// Word) the open fails and we refuse to proceed rather than risk a torn read.
/// </summary>
public static class FileLock
{
    public static bool CanOpenForRead(string path)
    {
        try
        {
            using var fs = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
