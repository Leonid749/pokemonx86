# Assembles the boot stub and launches it in QEMU.
#
# Neither NASM nor QEMU put themselves on PATH, so they are located explicitly.

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

$out = Join-Path $root "sharpemu.bin"
# nasm writes warnings to stderr; only the exit code decides success.
$nasmOut = & $nasm -f bin -i "$root\" -o $out (Join-Path $root "boot.asm") 2>&1
if ($LASTEXITCODE -ne 0) { $nasmOut | Out-String | Write-Host; throw "nasm failed" }
if ($nasmOut) { $nasmOut | Out-String | Write-Host }
Write-Host "assembled $out ($((Get-Item $out).Length) bytes)"

if ($args -contains "-build-only") { return }

$rom = Join-Path $repo "pokered-master\pokered.gbc"
$shot = Join-Path $root "qemu-screen.ppm"
if (Test-Path $shot) { Remove-Item $shot }

# Monitor on a TCP socket rather than stdio: the stdio monitor runs a readline
# editor that echoes and mangles piped input.
$port = 55432
$qemuArgs = @(
    "-kernel", $out,
    "-initrd", $rom,
    "-accel", "whpx",              # falls back to tcg if unavailable
    "-accel", "tcg",
    "-m", "256",
    "-display", "none",
    "-vga", "std",
    "-monitor", "tcp:127.0.0.1:$port,server,nowait",
    "-serial", "file:$root\trace-x86.txt",
    "-no-reboot"
)

Write-Host "launching qemu..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $qemu
$psi.Arguments = ($qemuArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)

$bootWait = if ($env:SHARPEMU_WAIT) { [int]$env:SHARPEMU_WAIT } else { 12 }
Start-Sleep -Seconds $bootWait   # emulating frames under TCG takes a while
try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $port)
    $ns = $client.GetStream()
    $wr = New-Object System.IO.StreamWriter($ns)
    $wr.AutoFlush = $true
    $wr.WriteLine("screendump $shot")
    Start-Sleep -Seconds 2
    $wr.WriteLine("quit")
    Start-Sleep -Milliseconds 500
    $client.Close()
} catch {
    Write-Warning "monitor connect failed: $_"
}

if (-not $p.WaitForExit(10000)) { $p.Kill() }
$err = $p.StandardError.ReadToEnd()
if ($err.Trim()) { Write-Host "qemu stderr: $err" }

if (-not (Test-Path $shot)) { Write-Warning "no screenshot produced"; return }

# Convert the PPM QEMU wrote into a PNG we can actually look at.
Add-Type -AssemblyName System.Drawing
$bytes = [System.IO.File]::ReadAllBytes($shot)
$pos = 0; $fields = @()
while ($fields.Count -lt 4) {
    while ([char]$bytes[$pos] -match '\s') { $pos++ }
    $tok = ""
    while (-not ([char]$bytes[$pos] -match '\s')) { $tok += [char]$bytes[$pos]; $pos++ }
    $fields += $tok
}
$pos++
$w = [int]$fields[1]; $h = [int]$fields[2]

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$bits = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
# Format32bppArgb is B,G,R,A in memory. Build the row as bytes rather than
# packing signed ints, which PowerShell widens and mangles.
$row = New-Object byte[] ($w * 4)
for ($y = 0; $y -lt $h; $y++) {
    $base = $pos + $y * $w * 3
    for ($x = 0; $x -lt $w; $x++) {
        $i = $base + $x * 3
        $o = $x * 4
        $row[$o]     = $bytes[$i + 2]   # B
        $row[$o + 1] = $bytes[$i + 1]   # G
        $row[$o + 2] = $bytes[$i]       # R
        $row[$o + 3] = 255
    }
    [System.Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]::Add($bits.Scan0, $y * $bits.Stride), $w * 4)
}
$bmp.UnlockBits($bits)
$outPng = [System.IO.Path]::ChangeExtension($shot, ".png")
$bmp.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "screenshot: $outPng (${w}x${h})"
