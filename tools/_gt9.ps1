# The 4th float (the angle) - is it at float index 3, i.e. bytes 12..15 of the slice?
# Print every float index for record 0 from the block the generator produced.
$src = [System.IO.File]::ReadAllText('C:\RobloxProjects\RoninTheLastBlade\tools\Publish-Animation.ps1')
$s = $src.IndexOf('function Write-CFrameBlock')
$e = $src.IndexOf('# ---------------------------------------------------------------------------', $s)
$code = [regex]::Replace($src.Substring($s, $e - $s), '(?s)<#.*?#>', '')
# also need the helpers
$hs = $src.IndexOf('function Write-RobloxFloat32')
$he = $src.IndexOf('function Get-ZigZag32')
Invoke-Expression ([regex]::Replace($src.Substring($hs, $he - $hs), '(?s)<#.*?#>', ''))
$is = $src.IndexOf('function Write-Interleaved')
$ie = $src.IndexOf('function Get-EulerToAxisAngle')
Invoke-Expression ([regex]::Replace($src.Substring($is, $ie - $is), '(?s)<#.*?#>', ''))
$gs = $src.IndexOf('function Get-EulerToAxisAngle')
$ge2 = $src.IndexOf('function Write-CFrameBlock')
Invoke-Expression ([regex]::Replace($src.Substring($gs, $ge2 - $gs), '(?s)<#.*?#>', ''))
# rotation format constants
$RotationFormatIdentity = 0
$RotationFormatAxisAngle = 2
Invoke-Expression $code

$cases = @(
    @{ Rx = 0.0;  Ry = 0.0;  Rz = 0.0 },
    @{ Rx = 30.0; Ry = 0.0;  Rz = 0.0 },
    @{ Rx = 0.0;  Ry = 90.0; Rz = 0.0 },
    @{ Rx = 12.0; Ry = -34.0; Rz = 56.0 }
)
$buf = New-Object System.Collections.Generic.List[byte]
Write-CFrameBlock $cases $buf
$arr = $buf.ToArray()

function D([byte[]] $bb, [int] $o) {
    $r = [uint32] (([uint32] $bb[$o]) -bor (([uint32] $bb[$o+1]) -shl 8) -bor
        (([uint32] $bb[$o+2]) -shl 16) -bor (([uint32] $bb[$o+3]) -shl 24))
    $sg = $r % 2
    $rest = ($r - $sg) / 2
    $bt = [uint32] ($rest + ([uint32] 2147483648 * $sg))
    return [BitConverter]::ToSingle([BitConverter]::GetBytes($bt), 0)
}

$n = 3
$base = 4
for ($rec = 0; $rec -lt $n; $rec++) {
    $out = @()
    for ($k = 0; $k -lt 4; $k++) {
        $t = New-Object byte[] 4
        for ($j = 0; $j -lt 4; $j++) { $t[$j] = $arr[($base + (($k * 4) + $j) * $n) + $rec] }
        $out += [Math]::Round((D $t 0), 5)
    }
    Write-Host ('  record ' + $rec + ': ' + ($out -join ', '))
}
Write-Host '  want rec0 = 1, 0, 0, 0.5236   rec1 = 0, 1, 0, 1.5708   rec2 = compound'
