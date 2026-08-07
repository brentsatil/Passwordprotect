#Requires -Modules Pester
<#
  The WPF dialogs are the product's primary UX and, until this suite, had zero
  automated coverage: CI runs on a Windows Server image with no interactive
  desktop, so no window has ever been rendered.

  A desktop is not actually required to catch the failures that matter.
  XamlReader.Load builds the object graph without creating an HWND - it only
  needs an STA thread, which powershell.exe already provides. That is enough to
  prove the markup parses, that every FindName the script performs resolves,
  and that the visibility rules the script applies leave the user with
  something to read.

  The XAML lives in here-strings inside scripts that call ShowDialog() at the
  bottom and have no dot-source guard, so the markup is lifted out with the
  PowerShell AST rather than by running the file.
#>

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $script:SrcDir = Join-Path $PSScriptRoot '..\src'

    function Get-XamlFromScript {
        <#
          Pull the value of the `$xaml` assignment out of a script without
          executing it. Returns the raw markup string.
        #>
        param([Parameter(Mandatory)][string] $ScriptPath)

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count) { throw "$ScriptPath has parse errors: $($errors[0].Message)" }

        $assign = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq 'xaml'
        }, $true) | Select-Object -First 1

        if (-not $assign) { throw "No `$xaml assignment found in $ScriptPath" }

        $expr = $assign.Right
        if ($expr -is [System.Management.Automation.Language.CommandExpressionAst]) { $expr = $expr.Expression }
        if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return $expr.Value
        }
        throw "The `$xaml assignment in $ScriptPath is not a plain string literal (got $($expr.GetType().Name))."
    }

    function ConvertTo-Window {
        param([Parameter(Mandatory)][string] $Xaml)
        $reader = [System.Xml.XmlNodeReader]::new([xml]$Xaml)
        return [System.Windows.Markup.XamlReader]::Load($reader)
    }

    function Get-FindNameArguments {
        <#
          Every literal passed to .FindName('X') in the script - the exact set
          the script will look up at run time.
        #>
        param([Parameter(Mandatory)][string] $ScriptPath)

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $n.Member.Value -eq 'FindName'
        }, $true)

        $names = @()
        foreach ($c in $calls) {
            foreach ($a in $c.Arguments) {
                if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names += $a.Value }
            }
        }
        return @($names | Sort-Object -Unique)
    }

    $script:GuiScripts = @(
        (Join-Path $script:SrcDir 'Prompt-Drop.ps1'),
        (Join-Path $script:SrcDir 'Prompt-Password.ps1')
    )
}

Describe 'WPF dialogs load and are wired correctly' {

    It 'every dialog script has an extractable XAML blob' {
        foreach ($s in $script:GuiScripts) {
            $xaml = Get-XamlFromScript -ScriptPath $s
            $xaml | Should -Not -BeNullOrEmpty
            $xaml | Should -Match '<Window'
        }
    }

    It 'the XAML parses - catches XamlParseException before a user sees it' {
        foreach ($s in $script:GuiScripts) {
            $xaml = Get-XamlFromScript -ScriptPath $s
            { ConvertTo-Window -Xaml $xaml } | Should -Not -Throw -Because "$(Split-Path $s -Leaf) must produce a loadable window"
        }
    }

    It 'every FindName the script performs resolves on the loaded tree' {
        foreach ($s in $script:GuiScripts) {
            $win   = ConvertTo-Window -Xaml (Get-XamlFromScript -ScriptPath $s)
            $names = Get-FindNameArguments -ScriptPath $s
            $names.Count | Should -BeGreaterThan 0
            foreach ($n in $names) {
                $win.FindName($n) | Should -Not -BeNullOrEmpty -Because "$(Split-Path $s -Leaf) calls FindName('$n'), so a control with Name=`"$n`" must exist"
            }
        }
    }
}

Describe 'Business mode leaves the user something to read' {
    # The regression this pins: the business-mode explanation used to be written
    # into ManualHint, which is a CHILD of the ManualPanel being collapsed - so
    # the manual-password box vanished with nothing on screen saying why, and
    # the only feedback came from a modal after the user clicked Protect. The
    # launcher passes -RequireClientDob, so this is the path most staff hit.

    BeforeAll {
        $script:PwWindow = ConvertTo-Window -Xaml (Get-XamlFromScript -ScriptPath (Join-Path $script:SrcDir 'Prompt-Password.ps1'))
    }

    It 'has a business-mode hint that is NOT inside the panel business mode hides' {
        $panel = $script:PwWindow.FindName('ManualPanel')
        $hint  = $script:PwWindow.FindName('BusinessHint')
        $panel | Should -Not -BeNullOrEmpty
        $hint  | Should -Not -BeNullOrEmpty

        # Walk the LOGICAL tree, not the visual one: nothing has been rendered,
        # so the visual tree is unpopulated and VisualTreeHelper::GetParent
        # would return null on the first hop, making this assertion pass
        # vacuously. XamlReader.Load does build the logical tree.
        $ancestors = @()
        $cur = [System.Windows.LogicalTreeHelper]::GetParent($hint)
        while ($null -ne $cur -and $ancestors.Count -lt 50) {
            $ancestors += $cur
            $cur = [System.Windows.LogicalTreeHelper]::GetParent($cur)
        }

        # Prove the walk actually traversed something, so a broken walk cannot
        # masquerade as a pass.
        $ancestors.Count | Should -BeGreaterThan 0 -Because 'the hint must be attached to the tree'
        ($ancestors | Where-Object { $_ -is [System.Windows.Window] }).Count |
            Should -BeGreaterThan 0 -Because 'the walk should reach the Window root'

        ($ancestors | Where-Object { [object]::ReferenceEquals($_, $panel) }).Count |
            Should -Be 0 -Because 'a hint inside ManualPanel disappears exactly when it is needed'
    }

    It 'collapsing ManualPanel still leaves the business hint visible' {
        $panel = $script:PwWindow.FindName('ManualPanel')
        $hint  = $script:PwWindow.FindName('BusinessHint')

        # Exactly what Prompt-Password.ps1 does under -RequireClientDob.
        $panel.Visibility = 'Collapsed'
        $hint.Visibility  = 'Visible'

        $hint.Visibility | Should -Be 'Visible'
        $hint.Text       | Should -Not -BeNullOrEmpty
        $hint.Text       | Should -Match 'DDMMYYYY'
    }
}
