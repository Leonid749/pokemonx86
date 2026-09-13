# Builds pokemonx86.img -- a raw, BIOS-bootable disk image.
#
# Layout (512-byte sectors):
#   LBA 0        boot sector
#   LBA 1..32    stage 2
#   LBA 33..96   kernel
#   LBA 128..    ROM (1MB)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root
$nasm = if (Get-Command nasm -ErrorAction SilentlyContinue) { "nasm" } else { "C:\Program Files\NASM\nasm.exe" }

function Asm($src, $out) {
    # nasm writes warnings to stderr; only the exit code decides success, so
    # don't let ErrorActionPreference=Stop turn a warning into a failure.
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $o = & $nasm -f bin -dTONE_AUDIO -i "$root\" -o $out (Join-Path $root $src) 2>&1
    $ErrorActionPreference = $old
    if ($LASTEXITCODE -ne 0) { $o | Out-String | Write-Host; throw "nasm failed on $src" }
    Write-Host ("  {0,-14} {1,7} bytes" -f $src, (Get-Item $out).Length)
}

Write-Host "assembling:"
Asm "bootsect.asm" "$root\bootsect.bin"
Asm "stage2.asm"   "$root\stage2.bin"
Asm "boot.asm"     "$root\pokemonx86.bin"

$rom = Join-Path $repo "pokered-master\pokered.gbc"
if (-not (Test-Path $rom)) { throw "ROM missing - run build_rom.ps1 first" }

$SEC = 512
$img = Join-Path $root "pokemonx86.img"

# Sector budget must match the LBA constants in stage2.asm.
$layout = @(
    @{ File = "$root\bootsect.bin";  Lba = 0;   Max = 1    },
    @{ File = "$root\stage2.bin";    Lba = 1;   Max = 32   },
    @{ File = "$root\pokemonx86.bin";  Lba = 33;  Max = 64   },
    @{ File = $rom;                  Lba = 128; Max = 2048 }
)

$totalSectors = 128 + 2048 + 64 + 16   # ROM then 64 sectors of SRAM
$buf = New-Object byte[] ($totalSectors * $SEC)

foreach ($p in $layout) {
    $bytes = [System.IO.File]::ReadAllBytes($p.File)
    $secs = [math]::Ceiling($bytes.Length / $SEC)
    if ($secs -gt $p.Max) {
        throw "$($p.File) needs $secs sectors but only $($p.Max) are reserved at LBA $($p.Lba)"
    }
    [Array]::Copy($bytes, 0, $buf, $p.Lba * $SEC, $bytes.Length)
}

[System.IO.File]::WriteAllBytes($img, $buf)
Write-Host ""
Write-Host "wrote $img ($([math]::Round($buf.Length / 1MB, 2)) MB)"
