	$form = New-Object System.Net.Http.MultipartFormDataContent
	$requestPart = New-Object System.Net.Http.StringContent($request)
	$requestPart.Headers.ContentType =
		New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')
	[void] $form.Add($requestPart, 'request')

	$bytes = [System.IO.File]::ReadAllBytes($FilePath)
	$fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$bytes)
	$fileContent.Headers.ContentType =
		New-Object System.Net.Http.Headers.MediaTypeHeaderValue('model/x-rbxm')
	[void] $form.Add($fileContent, 'fileContent')

	# Diagnostic: print the exact multipart envelope that will go on the wire.
	Write-Host ('    multipart boundary : ' + $form.Headers.ContentType.Parameters[0]) -ForegroundColor DarkGray
	Write-Host ('    part 1 name= request  bytes=' + $request.Length) -ForegroundColor DarkGray
	Write-Host ('    part 2 name= fileContent  bytes=' + $bytes.Length) -ForegroundColor DarkGray
