function Dec2([byte[]] $bb, [int] $o) {
    $r2 = [uint32] (([uint32] $bb[$o]) -bor (([uint32] $bb[$o+1]) -shl 8) -bor
        (([uint32] $bb[$o+2]) -shl 16) -bor (([uint32] $bb[$o+3]) -shl 24))
    $s2 = $r2 % 2
    $rest = ($r2 - $s2) / 2
    $b2 = [uint32] ($rest + ([uint32] 2147483648 * $s2))
    return [BitConverter]::ToSingle([BitConverter]::GetBytes($b2), 0)
}

# The writer interleaves at BYTE granularity: byte j of record i is at (j*n + i).
# So float k of record i starts at byte (k*4*n + i) but its four bytes are NOT
# contiguous - they are at (j*n + i) for j = k*4 .. k*4+3.
function DecInterleaved([byte[]] $bb, [int] $base, [int] $n, [int] $k) {
    $tmp = New-Object byte[] 4
    for ($j = 0; $j -lt 4; $j++) { $tmp[$j] = $bb[$base + ($k * 4 + $j) * $n + 0] }
    # place 4 bytes for THIS record: index (k*4 + j)*n + recordIndex
    return $tmp
}

for ($i = 0; $i -lt $n; $i++) {
    $f = @()
    for ($k = 0; $k -lt 4; $k++) {
        $tmp = New-Object byte[] 4
        for ($j = 0; $j -lt 4; $j++) { $tmp[$j] = $arr[(($k * 4 + $j) * $n) + $i] }
        $f += [Math]::Round((Dec2 $tmp 0), 4)
    }
    Write-Host ('  decoded rec' + $i + ' = (' + ($f -join ', ') + ')')
}
Write-Host '  expected: rec0=(1,0,0,0.5236) rec1=(0,1,0,1.5708) rec2=(0.3,0.5,0.81,1)'
