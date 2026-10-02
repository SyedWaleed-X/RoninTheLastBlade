#!/usr/bin/env pwsh
# Replaces a line range in a file, 1-based inclusive, with new content read from stdin.
# Used because the repo files are CRLF and the editor tool's exact-match
# replacement does not normalise line endings.
param(
  [Parameter(Mandatory = $true)][string]   $Path,
  [Parameter(Mandatory = $true)][int]      $StartLine,
  [Parameter(Mandatory = $true)][int]      $EndLine,
  [Parameter(Mandatory = $true)][string]   $ReplacementFile
)
$ErrorActionPreference = 'Stop'
$lines = [System.Collections.Generic.List[string]]::new()
foreach ($l in [System.IO.File]::ReadAllLines($Path)) { $lines.Add($l) }

if ($StartLine -lt 1 -or $EndLine -gt $lines.Count -or $StartLine -gt $EndLine) {
  throw "Range $StartLine..$EndLine out of bounds (file has $($lines.Count) lines)"
}

$replacement = [System.Collections.Generic.List[string]]::new()
foreach ($l in [System.IO.File]::ReadAllLines($ReplacementFile)) { $replacement.Add($l) }

$lines.RemoveRange($StartLine - 1, $EndLine - $StartLine + 1)
$lines.InsertRange($StartLine - 1, $replacement)

[System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding $false))
Write-Output "OK: $Path now $($lines.Count) lines (replaced $StartLine..$EndLine with $($replacement.Count) lines)"
