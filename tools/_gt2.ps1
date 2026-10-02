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
    @([single] 1.0, [single] 0.0, [single] 0.0, $deg),
    @([single] 0.0, [single] 1.0, [single] 0.0, $deg),
    @([single] 0.3, [single] 0.5, [single] 0.81, $deg)
)
$n = $data.Count

# A: column-major ACROSS records -> byte j of record i at (j*n + i)
$a = New-Object System.Collections.Generic.List[byte]
for ($j = 0; $j -lt 16; $j++) {
    for ($i = 0; $i -lt $n; $i++) { $a.AddRange([BitConverter]::GetBytes((Enc $data[$i][[int] ($j / 4)]))) }
}
# B: record-major, four floats interleaved within each record -> (i*16 + j)
$b = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt $n; $i++) {
    for ($j = 0; $j -lt 16; $j++) { $b.AddRange([BitConverter]::GetBytes((Enc $data[$i][[int] ($j / 4)]))) }
}

foreach ($case in @(@{ N = 'A across-records (j*n+i)'; Arr = $a.ToArray(); S = $n },
                    @{ N = 'B record-major  (i*16+j)'; Arr = $b.ToArray(); S = 16 })) {
    $arr = $case.Arr
    $ok = $true
    $lines = @()
    for ($i = 0; $i -lt $n; $i++) {
        $f = @()
        for ($k = 0; $k -lt 4; $k++) { $f += [Math]::Round((Dec $arr ($k * 4 * $case.S + $i)), 4) }
        $lines += ('rec' + $i + '=(' + ($f -join ',') + ')')
        for ($k = 0; $k -lt 4; $k++) {
            if ([Math]::Abs($f[$k] - $data[$i][$k]) -gt 0.001) { $ok = $false }
        }
    }
    Write-Host ($case.N + '  ->  ' + ($lines -join '  ') + '   ROUNDTRIP=' + $ok)
}
