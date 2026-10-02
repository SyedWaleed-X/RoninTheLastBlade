$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# Same subscript trap, first element this time: `$cz * $cy, (...)` still parses
# `$cz * $cy` against a following index, so every element gets parentheses.
$pairs = @(
    @('[void] $rows.Add(@($cz * $cy, ($cz * $sy * $sx - $sz * $cx), ($cz * $sy * $cx + $sz * $sx)))',
      '[void] $rows.Add(@(($cz * $cy), ($cz * $sy * $sx - $sz * $cx), ($cz * $sy * $cx + $sz * $sx)))'),
    @('[void] $rows.Add(@($sz * $cy, ($sz * $sy * $sx + $cz * $cx), ($sz * $sy * $cx - $cz * $sx)))',
      '[void] $rows.Add(@(($sz * $cy), ($sz * $sy * $sx + $cz * $cx), ($sz * $sy * $cx - $cz * $sx)))'),
    @('[void] $rows.Add(@(-$sy, ($cy * $sx), ($cy * $cx)))',
      '[void] $rows.Add(@((-$sy), ($cy * $sx), ($cy * $cx)))'),
    @('[void] $rows.Add(@($t * $x * $x + $c, ($t * $x * $y - $s * $z), ($t * $x * $z + $s * $y)))',
      '[void] $rows.Add(@(($t * $x * $x + $c), ($t * $x * $y - $s * $z), ($t * $x * $z + $s * $y)))')
)

$done = 0
for ($i = 0; $i -lt $l.Count; $i++) {
    $t = $l[$i].Trim()
    foreach ($p in $pairs) {
        if ($t -eq $p[0]) { $l[$i] = "`t" + $p[1]; $done++; break }
    }
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("parenthesised $done more row(s)")
