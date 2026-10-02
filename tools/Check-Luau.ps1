# Structural validator for the repo's Luau files.
#
# Checks the three things a text editor cannot:
#
#   1. Brace / paren / bracket balance, ignoring comments and strings.
#   2. Long comments (--[[ ... ]]) and long strings ([[ ... ]]) are all
#      *closed*. An unterminated one is the nastiest bug in a Luau file,
#      because the rest of the file is silently swallowed as comment text and
#      the error the engine reports can be hundreds of lines from the cause.
#   3. '--!strict' on line 1 (ARCHITECTURE.md #1).
#
# Run from the repo root:
#     tools\Check-Luau.ps1                  # every .luau under src/
#     tools\Check-Luau.ps1 -Path some.luau
#
# Deliberately does not type-check: that needs the Luau CLI, and Studio's
# compiler is the real authority. This catches the structural mistakes that a
# line-range replacement workflow can introduce.
param([string]$Path)

$ErrorActionPreference = 'Stop'

$files = if ($Path) { @($Path) }
         else { Get-ChildItem -Recurse -File -Path (Join-Path $PSScriptRoot '..\src') -Include *.luau,*.lua |
                ForEach-Object { $_.FullName } }

$failed = 0

foreach ($f in $files) {
  $text = [System.IO.File]::ReadAllText($f)
  $stack = New-Object System.Collections.Generic.Stack[object]
  $i = 0
  $n = $text.Length
  $line = 1
  $errs = New-Object System.Collections.Generic.List[string]

  while ($i -lt $n) {
    $c = $text[$i]
    $c2 = if ($i + 1 -lt $n) { $text.Substring($i, 2) } else { '' }
    $c4 = if ($i + 3 -lt $n) { $text.Substring($i, 4) } else { '' }

    if ($c -eq "`n") { $line++; $i++; continue }

    # long comment
    if ($c4 -eq '--[[') { $stack.Push(@{ kind = 'block'; line = $line }); $i += 4; continue }
    # long string
    if ($c2 -eq '[[')  { $stack.Push(@{ kind = 'string'; line = $line }); $i += 2; continue }

    $top = if ($stack.Count -gt 0) { $stack.Peek() } else { $null }

    if ($top -ne $null -and ($top.kind -eq 'block' -or $top.kind -eq 'string')) {
      if ($c2 -eq ']]') { [void]$stack.Pop(); $i += 2; continue }
      $i++; continue
    }

    # line comment
    if ($c2 -eq '--') {
      while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }
      continue
    }

    # quoted string
    if ($c -eq '"' -or $c -eq "'") {
      $q = $c; $i++
      while ($i -lt $n) {
        if ($text[$i] -eq '\') { $i += 2; continue }
        if ($text[$i] -eq "`n") { $line++; }
        if ($text[$i] -eq $q) { $i++; break }
        $i++
      }
      continue
    }

    switch ($c) {
      '{' { $stack.Push(@{ kind = '{'; line = $line }); $i++ }
      '(' { $stack.Push(@{ kind = '('; line = $line }); $i++ }
      '[' { $stack.Push(@{ kind = '['; line = $line }); $i++ }
      '}' {
        if ($stack.Count -eq 0) { $errs.Add("line $line : unexpected '}'") }
        else {
          $t = $stack.Pop()
          if ($t.kind -ne '{') { $errs.Add("line $line : '}' closes '$($t.kind)' opened at line $($t.line)") }
        }
        $i++
      }
      ')' {
        if ($stack.Count -eq 0) { $errs.Add("line $line : unexpected ')'") }
        else { $t = $stack.Pop(); if ($t.kind -ne '(') { $errs.Add("line $line : ')' closes '$($t.kind)' opened at line $($t.line)") } }
        $i++
      }
      ']' {
        if ($stack.Count -eq 0) { $errs.Add("line $line : unexpected ']'") }
        else { $t = $stack.Pop(); if ($t.kind -ne '[') { $errs.Add("line $line : ']' closes '$($t.kind)' opened at line $($t.line)") } }
        $i++
      }
      default { $i++ }
    }
  }

  foreach ($t in $stack) {
    $errs.Add("line $($t.line) : UNTERMINATED $($t.kind)")
  }

  $first = (Get-Content $f -TotalCount 1)
  if ($first -ne '--!strict') {
    $errs.Add("line 1 : missing '--!strict' (ARCHITECTURE.md #1)")
  }

  $rel = $f.Replace((Join-Path $PSScriptRoot '..'), '').TrimStart('\', '/')
  if ($errs.Count -eq 0) {
    Write-Host "PASS  $rel" -ForegroundColor DarkGreen
  }
  else {
    $failed++
    Write-Host "FAIL  $rel" -ForegroundColor Red
    foreach ($e in $errs) { Write-Host "        $e" -ForegroundColor Red }
  }
}

Write-Host ''
if ($failed -eq 0) { Write-Host "All $($files.Count) file(s) structurally valid." -ForegroundColor Green }
else { Write-Host "$failed file(s) failed." -ForegroundColor Red; exit 1 }
