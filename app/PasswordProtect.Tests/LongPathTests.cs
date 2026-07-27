using Xunit;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

public class LongPathTests
{
    [Fact]
    public void Local_path_gets_extended_prefix()
    {
        Assert.Equal(@"\\?\C:\docs\a.pdf", LongPath.AddPrefix(@"C:\docs\a.pdf"));
    }

    [Fact]
    public void Unc_path_gets_unc_extended_prefix()
    {
        Assert.Equal(@"\\?\UNC\server\share\a.pdf", LongPath.AddPrefix(@"\\server\share\a.pdf"));
    }

    [Fact]
    public void Already_prefixed_is_unchanged()
    {
        Assert.Equal(@"\\?\C:\x", LongPath.AddPrefix(@"\\?\C:\x"));
    }
}
