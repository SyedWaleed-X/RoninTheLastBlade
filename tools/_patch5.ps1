$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

for ($i = 0; $i -lt $l.Count; $i++) {
    if ($l[$i].Trim() -eq 'return @(@(1.0, 0, 0), @(0, 1.0, 0), @(0, 0, 1.0))') {
        $l[$i] = @(
            '		$identity = New-Object System.Collections.ArrayList',
            '		[void] $identity.Add(@(1.0, 0, 0))',
            '		[void] $identity.Add(@(0, 1.0, 0))',
            '		[void] $identity.Add(@(0, 0, 1.0))',
            '		return $identity'
        )[0]
        # insert the remaining lines after it
        $extra = @(
            '		[void] $identity.Add(@(1.0, 0, 0))',
            '		[void] $identity.Add(@(0, 1.0, 0))',
            '		[void] $identity.Add(@(0, 0, 1.0))',
            '		return $identity'
        )
        for ($k = $extra.Count - 1; $k -ge 0; $k--) { [void] $l.Insert($i + 1, $extra[$k]) }
        Write-Host ('patched identity return at line ' + ($i + 1))
        break
    }
}

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
