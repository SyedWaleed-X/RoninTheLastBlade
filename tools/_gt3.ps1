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

# Codec in isolation.
foreach ($v in @([single] 1.0, [single] 0.0, [single] 0.3, [single] 0.5236)) {
    $bytes = [BitConverter]::GetBytes((Enc $v))
    Write-Host ('  ' + $v + ' -> ' + (($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ') +
        ' -> ' + (Dec $bytes 0))
}

# The interleave question, with ONE record so interleave is the identity.
$one = @([single] 1.0, [single] 2.0, [single] 3.0, [single] 4.0)
$out = New-Object System.Collections.Generic.List[byte]
for ($j = 0; $j -lt 16; $j++) { $out.AddRange([BitConverter]::GetBytes((Enc $one[[int] ($j / 4)]))) }
$arr = $out.ToArray()
Write-Host ('  single record raw: ' + (($arr | ForEach-Object { $_.ToString('X2') }) -join ' '))
for ($k = 0; $k -lt 4; $k++) {
    Write-Host ('    float ' + $k + ' = ' + (Dec $arr ($k * 4)))
}

# Now TWO records: does interleaving mix them?
$two = @(
    @([single] 1.0, [single] 2.0, [single] 3.0, [single] 4.0),
    @([single] 5.0, [single] 6.0, [single] 7.0, [single] 8.0)
)
$n = 2
$out2 = New-Object System.Collections.Generic.List[byte]
for ($j = 0; $j -lt 16; $j++) {
    for ($i = 0; $i -lt $n; $i++) { $out2.AddRange([BitConverter]::GetBytes((Enc $two[$i][[int] ($j / 4)]))) }
}
$arr2 = $out2.ToArray()
Write-Host ('  two records raw: ' + (($arr2 | ForEach-Object { $_.ToString('X2') }) -join ' '))
Write-Host '  decode with stride n=2 (k*4*n + i):'
for ($i = 0; $i -lt $n; $i++) {
    $f = @()
    for ($k = 0; $k -lt 4; $k++) { $f += (Dec $arr2 ($k * 4 * $n + $i)) }
    Write-Host ('    rec' + $i + ' = ' + ($f -join ', '))
}
