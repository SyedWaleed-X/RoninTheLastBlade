$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# 0-idx 792..800 is a stray comment block that ended up inside Get-AxisAngleMatrix
# (lines 793-801 in 1-indexed terms). Delete it; Get-EulerMatrix gets a fresh note.
$l.RemoveRange(792, 9)

# Find Get-EulerMatrix's body and give it the transpose note.
$ge = -1
for ($i = 0; $i -lt $l.Count; $i++) {
    if ($l[$i] -match '^function Get-EulerMatrix') { $ge = $i; break }
}
if ($ge -lt 0) { throw 'Get-EulerMatrix not found' }
$rowsAt = -1
for ($i = $ge; $i -lt $l.Count; $i++) {
    if ($l[$i].Trim() -eq '$rows = New-Object System.Collections.ArrayList') { $rowsAt = $i; break }
}
if ($rowsAt -lt 0) { throw 'rows line not found' }

$note = @(
    '<#',
    '	Rz * Ry * Rx, transposed.',
    '',
    '	`Get-AxisAngleMatrix` returns the standard active-rotation matrix, whose',
    '	columns are the rotated basis vectors. Roblox composes rotations in the',
    '	opposite (row-vector) convention, so the same rotation is written here',
    '	transposed. Without the transpose the two agree on the identity and on every',
    '	axis-aligned case and disagree on everything else - which is exactly the kind',
    '	of bug that passes a smoke test and fails in the game.',
    '#>'
)
for ($k = $note.Count - 1; $k -ge 0; $k--) { [void] $l.Insert($rowsAt, $note[$k]) }

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('patched; total=' + ([System.IO.File]::ReadAllLines($f)).Count)
