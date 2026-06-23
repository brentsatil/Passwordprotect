using Xunit;
using PasswordProtect.Core;

namespace PasswordProtect.Tests;

public class ArgvQuotingTests
{
    [Theory]
    [InlineData("simple", "simple")]
    [InlineData("has space", "\"has space\"")]
    [InlineData("", "\"\"")]
    [InlineData("a\"b", "\"a\\\"b\"")]
    public void Quote_follows_commandlinetoargvw_rules(string input, string expected)
    {
        Assert.Equal(expected, ArgvQuoting.Quote(input));
    }

    [Fact]
    public void Quote_handles_trailing_backslashes_before_quote_boundary()
    {
        // A path ending in a backslash must double its backslashes inside quotes.
        Assert.Equal("\"a b\\\\\"", ArgvQuoting.Quote(@"a b\"));
    }

    [Fact]
    public void Null_becomes_empty_quotes()
    {
        Assert.Equal("\"\"", ArgvQuoting.Quote(null));
    }
}
