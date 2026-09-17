# Encoding: UTF-8 with BOM.
# Colour palette for the card. Pure data - plain RGB triples - so both themes can
# be checked offline without touching System.Drawing.
#
# Dark and light expose the exact same key set, and no control is allowed to keep
# a literal ARGB: a new theme must be able to repaint the whole window from here.

function ConvertTo-WidgetTheme {
    param([string]$Value, [string]$Default = 'dark')
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'light') { return 'light' }
    if ($text -eq 'dark') { return 'dark' }
    return $Default
}

# Get-WidgetPalette -> @{ <name> = @(R, G, B) }. Component triples keep the values
# readable and let the caller build either a Color or an ARGB integer.
function Get-WidgetPalette {
    param([string]$Theme)
    if ((ConvertTo-WidgetTheme $Theme) -eq 'light') {
        return @{
            Text       = @(26, 26, 32)
            Muted      = @(96, 96, 108)
            Dim        = @(138, 138, 148)
            Background = @(250, 250, 252)
            Field      = @(236, 236, 241)
            Track      = @(226, 226, 232)
            Button     = @(234, 234, 240)
            Danger     = @(214, 48, 49)
            ErrorText  = @(192, 40, 40)
            Link       = @(0, 102, 204)
            Success    = @(16, 140, 84)
            Warning    = @(176, 116, 0)
            Ok         = @(16, 152, 96)
        }
    }
    return @{
        Text       = @(244, 244, 247)
        Muted      = @(152, 152, 160)
        Dim        = @(108, 108, 116)
        Background = @(18, 18, 22)
        Field      = @(32, 32, 40)
        Track      = @(42, 42, 50)
        Button     = @(38, 38, 46)
        Danger     = @(255, 107, 107)
        ErrorText  = @(255, 138, 128)
        Link       = @(120, 190, 255)
        Success    = @(120, 220, 160)
        Warning    = @(255, 196, 64)
        Ok         = @(48, 227, 160)
    }
}