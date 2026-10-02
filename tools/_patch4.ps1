$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# Locate the two `return @(` matrix literals in the self test and replace them with
# ArrayList-of-rows returns, because PowerShell flattens array-of-arrays on return.
function Find-ReturnAt([System.Collections.Generic.List[string]] $Lines) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq 'return @(') { return $i }
    }
    return -1
}

$replacements = 0
while ($true) {
    $i = Find-ReturnAt $l
    if ($i -lt 0) { break }

    # find the matching ')' at the same indent
    $j = $i + 1
    while ($j -lt $l.Count -and $l[$j].Trim() -ne ')') { $j++ }
    if ($j -ge $l.Count) { throw 'unterminated return @( at ' + ($i + 1) }

    $rows = @()
    for ($k = $i + 1; $k -lt $j; $k++) {
        $body = $l[$k].Trim()
        $body = $body.TrimEnd(',')
        if ($body.StartsWith('@(') -and $body.EndsWith(')')) {
            $rows += $body
        }
    }
    if ($rows.Count -ne 3) { throw ('expected 3 rows at line ' + ($i + 1) + ', got ' + $rows.Count) }

    $new = @()
    $new += '#[['
    $new += '	Returned as an ArrayList of rows rather than a nested array.'
    $new += ''
    $new += '	PowerShell flattens an array-of-arrays on return, so a `return @(@(..),@(..))`'
    $new += '	comes back as nine loose doubles and every later index is silently wrong -'
    $new += '	the same class of bug as a bad interleave stride: it fails as nonsense'
    $new += '	numbers rather than as an error. An ArrayList of rows is not flattened, and'
    $new += '	indexing a row is unambiguous.'
    $new += ']]'
    $new += '$rows = New-Object System.Collections.ArrayList'
    for ($r = 0; $r -lt 3; $r++) {
        $new += ('[void] $rows.Add(' + $rows[$r] + ')')
    }
    $new += 'return $rows'

    $l.RemoveRange($i, $j - $i + 1)
    for ($k = $new.Count - 1; $k -ge 0; $k--) { [void] $l.Insert($i, $new[$k]) }
    $replacements++
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("patched $replacements matrix return(s); total=" + ([System.IO.File]::ReadAllLines($f)).Count)
