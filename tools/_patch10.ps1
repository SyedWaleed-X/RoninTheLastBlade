$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# 1-idx 793 lost its `$rows = ...` initialisation when the stray block was removed.
if ($l[792].Trim().StartsWith('[void] $rows.Add')) {
    [void] $l.Insert(792, "`t`$rows = New-Object System.Collections.ArrayList")
}

# Drop the older, now-redundant comment block (0-idx 811..819 after the insert shift).
$start = -1
for ($i = 0; $i -lt $l.Count; $i++) {
    if ($l[$i].Trim() -eq 'Returned as an ArrayList of rows rather than a nested array.') { $start = $i; break }
}
if ($start -ge 0) {
    $end = $start
    while ($l[$end].Trim() -ne '#>') { $end++ }
    $l.RemoveRange($start - 1, ($end - $start) + 2)
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('patched; total=' + ([System.IO.File]::ReadAllLines($f)).Count)
