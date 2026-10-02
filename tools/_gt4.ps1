# Decode the RAW block the generator actually produced, using the generator's own
# writer semantics reproduced exactly (List[byte] + explicit uint32 cast).
$single = [single] 0.5235988   # 30 degrees in radians
$bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($single), 0)
$rot = (($bits -shl 1) -bor ($bits -shr 31)) -band 0xFFFFFFFF
$enc = [BitConverter]::GetBytes([uint32] $rot)
Write-Host ('  encoded 0.5235988 as: ' + (($enc | ForEach-Object { $_.ToString('X2') }) -join ' '))

# Now encode three known axis+angle records the way the generator does, through a
# List[byte], and print the raw block.
$vals = @(
    @([double] 1.0, [double] 0.0, [double] 0.0, 0.5235988),
    @([double] 0.0, [double] 1.0, [double] 0.0, 1.5707963),
    @([double] 0.3, [double] 0.5, [double] 0.81, 1.0)
)
$recs = New-Object System.Collections.Generic.List[byte[]]
foreach ($v in $vals) {
    $r = New-Object System.Collections.Generic.List[byte]
    foreach ($f in $v) {
        $s = [single] $f
        $b = [BitConverter]::ToUInt32([BitConverter]::GetBytes($s), 0)
        $rt = (($b -shl 1) -bor ($b -shr 31)) -band 0xFFFFFFFF
        $r.AddRange([BitConverter]::GetBytes([uint32] $rt))
    }
    $recs.Add($r.ToArray())
}
$n = $recs.Count
$out = New-Object System.Collections.Generic.List[byte]
for ($j = 0; $j -lt 16; $j++) {
    foreach ($rec in $recs) { $out.Add($rec[$j]) }
}
$arr = $out.ToArray()
Write-Host ('  block: ' + (($arr | ForEach-Object { $_.ToString('X2') }) -join ' '))

function Dec2([byte[]] $bb, [int] $o) {
    $r2 = [uint32] (([uint32] $bb[$o]) -bor (([uint32] $bb[$o+1]) -shl 8) -bor
        (([uint32] $bb[$o+2]) -shl 16) -bor (([uint32] $bb[$o+3]) -shl 24))
    $s2 = $r2 % 2
    $rest = ($r2 - $s2) / 2
    $b2 = [uint32] ($rest + ([uint32] 2147483648 * $s2))
    return [BitConverter]::ToSingle([BitConverter]::GetBytes($b2), 0)
}
for ($i = 0; $i -lt $n; $i++) {
    $f = @()
    for ($k = 0; $k -lt 4; $k++) { $f += [Math]::Round((Dec2 $arr ($k * 4 * $n + $i)), 4) }
    Write-Host ('  decoded rec' + $i + ' = (' + ($f -join ', ') + ')')
}
Write-Host '  expected: rec0=(1,0,0,0.5236) rec1=(0,1,0,1.5708) rec2=(0.3,0.5,0.81,1)'
