$src = [System.IO.File]::ReadAllText('C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1')
function Grab([string]$fn, [string]$next) {
    $s = $src.IndexOf("function $fn")
    $e = $src.IndexOf($next, $s)
    [regex]::Replace($src.Substring($s, $e - $s), '(?s)<#.*?#>', '')
}
$RotationFormatIdentity = 0
$RotationFormatAxisAngle = 2
Invoke-Expression (Grab 'Write-RobloxFloat32' 'function Get-ZigZag32')
Invoke-Expression (Grab 'Write-Interleaved' 'function Get-EulerToAxisAngle')
Invoke-Expression (Grab 'Get-EulerToAxisAngle' 'function Write-CFrameBlock')
Invoke-Expression (Grab 'Write-CFrameBlock' 'function New-RbxDocument')

$cases = @(
    @{ Rx = 0.0;  Ry = 0.0;  Rz = 0.0 },
    @{ Rx = 30.0; Ry = 0.0;  Rz = 0.0 },
    @{ Rx = 0.0;  Ry = 90.0; Rz = 0.0 },
    @{ Rx = 12.0; Ry = -34.0; Rz = 56.0 }
)
$buf = New-Object System.Collections.Generic.List[byte]
Write-CFrameBlock $cases $buf
$arr = $buf.ToArray()
Write-Host ('block length: ' + $arr.Length + ' (expected ' + (4 + 16 * 3 + 12 * 4) + ')')

function D([byte[]] $bb, [int] $o) {
    $r = [uint32] (([uint32] $bb[$o]) -bor (([uint32] $bb[$o+1]) -shl 8) -bor
        (([uint32] $bb[$o+2]) -shl 16) -bor (([uint32] $bb[$o+3]) -shl 24))
    $sg = $r % 2
    $rest = ($r - $sg) / 2
    $bt = [uint32] ($rest + ([uint32] 2147483648 * $sg))
    return [BitConverter]::ToSingle([BitConverter]::GetBytes($bt), 0)
}

$base = 4
$n = 3
$hex = { param($b) (($b | ForEach-Object { $_.ToString('X2') }) -join ' ') }

$axisBytes = @()
for ($j = 0; $j -lt 4; $j++) { $axisBytes += $arr[($base + (0 + $j) * $n) + 0] }
$angleBytes = @()
for ($j = 0; $j -lt 4; $j++) { $angleBytes += $arr[($base + (12 + $j) * $n) + 0] }

Write-Host ('  axis.x bytes   = ' + (& $hex $axisBytes) + '   want 00 00 00 7F')
Write-Host ('  angle   bytes  = ' + (& $hex $angleBytes) + '   want 15 0C 7E 00... (rotated 0.5235988)')

# What does the writer's own record contain? Build record 0 by hand.
$single = [single] 0.5235988
$bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($single), 0)
$rot = (($bits -shl 1) -bor ($bits -shr 31)) -band 0xFFFFFFFF
Write-Host ('  rotated 0.5235988 = ' + (& $hex ([BitConverter]::GetBytes([uint32] $rot))))
