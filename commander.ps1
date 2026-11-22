$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$exe = Join-Path $env:LOCALAPPDATA 'Programs\Direct Commander\Direct Commander.exe'

function Get-CommanderWindows {
    foreach ($process in (Get-Process -Name 'Direct Commander' -ErrorAction SilentlyContinue)) {
        if ($process.MainWindowHandle -ne 0 -and $process.Path -eq $exe) {
            $handle = $process.MainWindowHandle.ToInt64()
            [pscustomobject]@{
                id = "$($process.Id)-$($process.StartTime.ToUniversalTime().Ticks)-$handle"
                title = $process.MainWindowTitle
                handle = $handle
            }
        }
    }
}

function Find-ByType($parent, $type) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
    $parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-Panels($root) {
    foreach ($group in (Find-ByType $root ([System.Windows.Automation.ControlType]::Group))) {
        if ($group.Current.ClassName -cmatch '(?:^| )main-layout__(main|sub)-panel(?: |$)') {
            [pscustomobject]@{ id = $Matches[1]; element = $group }
        }
    }
}

function Get-Tabs($panelElement) {
    foreach ($radio in (Find-ByType $panelElement ([System.Windows.Automation.ControlType]::RadioButton))) {
        if ($radio.Current.ClassName -cne 'dc-MultiButton__input') { continue }
        $parent = $walker.GetParent($radio)
        if (!$parent) { continue }
        $group = $walker.GetParent($parent)
        if (!$group) { continue }
        $strip = $walker.GetParent($group)
        if (!$strip -or $strip.Current.ClassName -cne 'view-panel__tabs') { continue }
        $label = $radio.Current.Name
        if ($label -cnotmatch '^([A-Za-z][A-Za-z0-9_]{0,63})\s+\1(?:\s+|$)') { continue }
        [pscustomobject]@{
            id = $Matches[1]; label = $label.Substring($Matches[0].Length)
            selected = [bool]$radio.GetCurrentPropertyValue([System.Windows.Automation.SelectionItemPattern]::IsSelectedProperty)
            enabled = $radio.Current.IsEnabled; element = $radio
        }
    }
}

function Get-SelectedTab($tabs) {
    $selected = @($tabs | Where-Object selected)
    if ($selected.Count -eq 1) { return $selected[0].id }
    return $null
}

function Get-QuickFilter($panelElement) {
    $found = @(foreach ($edit in (Find-ByType $panelElement ([System.Windows.Automation.ControlType]::Edit))) {
        if ($edit.Current.IsPassword) { continue }
        $parent = $walker.GetParent($edit)
        if ($parent -and $parent.Current.ClassName -cmatch '(?:^| )[\w-]+-view__filter(?: |$)') {
            [pscustomobject]@{ element = $edit; value = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) }
        }
    })
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Submit-QuickFilter($root, $panelElement, $field, $text) {
    # The search bar applies its current value on Enter. Target this HWND only.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CommanderSearchKey {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr key, IntPtr detail,
        uint flags, uint timeout, out UIntPtr result);
    public static void Enter(IntPtr hwnd) {
        UIntPtr result;
        if (SendMessageTimeout(hwnd, 0x100, (UIntPtr)13, (IntPtr)0x001C0001, 2, 1000, out result) == IntPtr.Zero ||
            SendMessageTimeout(hwnd, 0x101, (UIntPtr)13, new IntPtr(unchecked((int)0xC01C0001)), 2, 1000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("The Commander window did not acknowledge the search key.");
    }
}
'@
    $window = [IntPtr]$root.Current.NativeWindowHandle
    $prior = [CommanderSearchKey]::GetForegroundWindow()
    try {
        if ($prior -ne $window) { $null = [CommanderSearchKey]::SetForegroundWindow($window) }
        $field.element.SetFocus()
        for ($i = 0; $i -lt 8 -and !$field.element.Current.HasKeyboardFocus; $i++) { Start-Sleep -Milliseconds 50 }
        if (!$field.element.Current.HasKeyboardFocus -or !$root.Current.IsEnabled -or
            [CommanderSearchKey]::GetForegroundWindow() -ne $window) {
            throw 'The search field could not receive focus. Bring Commander to the foreground and inspect the panel.'
        }
        if ($text -ceq '') {
            $container = $walker.GetParent($field.element)
            $clear = @(Find-ByType $container ([System.Windows.Automation.ControlType]::Button) |
                Where-Object { $_.Current.ClassName -cmatch '(?:^| )dc-TextInput__clear-button(?: |$)' })
            if ($clear.Count -eq 1 -and $clear[0].Current.IsEnabled) {
                $clear[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                return
            }
        }
        $field.value.SetValue($text)
        $updated = Get-QuickFilter $panelElement
        if (!$updated -or $updated.value.Current.Value -cne $text) { throw 'The search box did not retain the requested value.' }
        if (!$updated.element.Current.HasKeyboardFocus) { $updated.element.SetFocus() }
        if (!$root.Current.IsEnabled -or !$updated.element.Current.HasKeyboardFocus -or
            [CommanderSearchKey]::GetForegroundWindow() -ne $window) { throw 'The search field lost keyboard focus.' }
        [CommanderSearchKey]::Enter($window)
        Start-Sleep -Milliseconds 150
    } finally {
        if ($prior -ne [IntPtr]::Zero -and $prior -ne $window -and [CommanderSearchKey]::GetForegroundWindow() -eq $window) {
            $null = [CommanderSearchKey]::SetForegroundWindow($prior)
        }
    }
}

function Get-CellText($cell) {
    $values = @(foreach ($part in (Find-ByType $cell ([System.Windows.Automation.ControlType]::Text))) {
        if ($part.Current.Name) { $part.Current.Name }
    })
    $text = ($values -join ' ').Trim()
    if (!$text) { $text = $cell.Current.Name }
    if ($text.Length -gt 1024) { return ($text.Substring(0,1023) + [char]0x2026) }
    if ($text) { return $text }
    return $null
}

function Get-GridParts($panelElement) {
    $grids = @(Find-ByType $panelElement ([System.Windows.Automation.ControlType]::DataGrid))
    $header = @($grids | Where-Object { $_.Current.ClassName -cmatch '(?:^| )r-grid__grid-content_type_header(?: |$)' })
    $body = @($grids | Where-Object { $_.Current.ClassName -cmatch '(?:^| )r-grid__grid-content_type_body(?: |$)' })
    if ($header.Count -ne 1 -or $body.Count -ne 1) {
        throw 'This panel has no unambiguous Commander grid. Check the active tab, window size and any open dialog.'
    }
    return @{ header = $header[0]; body = $body[0] }
}

function Get-GridFrame($parts) {
    $children = [System.Windows.Automation.TreeScope]::Children
    $any = [System.Windows.Automation.Condition]::TrueCondition
    $viewport = $parts.body.Current.BoundingRectangle
    $columns = @{}
    foreach ($cell in $parts.header.FindAll($children,$any)) {
        if ($cell.Current.ClassName -cnotmatch '(?:^| )r-grid-header-cell_index_(\d+)(?: |$)') { continue }
        $index = [int]$Matches[1]
        $rect = $cell.Current.BoundingRectangle
        if ($rect.Right -gt $viewport.Left -and $rect.Left -lt $viewport.Right) {
            $columns[$index] = Get-CellText $cell
        }
    }
    $byTop = @{}
    foreach ($cell in $parts.body.FindAll($children,$any)) {
        if ($cell.Current.ClassName -cnotmatch '(?:^| )r-grid__cell_index_(\d+)(?: |$)') { continue }
        $index = [int]$Matches[1]
        $rect = $cell.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0 -or
            $rect.Bottom -le $viewport.Top -or $rect.Top -ge $viewport.Bottom -or
            $rect.Right -le $viewport.Left -or $rect.Left -ge $viewport.Right) { continue }
        if (!$columns.ContainsKey($index)) { $columns[$index] = $null }
        $top = [double]$rect.Top
        if (!$byTop.ContainsKey($top)) { $byTop[$top] = @{} }
        if ($byTop[$top].ContainsKey($index)) { throw 'The viewport changed or contains overlapping cells. Read the table again.' }
        $byTop[$top][$index] = $cell
    }
    return @{ columns = $columns; cells = $byTop; tops = @($byTop.Keys | Sort-Object); viewport = $viewport }
}

function Get-ScrollPosition($scroll) {
    $s = $scroll.Current
    return @{ horizontal = $s.HorizontalScrollPercent; vertical = $s.VerticalScrollPercent }
}

function Get-Grid($panelElement, $q) {
    $parts = Get-GridParts $panelElement
    $frame = Get-GridFrame $parts
    $columns = $frame.columns
    $byTop = $frame.cells
    $indices = @($columns.Keys | Sort-Object)
    if ($null -ne $q.columns) {
        $indices = @($q.columns | ForEach-Object { [int]$_ } | Select-Object -Unique)
        foreach ($index in $indices) {
            if (!$columns.ContainsKey($index)) { throw "Column $index is outside the current viewport." }
        }
    }
    $tops = $frame.tops
    $end = [Math]::Min([int]($q.offset + $q.limit),$tops.Count)
    $rows = @(for ($i = [int]$q.offset; $i -lt $end; $i++) {
        $cells = $byTop[$tops[$i]]
        $values = @(foreach ($index in $indices) {
            if ($cells.ContainsKey($index)) { Get-CellText $cells[$index] } else { $null }
        })
        [pscustomobject]@{ viewport_index = $i; values = $values }
    })
    $next = if ($q.limit -gt 0 -and $end -lt $tops.Count) { $end }
    $scroll = $null
    $position = if ($parts.body.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$scroll)) {
        Get-ScrollPosition $scroll
    }
    return @{
        scroll_position = $position
        panel = $q.panel; tab = $q.expected_tab; visible_row_count = $tops.Count
        columns = @($indices | ForEach-Object { @{ id = $_; label = $columns[$_] } })
        rows = $rows; next_offset = $next
    }
}

function Assert-ScanPosition($scan) {
    $now = Get-ScrollPosition $scan.scroll
    if ($scan.interrupted -or $now.horizontal -ne $scan.last.horizontal -or $now.vertical -ne $scan.last.vertical -or
        $scan.scroll.Current.HorizontalViewSize -ne $scan.width -or $scan.scroll.Current.VerticalViewSize -ne $scan.height) {
        throw 'The table was scrolled during the read. The new user position was preserved.'
    }
}

function Set-ScanHorizontal($scan, [double]$target, [switch]$Restore) {
    Assert-ScanPosition $scan
    if ($scan.last.horizontal -eq $target -and $scan.last.vertical -eq $scan.origin.vertical) { return }
    # Chromium may round a requested percentage to the adjacent CSS pixel.
    $h = $target
    $v = $scan.origin.vertical
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $prior = $scan.last
        try {
            $scan.scroll.SetScrollPercent($h, $v)
        } finally {
            # The renderer applies an acknowledged UIA request asynchronously.
            for ($poll = 0; $poll -lt 12; $poll++) {
                Start-Sleep -Milliseconds 45
                $scan.last = Get-ScrollPosition $scan.scroll
                if ([Math]::Abs($scan.last.horizontal - $target) -le $scan.pixelH -and
                    [Math]::Abs($scan.last.vertical - $scan.origin.vertical) -le $scan.pixelV) { break }
            }
        }
        $dh = $target - $scan.last.horizontal
        $dv = $scan.origin.vertical - $scan.last.vertical
        if ([Math]::Abs($dv) -gt $scan.pixelV -or [Math]::Abs($dh) -gt $scan.pixelH) {
            if ($prior.horizontal -ne $scan.last.horizontal -or $prior.vertical -ne $scan.last.vertical) {
                $scan.interrupted = $true
            }
            throw 'Commander did not reach the requested scroll position.'
        }
        if ($dv -eq 0 -and (!$Restore -or $dh -eq 0)) { return }
        if ($h -ge 0) { $h = [Math]::Clamp($h + 0.75 * $dh, 0.0, 100.0) }
        if ($v -ge 0) { $v = [Math]::Clamp($v + 0.75 * $dv, 0.0, 100.0) }
        Assert-ScanPosition $scan
    }
    throw 'Could not reproduce the exact scrollbar position.'
}

function Assert-FrameOverlap($left, $right) {
    if ($left.viewport -ne $right.viewport -or $left.tops.Count -ne $right.tops.Count) {
        throw 'The grid layout or visible rows changed during the read.'
    }
    foreach ($y in $left.tops) {
        if (!$right.cells.ContainsKey($y)) { throw 'Visible rows moved during the read.' }
        $shared = $false
        foreach ($id in $left.cells[$y].Keys) {
            if ($right.cells[$y].ContainsKey($id) -and $left.cells[$y][$id].Equals($right.cells[$y][$id])) {
                $shared = $true
                break
            }
        }
        if (!$shared) { throw 'Could not match the same row across adjacent horizontal views.' }
    }
}

function Get-SettledFrame($parts) {
    # React Virtualized replaces its scrolling placeholders after the thumb has stopped.
    Start-Sleep -Milliseconds 180
    $last = Get-GridFrame $parts
    for ($poll = 0; $poll -lt 3; $poll++) {
        Start-Sleep -Milliseconds 70
        $frame = Get-GridFrame $parts
        if ($frame.viewport -eq $last.viewport -and ($frame.tops -join ',') -eq ($last.tops -join ',') -and
            $frame.columns.Count -eq $last.columns.Count) {
            $changed = @($frame.columns.Keys | Where-Object {
                !$last.columns.ContainsKey($_) -or $frame.columns[$_] -cne $last.columns[$_]
            })
            if (!$changed.Count) { return $frame }
        }
        $last = $frame
    }
    throw 'The Commander grid is still changing. Inspect the current panel and retry.'
}

function Read-NamedColumns($panelElement, $q) {
    $parts = Get-GridParts $panelElement
    $scroll = $parts.body.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $origin = Get-ScrollPosition $scroll
    $rect = $parts.body.Current.BoundingRectangle
    $hs = $scroll.Current.HorizontalViewSize
    $vs = $scroll.Current.VerticalViewSize
    $spanH = $rect.Width * (100 / [Math]::Max(0.001,$hs) - 1)
    $spanV = $rect.Height * (100 / [Math]::Max(0.001,$vs) - 1)
    $scan = @{ scroll = $scroll; last = $origin; origin = $origin; width = $hs; height = $vs; interrupted = $false
        pixelH = 200 / [Math]::Max(1,$spanH); pixelV = 200 / [Math]::Max(1,$spanV) }
    $wanted = @($q.columns | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    if (@($wanted | Select-Object -Unique -CaseInsensitive).Count -ne $wanted.Count) { throw 'Duplicate column names.' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $found = @{}
    $values = @{}
    $previous = $null
    $initial = Get-SettledFrame $parts
    $frame = $initial
    $visibleLabels = @($initial.columns.Values | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    $needsScan = @($wanted | Where-Object { $_ -notin $visibleLabels }).Count -gt 0
    $step = 55 * $hs / [Math]::Max(0.001,100 - $hs)
    try {
        if ($needsScan -and $origin.horizontal -gt 0) {
            Set-ScanHorizontal $scan 0
            $frame = Get-SettledFrame $parts
        }
        while ($true) {
            Assert-ScanPosition $scan
            if ($clock.Elapsed.TotalSeconds -gt 18) { throw 'The horizontal read took too long. Request fewer columns.' }
            if ($previous) { Assert-FrameOverlap $previous $frame }
            $end = [Math]::Min([int]($q.offset + $q.limit),$frame.tops.Count)
            foreach ($id in $frame.columns.Keys) {
                $label = ($frame.columns[$id] -replace '\s+', ' ').Trim()
                if ($label -notin $wanted) { continue }
                if ($found.ContainsKey($label) -and $found[$label] -ne $id) { throw "Ambiguous column: $label." }
                $found[$label] = $id
                $columnValues = @(for ($i = [int]$q.offset; $i -lt $end; $i++) {
                    $cells = $frame.cells[$frame.tops[$i]]
                    if (!$cells.ContainsKey($id)) { throw "Column '$label' is missing a rendered cell." }
                    Get-CellText $cells[$id]
                })
                if ($values.ContainsKey($label)) {
                    for ($i = 0; $i -lt $columnValues.Count; $i++) {
                        if ($values[$label][$i] -cne $columnValues[$i]) { throw 'The grid data changed during the read.' }
                    }
                }
                $values[$label] = $columnValues
            }
            if ($found.Count -eq $wanted.Count) { break }
            if (!$scroll.Current.HorizontallyScrollable -or $scan.last.horizontal -ge 100) {
                $missing = @($wanted | Where-Object { !$found.ContainsKey($_) })
                throw "Column(s) not shown in this table: $($missing -join ', ')."
            }
            $nextH = [Math]::Min(100,$scan.last.horizontal + $step)
            $previous = $frame
            Set-ScanHorizontal $scan $nextH
            $frame = Get-SettledFrame $parts
        }
        Assert-ScanPosition $scan
    } finally {
        if ($origin.horizontal -ne $scan.last.horizontal -or $origin.vertical -ne $scan.last.vertical) {
            if ((Get-SelectedTab @(Get-Tabs $panelElement)) -cne $q.expected_tab) {
                throw 'The selected tab changed during the read. Check the original tab position.'
            }
            Set-ScanHorizontal $scan $origin.horizontal -Restore
        }
    }
    Assert-ScanPosition $scan
    $count = $frame.tops.Count
    $next = if ($q.limit -gt 0 -and $end -lt $count) { $end }
    return @{ panel = $q.panel; tab = $q.expected_tab; visible_row_count = $count; next_offset = $next
        columns = @($wanted | ForEach-Object { @{ id = $found[$_]; label = $_ } })
        rows = @(for ($i = [int]$q.offset; $i -lt $end; $i++) {
            @{ viewport_index = $i; values = @($wanted | ForEach-Object { $values[$_][$i - $q.offset] }) }
        })
        scroll_before = $origin; scroll_after = $scan.last
    }
}

function Invoke-Commander($q) {
    $windows = @(Get-CommanderWindows)
    if ($q.operation -eq 'status') {
        $installed = Test-Path -LiteralPath $exe -PathType Leaf
        $version = if ($installed) { (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
        return @{ installed = $installed; version = $version; windows = @($windows | Select-Object id,title) }
    }
    $match = @($windows | Where-Object { $_.id -ceq $q.window_id })
    if ($match.Count -ne 1) { throw 'The bound window is closed or has changed. Call commander_status again.' }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$match[0].handle)
    $panels = @(Find-Panels $root)
    if ($q.operation -eq 'panels') {
        $result = @(foreach ($p in $panels) {
            $tabs = @(Get-Tabs $p.element)
            $field = Get-QuickFilter $p.element
            [pscustomobject]@{
                panel = $p.id; selected_tab = Get-SelectedTab $tabs
                tabs = @($tabs | Select-Object id,label,enabled,selected)
                quick_filter = if ($field) { $field.value.Current.Value }
            }
        })
        return @{ window_id = $q.window_id; panels = $result }
    }
    $panel = @($panels | Where-Object { $_.id -ceq $q.panel })
    if ($panel.Count -ne 1) { throw 'The requested panel is unavailable. Call commander_list_panels.' }
    $element = $panel[0].element
    $tabs = @(Get-Tabs $element)
    $selected = Get-SelectedTab $tabs
    if (!$selected -or $selected -cne $q.expected_tab) { throw 'The selected tab changed. Call commander_list_panels.' }
    if ($q.operation -eq 'grid') {
        $data = Get-Grid $element $q
        if ((Get-SelectedTab @(Get-Tabs $element)) -cne $selected) { throw 'Tab changed during the read. Read again.' }
        return $data
    }
    if (!$root.Current.IsEnabled -or !$element.Current.IsEnabled) { throw 'The window is busy or blocked by a dialog.' }
    if ($q.operation -eq 'columns') {
        $data = Read-NamedColumns $element $q
        if ((Get-SelectedTab @(Get-Tabs $element)) -cne $selected) { throw 'Tab changed during the read. Read again.' }
        return $data
    }
    if ($q.operation -eq 'select') {
        $target = @($tabs | Where-Object { $_.id -ceq $q.target_tab -and $_.enabled })
        if ($target.Count -ne 1) { throw 'The object tab is missing, disabled or ambiguous. Call commander_list_panels.' }
        if ($selected -cne $q.target_tab) {
            $target[0].element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        }
        for ($i = 0; $i -lt 12; $i++) {
            if ((Get-SelectedTab @(Get-Tabs $element)) -ceq $q.target_tab) {
                return @{ panel = $q.panel; selected_tab = $q.target_tab; changed = ($selected -cne $q.target_tab) }
            }
            Start-Sleep -Milliseconds 100
        }
        throw 'The requested tab selection could not be verified. Inspect the panel before retrying.'
    }
    if ($q.operation -eq 'filter') {
        $field = Get-QuickFilter $element
        if (!$field -or $field.value.Current.IsReadOnly) { throw 'This panel has no editable quick filter.' }
        if ($field.value.Current.Value -cne $q.expected_text) { throw 'Quick filter changed. Inspect the panel before retrying.' }
        $changed = $q.text -cne $q.expected_text
        if ($changed) { Submit-QuickFilter $root $element $field $q.text }
        Start-Sleep -Milliseconds 300
        $current = Get-QuickFilter $element
        if (!$current -or $current.value.Current.Value -cne $q.text -or (Get-SelectedTab @(Get-Tabs $element)) -cne $selected) {
            throw 'The filter update could not be verified. Inspect the panel before retrying.'
        }
        return @{ panel = $q.panel; tab = $selected; quick_filter = $current.value.Current.Value; changed = $changed }
    }
    throw 'Unknown Commander operation.'
}

if ($MyInvocation.InvocationName -eq '.') { return }

$mutex = $null
$acquired = $false
try {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    # Independent Codex chats can share the same application window.
    $mutex = [Threading.Mutex]::new($false, 'Local\Codex.DirectCommander.UI')
    try { $acquired = $mutex.WaitOne(4000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { throw 'Commander is servicing another UI request. Inspect the panel and try again.' }
    $result = Invoke-Commander $request
} catch {
    $result = @{ error = $_.Exception.Message }
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
[Console]::WriteLine((ConvertTo-Json -Depth 8 -Compress -InputObject $result))
