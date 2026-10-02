# The angle float is the odd one out. Print what the WRITER put in the 4th slot
# versus what Get-EulerToAxisAngle produced, by encoding the same value directly.
$angle = 0.5235988
$single = [single] $angle
$bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($single), 0)
$rot = (($bits -shl 1) -bor ($bits -shr 31)) -band 0xFFFFFFFF
$want = [BitConverter]::GetBytes([uint32] $rot)
Write-Host ('  angle 0.5235988 should encode as: ' + (($want | ForEach-Object { $_.ToString('X2') }) -join ' '))

# Now find those 4 bytes inside the block. The 4th float of record 0 sits at
# byte base + 12*n + 0 .. +3.
$base = 4
$n = 3
$got = @()
for ($j = 0; $j -lt 4; $j++) { $got += $arr[($base + (12 + $j) * $n) + 0] }
Write-Host ('  block bytes for angle rec0: ' + (($got | ForEach-Object { $_.ToString('X2') }) -join ' '))

# Compare with the axis float bytes (float 0 of record 0) which DO decode right.
$got0 = @()
for ($j = 0; $j -lt 4; $j++) { $got0 += $arr[($base + (0 + $j) * $n) + 0] }
Write-Host ('  block bytes for axis.x rec0: ' + (($got0 | ForEach-Object { $_.ToString('X2') }) -join ' ') + '  (want 00 00 00 7F)')

# The writer builds each 16-byte record, then Write-Interleaved emits byte j of
# every record. So byte j of record i is at j*n + i. Float 3 of record 0 is bytes
# 12..15 of record 0 -> block offsets 12*n+0 .. 15*n+0. That is what we read.
Write-Host ('  total block length: ' + $arr.Length + ' (expected ' + (4 + 16 * 3 + 12 * 4) + ')')
