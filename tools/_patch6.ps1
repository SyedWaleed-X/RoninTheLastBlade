$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# PowerShell parses `EXPR, NEXT` inside @() as a multi-dimensional SUBSCRIPT
# ( $expr[$next] ), not as two array elements. So any element that is an
# arithmetic expression and is followed by a comma must be parenthesised.
# Wrap each element of the three-element matrix rows.
$patterns = @(
    @('[void] $rows.Add(@($t * $x * $x + $c,       $t * $x * $y - $s * $z,  $t * $x * $z + $s * $y))',
      '[void] $rows.Add(@(($t * $x * $x + $c), ($t * $x * $y - $s * $z), ($t * $x * $z + $s * $y)))'),
    @('[void] $rows.Add(@($t * $x * $y + $s * $z,  $t * $y * $y + $c,       $t * $y * $z - $s * $x))',
      '[void] $rows.Add(@(($t * $x * $y + $s * $z), ($t * $y * $y + $c), ($t * $y * $z - $s * $x)))'),
    @('[void] $rows.Add(@($t * $x * $z - $s * $y,  $t * $y * $z + $s * $x,  $t * $z * $z + $c))',
      '[void] $rows.Add(@(($t * $x * $z - $s * $y), ($t * $y * $z + $s * $x), ($t * $z * $z + $c)))'),
    @('[void] $rows.Add(@($cz * $cy,                       $cz * $sy * $sx - $sz * $cx,  $cz * $sy * $cx + $sz * $sx))',
      '[void] $rows.Add(@($cz * $cy, ($cz * $sy * $sx - $sz * $cx), ($cz * $sy * $cx + $sz * $sx)))'),
    @('[void] $rows.Add(@($sz * $cy,                       $sz * $sy * $sx + $cz * $cx,  $sz * $sy * $cx - $cz * $sx))',
      '[void] $rows.Add(@($sz * $cy, ($sz * $sy * $sx + $cz * $cx), ($sz * $sy * $cx - $cz * $sx)))'),
    @('[void] $rows.Add(@(-$sy,                            $cy * $sx,                    $cy * $cx))',
      '[void] $rows.Add(@(-$sy, ($cy * $sx), ($cy * $cx)))')
)

$done = 0
for ($i = 0; $i -lt $l.Count; $i++) {
    $trimmed = $l[$i].Trim()
    foreach ($p in $patterns) {
        if ($trimmed -eq $p[0]) { $l[$i] = "`t" + $p[1]; $done++; break }
    }
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("parenthesised $done matrix row(s)")
