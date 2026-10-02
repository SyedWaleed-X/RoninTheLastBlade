$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# Get-EulerMatrix must be the TRANSPOSE of the standard active-rotation matrix that
# Get-AxisAngleMatrix returns, because Roblox composes rotations in the row-vector
# convention. The two agree on the identity and on every axis-aligned case, so an
# untransposed version passes a smoke test and fails in the game.
$l[830] = "`t[void] `$rows.Add(@((`$cz * `$cy), (`$sz * `$cy), (-`$sy)))"
$l[831] = "`t[void] `$rows.Add(@((`$cz * `$sy * `$sx - `$sz * `$cx), (`$sz * `$sy * `$sx + `$cz * `$cx), (`$cy * `$sx)))"
$l[832] = "`t[void] `$rows.Add(@((`$cz * `$sy * `$cx + `$sz * `$sx), (`$sz * `$sy * `$cx - `$cz * `$sx), (`$cy * `$cx)))"

# Replace the stale comment above it with the reason.
$start = -1
for ($i = 0; $i -lt $l.Count; $i++) {
    if ($l[$i].Trim() -eq 'Returned as an ArrayList of rows rather than a nested array.') { $start = $i; break }
}
if ($start -ge 0) {
    $end = $start
    while ($l[$end].Trim() -ne '#>') { $end++ }
    $note = @(
        'Rz * Ry * Rx, transposed.',
        '',
        '`Get-AxisAngleMatrix` returns the standard active-rotation matrix, whose',
        'columns are the rotated basis vectors. Roblox composes rotations in the',
        'opposite (row-vector) convention, so the same rotation is written here',
        'transposed. Without the transpose the two agree on the identity and on',
        'every axis-aligned case and disagree on everything else - which is exactly',
        'the kind of bug that passes a smoke test and fails in the game.'
    )
    $l.RemoveRange($start - 1, ($end - $start) + 2)
    for ($k = $note.Count - 1; $k -ge 0; $k--) { [void] $l.Insert($start - 1, "`t" + $note[$k]) }
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('patched; total=' + ([System.IO.File]::ReadAllLines($f)).Count)
