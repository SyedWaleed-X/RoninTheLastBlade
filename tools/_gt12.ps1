$src = [System.IO.File]::ReadAllText('C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1')
$s = $src.IndexOf('function Get-EulerToAxisAngle')
$e = $src.IndexOf('function Write-CFrameBlock')
Invoke-Expression ([regex]::Replace($src.Substring($s, $e - $s), '(?s)<#.*?#>', ''))

foreach ($c in @(@{Rx=30.0;Ry=0.0;Rz=0.0}, @{Rx=0.0;Ry=90.0;Rz=0.0}, @{Rx=0.0;Ry=0.0;Rz=45.0})) {
    $d = Get-EulerToAxisAngle $c.Rx $c.Ry $c.Rz
    if ($null -eq $d) { Write-Host ('  (' + $c.Rx + ',' + $c.Ry + ',' + $c.Rz + ') -> identity'); continue }
    Write-Host ('  in (' + $c.Rx + ',' + $c.Ry + ',' + $c.Rz + ') -> AxisX=' + $d.AxisX +
        ' AxisY=' + $d.AxisY + ' AxisZ=' + $d.AxisZ + ' Angle=' + $d.Angle)
    $enc = New-Object System.Collections.Generic.List[byte]
    Write-RobloxFloat32 $d.AxisX $enc
    Write-RobloxFloat32 $d.AxisY $enc
    Write-RobloxFloat32 $d.AxisZ $enc
    Write-RobloxFloat32 $d.Angle $enc
    $b = $enc.ToArray()
    Write-Host ('     record bytes: ' + (($b | ForEach-Object { $_.ToString('X2') }) -join ' '))
}
