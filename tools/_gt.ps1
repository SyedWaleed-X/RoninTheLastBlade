# Ground truth: encode three axis+angle records with the same column-major writer
# the generator uses, then de-interleave with stride = n and confirm it recovers
# the inputs. This isolates the interleave from everything else in the script.
function Enc([single]$v) {
    $bits = [uint32] ([BitConverter]::ToUInt32([BitConverter]::GetBytes($v), 0))
    return [uint32] (($bits -shl 1) -bor ($bits -shr 31))
}

function Dec([byte[]] $bb, [int] $o) {
    $rot = [uint32] (([uint32] $bb[$o]) -bor (([uint32] $bb[$o+1]) -shl 8) -bor
        (([uint32] $bb[$o+2]) -shl 16) -bor (([uint32] $bb[$o+3]) -shl 24))
    $s = $rot % 2
    $r = ($rot - $s) / 2
    $bits = [uint32] ($r + ([uint32] 2147483648 * $s))
    return [BitConverter]::ToSingle([BitConverter]::GetBytes($bits), 0)
}

$deg = [single] (30 * [Math]::PI / 180)
$data = @(
    @([single] 1.0,  [single] 0.0, [single] 0.0, $deg),
    @([single] 0.0,  [single] 1.0, [single] 0.0, $deg),
    @([single] 0.3,  [single] 0.5, [single] 0.81, $deg)
)

$n = $data.Count
$out = New-Object System.Collections.Generic.List[byte]
for ($j = 0; $j -lt 16; $j++) {
    for ($i = 0; $i -lt $n; $i++) {
        $f = $data[$i][[int] ($j / 4)]
        $out.AddRange([BitConverter]::GetBytes((Enc $f)))
    }
}
$arr = $out.ToArray()
Write-Host ('first 16: ' + (($arr[0..15] | ForEach-Object { $_.ToString('X2') }) -join ' '))
for ($i = 0; $i -lt $n; $i++) {
    $f = @()
    for ($k = 0; $k -lt 4; $k++) { $f += [Math]::Round((Dec $arr (4 * $k * $n + $i)), 4) }
    Write-Host ('  rec' + $i + ' = ' + ($f -join ', '))
}
