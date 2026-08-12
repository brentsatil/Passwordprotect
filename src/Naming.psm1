# Naming.psm1
# Output-file naming for protected PDFs: template expansion, filename
# sanitising, and collision resolution. Ported from the app\ prototype's
# NamingEngine/NameTemplate/FilenameSanitizer (C#) when its batch UI was
# folded into this tool - see docs\DECISIONS.md.
#
# The ONE rule that matters: with no output_name_template configured, the
# result must be byte-identical to the historical "<stem><output_suffix><ext>"
# naming. tests\Naming.Tests.ps1 pins that equivalence; the core protect path
# and the batch window's preview column both call Get-ProtectedOutputPath, so
# the name shown before a run and the file written by the run cannot drift.

function Expand-NameTemplate {
    <#
    .SYNOPSIS
        Expand {Token} / {Token:fmt} placeholders from a hashtable.
        Unknown tokens are left verbatim so a typo degrades visibly rather
        than vanishing. {Seq:000}-style formats apply .NET numeric formatting
        when the token value parses as an integer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Template,
        [Parameter(Mandatory)] [hashtable] $Tokens
    )
    $pattern = '\{(?<name>[A-Za-z][A-Za-z0-9]*)(?::(?<fmt>[^}]+))?\}'
    $evaluator = {
        param($m)
        $name = $m.Groups['name'].Value
        if (-not $Tokens.ContainsKey($name)) { return $m.Value }   # leave verbatim
        $value = [string]$Tokens[$name]
        $fmt = if ($m.Groups['fmt'].Success) { $m.Groups['fmt'].Value } else { $null }
        if ($fmt) {
            $n = 0
            if ([int]::TryParse($value, [ref]$n)) {
                return $n.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        return $value
    }
    return [regex]::Replace($Template, $pattern, [System.Text.RegularExpressions.MatchEvaluator]$evaluator)
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Make an arbitrary string safe as a single Windows file-name component:
        invalid characters become '_', trailing dots/spaces are trimmed
        (Windows forbids them), and an empty result becomes '_'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $cleaned = $sb.ToString().Trim().TrimEnd('.', ' ')
    if ($cleaned.Length -eq 0) { return '_' }
    return $cleaned
}

function Resolve-NameCollision {
    <#
    .SYNOPSIS
        Append " (2)", " (3)", ... before the extension until a free name is
        found. NOT used by the protect core - its policy is refuse-on-exists
        unless the user ticked overwrite, and that policy is unchanged. This
        exists for previews/tools and is exported so tests pin the behaviour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [scriptblock] $ExistsTest = { param($p) Test-Path -LiteralPath $p }
    )
    if (-not (& $ExistsTest $Path)) { return $Path }
    $dir  = [System.IO.Path]::GetDirectoryName($Path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [System.IO.Path]::GetExtension($Path)
    for ($i = 2; $i -lt 100000; $i++) {
        $candidate = Join-Path $dir ('{0} ({1}){2}' -f $stem, $i, $ext)
        if (-not (& $ExistsTest $candidate)) { return $candidate }
    }
    throw 'Could not find a free output filename.'
}

function Get-NameTemplateFromConfig {
    # Internal helper: the effective template for a config. The key is
    # OPTIONAL - deployments without it keep the historical suffix naming.
    param([Parameter(Mandatory)] $Config)
    if ($Config.PSObject.Properties['output_name_template'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.output_name_template)) {
        return [string]$Config.output_name_template
    }
    return ('{OriginalName}' + [string]$Config.output_suffix)
}

function Get-ProtectedOutputPath {
    <#
    .SYNOPSIS
        The full output path for protecting one file, from the config's
        optional output_name_template (default: historical suffix naming).
        Tokens: {OriginalName} {Ext} {Date} {DateCompact} {Seq} {ClientRef}.
        There is deliberately NO today's-date-as-DDMMYYYY token: in this tool
        that exact string means a client's DOB, and a template author WILL
        confuse them.
    .NOTES
        If the expanded name does not already end with the input's extension,
        the extension is appended - so "{OriginalName}_protected" and
        "{OriginalName}_protected{Ext}" produce the same file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $InputPath,
        [string] $ClientRef,
        [int] $Sequence = 1,
        [datetime] $Timestamp = (Get-Date)
    )
    $dir  = [System.IO.Path]::GetDirectoryName($InputPath)   # -LiteralPath can't take -Parent in PS 5.1
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext  = [System.IO.Path]::GetExtension($InputPath)
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture

    $tokens = @{
        OriginalName = $stem
        Ext          = $ext
        Date         = $Timestamp.ToString('yyyy-MM-dd', $inv)
        DateCompact  = $Timestamp.ToString('yyyyMMdd', $inv)
        Seq          = [string]$Sequence
        ClientRef    = if ($ClientRef) { $ClientRef } else { '' }
    }

    $template = Get-NameTemplateFromConfig -Config $Config
    $name = Get-SafeFileName -Name (Expand-NameTemplate -Template $template -Tokens $tokens)
    if (-not $name.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
        $name = "$name$ext"
    }
    return (Join-Path $dir $name)
}

function Get-UnprotectedOutputPath {
    <#
    .SYNOPSIS
        Destination for an unprotected copy: <stem><unprotected_suffix><ext>,
        default suffix "_unprotected".
    .NOTES
        A protected input is usually already named "..._protected.pdf", which
        would otherwise yield "..._protected_unprotected.pdf" - actively
        confusing on a file whose whole point is that it is NOT protected. The
        protected suffix is stripped from the stem first, so
        "Statement_protected.pdf" becomes "Statement_unprotected.pdf".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $InputPath
    )
    $dir  = [System.IO.Path]::GetDirectoryName($InputPath)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext  = [System.IO.Path]::GetExtension($InputPath)

    $protectedSuffix = [string]$Config.output_suffix
    if ($protectedSuffix -and $stem.EndsWith($protectedSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $stem = $stem.Substring(0, $stem.Length - $protectedSuffix.Length)
    }

    $suffix = if ($Config.PSObject.Properties['unprotected_suffix'] -and
                  -not [string]::IsNullOrWhiteSpace([string]$Config.unprotected_suffix)) {
        [string]$Config.unprotected_suffix
    } else { '_unprotected' }

    # Inner parens are load-bearing: in command-parsing mode
    # `Join-Path $dir (X) + $ext` passes '+' and $ext as extra ARGUMENTS to
    # Join-Path rather than concatenating, and the call fails.
    return (Join-Path $dir ((Get-SafeFileName -Name "$stem$suffix") + $ext))
}

function Get-TemplateWildcard {
    <#
    .SYNOPSIS
        The config's effective name template as a -like wildcard (every token
        becomes *), used by the folder batch to skip already-protected files.
        Matches against BaseName, exactly as the old "*<output_suffix>" filter
        did - the default template yields the identical "*_protected" pattern.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $template = Get-NameTemplateFromConfig -Config $Config
    $pattern = '\{[A-Za-z][A-Za-z0-9]*(?::[^}]+)?\}'
    $parts = [regex]::Split($template, $pattern)
    # Escape wildcard metacharacters in the literal parts so a template
    # containing [ or ] cannot corrupt the -like match.
    # No extra leading * is prepended: the split already yields one exactly
    # when the template STARTS with a token (the default does), and adding one
    # to a literal-prefix template would over-match - "SeCuro-plan" is not a
    # "Curo-{OriginalName}" output and must not be skipped.
    $escaped = @($parts | ForEach-Object { [System.Management.Automation.WildcardPattern]::Escape($_) })
    $wildcard = ($escaped -join '*')
    return ($wildcard -replace '\*{2,}', '*')
}

Export-ModuleMember -Function Expand-NameTemplate, Get-SafeFileName, Resolve-NameCollision, Get-ProtectedOutputPath, Get-UnprotectedOutputPath, Get-TemplateWildcard
