# Regression checks for the scroll transaction, independent of the user's Commander window.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'commander.ps1')

$position = [pscustomobject]@{
    HorizontalScrollPercent = 78.625; VerticalScrollPercent = 43.5
    HorizontalViewSize = 25.0; VerticalViewSize = 40.0; HorizontallyScrollable = $true
}
$scrollbar = [pscustomobject]@{ Current = $position }
$scrollbar | Add-Member ScriptMethod SetScrollPercent {
    param([double]$horizontal, [double]$vertical)
    $this.Current.HorizontalScrollPercent = $horizontal
    $this.Current.VerticalScrollPercent = $vertical
}
$body = [pscustomobject]@{ Current = @{ BoundingRectangle = [pscustomobject]@{ Width = 400; Height = 200 } }; scroll = $scrollbar }
$body | Add-Member ScriptMethod GetCurrentPattern { param($pattern) return $this.scroll }
$partsForTest = @{ body = $body }
function Get-GridParts($panelElement) { return $partsForTest }
function Get-Tabs($panelElement) { return @{ selected = $true; id = 'campaigns' } }
function Get-CellText($cell) { return $cell }

$originForTest = Get-ScrollPosition $scrollbar
$fault = ''
function Get-GridFrame($parts) {
    $h = $position.HorizontalScrollPercent
    if ($h -gt 35 -and $h -lt 70) {
        if ($fault -eq 'read') { throw 'Simulated provider failure.' }
        if ($fault -eq 'user') { $position.HorizontalScrollPercent = 92.0 }
    }
    $columns = @{ 0 = 'Index' }
    $cells = @{}
    foreach ($top in @(10.0,30.0)) {
        $cells[$top] = @{ 0 = "row-$top" }
        if ($h -lt 36) { $columns[1] = 'Название'; $cells[$top][1] = "name-$top" }
        if ($h -ge 36) { $columns[2] = 'Статус'; $cells[$top][2] = "status-$top" }
    }
    return @{ viewport = $body.Current.BoundingRectangle; columns = $columns; cells = $cells; tops = @(10.0,30.0) }
}
function Assert-TestPosition([double]$h,[double]$v) {
    if ($position.HorizontalScrollPercent -ne $h -or $position.VerticalScrollPercent -ne $v) {
        throw 'Unexpected final scroll position.'
    }
}
$q = @{ panel = 'sub'; expected_tab = 'campaigns'; columns = @('Статус','Название'); offset = 1; limit = 1 }
$read = Read-NamedColumns $null $q
if ($read.rows.Count -ne 1 -or $read.rows[0].viewport_index -ne 1 -or
    ($read.rows[0].values -join ',') -cne 'status-30,name-30') { throw 'Wrong row, order or values.' }
Assert-TestPosition $originForTest.horizontal $originForTest.vertical

foreach ($case in @('missing','read','user')) {
    $fault = $case
    $q.columns = if ($case -eq 'missing') { @('Unknown') } else { @('Статус','Название') }
    $expectedError = @{ missing = 'not shown'; read = 'Simulated provider failure'; user = 'new user position' }[$case]
    try { $null = Read-NamedColumns $null $q; throw 'Expected an error.' }
    catch { if ($_.Exception.Message -notmatch $expectedError) { throw } }
    $h = if ($case -eq 'user') { 92.0 } else { $originForTest.horizontal }
    Assert-TestPosition $h $originForTest.vertical
}
'Scroll regression checks passed: paginated join, nonzero restore, missing column, provider error and user movement.'
