$src = [System.IO.File]::ReadAllText('C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1')
function Grab([string]$fn, [string]$next) {
    $s = $src.IndexOf("function $fn")
    $e = $src.IndexOf($next, $s)
    [regex]::Replace($src.Substring($s, $e - $s), '(?s)<#.*?#>', '')
}
Invoke-Expression (Grab 'Get-AxisAngleMatrix' 'function Get-EulerMatrix')
Invoke-Expression (Grab 'Get-EulerMatrix' 'function Get-MatrixDelta')

# Identity reconstruction from a known axis+angle.
$m = Get-AxisAngleMatrix 1.0 0.0 0.0 0.5235988
Write-Host ("AAM(1,0,0,30deg):")
for ($r = 0; $r -lt 3; $r++) {
    Write-Host ('   row' + $r + ' = ' + $m[$r][0] + ', ' + $m[$r][1] + ', ' + $m[$r][2])
}
$e = Get-EulerMatrix 0.0 0.0 0.5235988
Write-Host ("Euler(0,0,30deg):")
for ($r = 0; $r -lt 3; $r++) {
    Write-Host ('   row' + $r + ' = ' + $e[$r][0] + ', ' + $e[$r][1] + ', ' + $e[$r][2])
}
Write-Host ('delta = ' + (Get-MatrixDelta $m $e))
