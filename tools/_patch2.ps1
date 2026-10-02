$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

$idx = -1
for ($i = 0; $i -lt $l.Count; $i++) {
    if ($l[$i] -match '^(try \{)$') { $idx = $i; break }
}
if ($idx -lt 0) { throw 'could not find the main try block' }
Write-Host ('main try at line ' + ($idx + 1))

$block = [System.IO.File]::ReadAllLines('C:\RobloxProjects\RoninTheLastBlade\tools\_selftest.snippet')
for ($k = $block.Count - 1; $k -ge 0; $k--) { [void] $l.Insert($idx, $block[$k]) }

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('inserted; lines=' + ([System.IO.File]::ReadAllLines($f)).Count)
