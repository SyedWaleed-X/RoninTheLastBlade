$f = 'C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1'
$l = New-Object System.Collections.Generic.List[string]
foreach ($x in [System.IO.File]::ReadAllLines($f)) { [void] $l.Add($x) }

# Replace 0-idx 974..1003 (the whole multipart assembly, now duplicated) with a
# single correct version.
$block = @(
    '	# Force an unquoted boundary. The default constructor produces a GUID boundary',
    '	# that renders QUOTED in the Content-Type header, and a quoted boundary makes',
    '	# the body unparseable server-side: the 400 that comes back claims the fileContent',
    '	# part is missing even though it is plainly in the body. The part names must also',
    '	# be passed unquoted, because MultipartFormDataContent.Add adds the quotes itself.',
    '	$form = New-Object System.Net.Http.MultipartFormDataContent',
    '	$form.Headers.ContentType =',
    '		New-Object System.Net.Http.Headers.MediaTypeHeaderValue(''multipart/form-data'')',
    '	$form.Headers.ContentType.Boundary = ''ronin-'' + [Guid]::NewGuid().ToString(''N'')',
    '',
    '	$requestPart = New-Object System.Net.Http.StringContent($request)',
    '	$requestPart.Headers.ContentType =',
    '		New-Object System.Net.Http.Headers.MediaTypeHeaderValue(''application/json'')',
    '	[void] $form.Add($requestPart, ''request'')',
    '',
    '	$bytes = [System.IO.File]::ReadAllBytes($FilePath)',
    '	$fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$bytes)',
    '	$fileContent.Headers.ContentType =',
    '		New-Object System.Net.Http.Headers.MediaTypeHeaderValue(''model/x-rbxm'')',
    '	[void] $form.Add($fileContent, ''fileContent'')'
)

$l.RemoveRange(974, 30)
for ($k = $block.Count - 1; $k -ge 0; $k--) { [void] $l.Insert(974, $block[$k]) }

[System.IO.File]::WriteAllLines($f, $l, (New-Object System.Text.UTF8Encoding $false))
Write-Host ('patched; total=' + ([System.IO.File]::ReadAllLines($f)).Count)
