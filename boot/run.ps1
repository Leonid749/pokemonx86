# Assembles pokemonx86 and launches it in a visible QEMU window.
# Close the QEMU window to stop it.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root

function Find-Tool($name, $candidates) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    throw "$name not found"
}

$nasm = Find-Tool "nasm" @("C:\Program Files\NASM\nasm.exe")
$qemu = Find-Tool "qemu-system-x86_64" @("C:\Program Files\qemu\qemu-system-x86_64.exe")

$bin = Join-Path $root "pokemonx86.bin"
$out = & $nasm -f bin -i "$root\" -o $bin (Join-Path $root "boot.asm") 2>&1
if ($LASTEXITCODE -ne 0) { $out | Out-String | Write-Host; throw "nasm failed" }
Write-Host "assembled $bin ($((Get-Item $bin).Length) bytes)"

$rom = Join-Path $repo "pokered-master\pokered.gbc"
if (-not (Test-Path $rom)) { throw "ROM missing - run build_rom.ps1 first" }

Write-Host "launching... close the QEMU window to stop."

& $qemu `
    -kernel $bin `
    -initrd $rom `
    -accel whpx -accel tcg `
    -m 256 `
    -vga std `
    -audiodev sdl,id=snd0 `

    -machine pcspk-audiodev=snd0 `
    -serial file:"$root\run-serial.txt" `
    -no-reboot
