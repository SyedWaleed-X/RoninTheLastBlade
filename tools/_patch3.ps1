$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# The self-test block was inserted inside Invoke-UploadAsset, splitting it.
# Lift it out (0-idx 755..934 inclusive = 1-idx 756..935) and re-insert it
# immediately before that function, which starts at 1-idx 729.
$start = 755
$count = 935 - 756 + 1
if ($l[$start].Trim() -ne '# ---------------------------------------------------------------------------') { throw "unexpected start: " + $l[$start] }
if ($l[934].Trim() -ne '}') { throw "unexpected end: " + $l[934] }
if ($l[935].Trim() -ne 'try {') { throw "unexpected resume: " + $l[935] }

$block = $l.GetRange($start, $count)
$l.RemoveRange($start, $count)

$anchor = 728   # 0-idx of "function Invoke-UploadAsset(...)"
if ($l[$anchor] -notmatch '^function Invoke-UploadAsset') { throw "anchor moved: " + $l[$anchor] }

$l.InsertRange($anchor, $block)
[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('moved ' + $count + ' lines; total=' + ([System.IO.File]::ReadAllLines($f)).Count)
