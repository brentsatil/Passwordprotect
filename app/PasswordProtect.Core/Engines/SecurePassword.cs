using System.Runtime.InteropServices;
using System.Security;

namespace PasswordProtect.Core;

/// <summary>
/// Helpers for handling a <see cref="SecureString"/> password. The plaintext is
/// materialised only at the moment it is needed and the BSTR is zero-freed
/// immediately afterwards — the same SecureString→BSTR→ZeroFreeBSTR dance the
/// legacy engines used. (The transient managed string copy lives until GC, an
/// unavoidable consequence of passing a password on a child argv, exactly as
/// before.)
/// </summary>
public static class SecurePassword
{
    public static SecureString FromString(string value)
    {
        var ss = new SecureString();
        foreach (char c in value) ss.AppendChar(c);
        ss.MakeReadOnly();
        return ss;
    }

    /// <summary>Run <paramref name="body"/> with the decrypted plaintext, then wipe the BSTR.</summary>
    public static T Use<T>(SecureString secret, Func<string, T> body)
    {
        IntPtr bstr = Marshal.SecureStringToBSTR(secret);
        try
        {
            string plain = Marshal.PtrToStringBSTR(bstr)!;
            return body(plain);
        }
        finally
        {
            Marshal.ZeroFreeBSTR(bstr);
        }
    }
}
