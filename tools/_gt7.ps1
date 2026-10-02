# The angle is the 4th float, and it is a QUATERNION half-angle in the format the
# writer emits. Verify by comparing against the writer's own decomposition.
$src = [System.IO.File]::ReadAllText('C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1')
$s = $src.IndexOf('function Get-EulerToAxisAngle')
$e = $src.IndexOf('function Write-CFrameBlock')
Invoke-Expression ([regex]::Replace($src.Substring($s, $e - $s), '(?s)<#.*?#>', ''))

foreach ($deg in @(30.0, 90.0, 45.0, -34.0, 56.0)) {
    $d = Get-EulerToAxisAngle 0.0 0.0 ([Math]::PI * $deg / 180)
    if ($null -eq $d) { Write-Host ("  " + $deg + " deg -> identity"); continue }
    Write-Host ("  Z=" + $deg + " deg -> axis=(" + [Math]::Round($d.AxisX,4) + ',' +
        [Math]::Round($d.AxisY,4) + ',' + [Math]::Round($d.AxisZ,4) + ') angleRad=' +
        [Math]::Round($d.Angle,6) + ' = ' + [Math]::Round($d.Angle*180/[Math]::PI,4) + ' deg')
}
