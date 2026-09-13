# Builds pokered.gbc without make or a C compiler.
#
# Replaces the pret Makefile: discovers graphics targets by scanning INCBIN
# directives (which is what scan_includes exists for), runs rgbgfx, applies the
# ported gfx/pkmncompress passes, then rgbasm/rgblink/rgbfix.
#
# Success criterion is objective: sha1 of pokered.gbc must be
#   ea9bcae617fdf159b045185467ae58b2e4a48b9a

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$src    = Join-Path $root "pokered-master"
$recomp = Join-Path $root "recomp\bin\recomp.exe"

# Prefer a copy vendored next to this script, so rgbds does not have to be on PATH.
$localRgbds = Join-Path $root "rgbds-win64\bin"
if (Test-Path (Join-Path $localRgbds "rgbasm.exe")) {
    $env:PATH = "$localRgbds;$env:PATH"
}

foreach ($t in @("rgbasm","rgblink","rgbfix","rgbgfx")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "$t not found. Put rgbds v1.0.3 on PATH or in $localRgbds (rgbdscheck.asm rejects other versions)."
    }
}
if (-not (Test-Path $recomp)) { throw "recomp.exe missing; run recomp\build.ps1 first" }

$ver = (& rgbasm --version) -join ""
Write-Host "using $ver"
if ($ver -notmatch "1\.0\.3") {
    Write-Warning "expected rgbds 1.0.3 (per .rgbds-version); rgbdscheck.asm will likely fail the build"
}

function Run($exe, $argList) {
    & $exe @argList
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argList -join ' ') -> exit $LASTEXITCODE" }
}

# --- per-file flags lifted from the Makefile ------------------------------

# rgbgfx extra flags
$rgbgfxFlags = @{
    "gfx/intro/blue_jigglypuff_1" = @("--columns")
    "gfx/intro/blue_jigglypuff_2" = @("--columns")
    "gfx/intro/blue_jigglypuff_3" = @("--columns")
    "gfx/intro/red_nidorino_1"    = @("--columns")
    "gfx/intro/red_nidorino_2"    = @("--columns")
    "gfx/intro/red_nidorino_3"    = @("--columns")
    "gfx/intro/gengar"            = @("--columns")
}

# post-processing passes (our ported tools/gfx)
function Get-GfxPasses($stem, $srcPng) {
    $f = @()
    # Makefile: gfx/tilesets/%.2bpp gets --trim-whitespace via a pattern rule,
    # and reds_house additionally accumulates --preserve=0x48.
    if ($stem -like "gfx/tilesets/*")            { $f += "--trim-whitespace" }
    if ($stem -eq "gfx/tilesets/reds_house")     { $f += "--preserve=0x48" }
    if ($stem -eq "gfx/battle/move_anim_0")      { $f += "--trim-whitespace" }
    if ($stem -eq "gfx/battle/move_anim_1")      { $f += "--trim-whitespace" }
    if ($stem -eq "gfx/slots/red_slots_1")       { $f += "--trim-whitespace" }
    if ($stem -eq "gfx/slots/blue_slots_1")      { $f += "--trim-whitespace" }
    if ($stem -eq "gfx/intro/gengar")            { $f += @("--remove-duplicates","--preserve=0x19,0x76") }
    if ($stem -eq "gfx/trade/game_boy")          { $f += "--remove-duplicates" }
    if ($stem -eq "gfx/credits/the_end")         { $f += @("--interleave","--png=$srcPng") }
    return $f
}

# --- discover graphics targets from INCBIN directives ---------------------

Write-Host "scanning INCBIN targets..."
$incbins = New-Object System.Collections.Generic.HashSet[string]
Get-ChildItem -Path $src -Recurse -Include *.asm,*.inc -File | ForEach-Object {
    foreach ($m in [regex]::Matches((Get-Content $_.FullName -Raw), 'INCBIN\s+"([^"]+)"')) {
        [void]$incbins.Add($m.Groups[1].Value)
    }
}
Write-Host "  $($incbins.Count) distinct INCBIN targets"

$want2bpp = @(); $want1bpp = @(); $wantPic = @()
foreach ($p in $incbins) {
    if ($p -like "*.2bpp") { $want2bpp += $p }
    elseif ($p -like "*.1bpp") { $want1bpp += $p }
    elseif ($p -like "*.pic")  { $wantPic  += $p }
}
Write-Host "  2bpp=$($want2bpp.Count) 1bpp=$($want1bpp.Count) pic=$($wantPic.Count)"

# --- convert PNGs ---------------------------------------------------------

function Build-Gfx($relTarget, $depth) {
    $stem   = $relTarget -replace '\.(1bpp|2bpp)$',''
    $png    = Join-Path $src "$stem.png"
    $outAbs = Join-Path $src $relTarget
    if (-not (Test-Path $png)) { throw "missing source PNG for $relTarget" }

    $args = @("--colors","dmg")
    if ($depth -eq 1) { $args += @("--depth","1") }
    if ($rgbgfxFlags.ContainsKey($stem)) { $args += $rgbgfxFlags[$stem] }
    $args += @("-o",$outAbs,$png)
    Run "rgbgfx" $args

    $passes = Get-GfxPasses $stem $png
    if ($passes.Count -gt 0) {
        Run $recomp (@("gfx") + $passes + @("--depth",$depth,"-o",$outAbs,$outAbs))
    }
}

$n = 0
foreach ($t in $want2bpp) { Build-Gfx $t 2; $n++ }
foreach ($t in $want1bpp) { Build-Gfx $t 1; $n++ }
Write-Host "converted $n PNGs"

# .pic files are compressed from a matching .2bpp that is not itself INCBINed
foreach ($t in $wantPic) {
    $stem    = $t -replace '\.pic$',''
    $twobpp  = Join-Path $src "$stem.2bpp"
    if (-not (Test-Path $twobpp)) { Build-Gfx "$stem.2bpp" 2 }
    Run $recomp @("pkmncompress", $twobpp, (Join-Path $src "$t"))
}
Write-Host "compressed $($wantPic.Count) .pic sprites"

# --- assemble, link, fix --------------------------------------------------

Push-Location $src
try {
    $objs = @("audio","home","main","maps","ram","text","gfx/pics","gfx/sprites","gfx/tilesets")

    # rgbdscheck.o is a guard the Makefile builds first; it fails the build on
    # the wrong rgbds version.
    Run "rgbasm" @("-o","rgbdscheck.o","rgbdscheck.asm")

    foreach ($o in $objs) {
        Run "rgbasm" @("-Weverything","-Wtruncation=1","-Q8","-P","includes.asm","-D","_RED","-o","$o`_red.o","$o.asm")
    }

    $objFiles = $objs | ForEach-Object { "$_`_red.o" }
    Run "rgblink" (@("-Weverything","-Wtruncation=1","-d","-p","0x00","-l","layout.link",
                     "-m","pokered.map","-n","pokered.sym","-o","pokered.gbc") + $objFiles)

    Run "rgbfix" @("-Weverything","-jsv","-n","0","-k","01","-l","0x33",
                   "-m","MBC3+RAM+BATTERY","-r","03","-p","0x00","-t","POKEMON RED","pokered.gbc")

    $sha = (Get-FileHash "pokered.gbc" -Algorithm SHA1).Hash.ToLower()
    $expect = "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
    Write-Host ""
    if ($sha -eq $expect) {
        Write-Host "OK  pokered.gbc sha1 $sha" -ForegroundColor Green
        Write-Host "    front end verified end to end"
    } else {
        Write-Host "MISMATCH" -ForegroundColor Red
        Write-Host "  got      $sha"
        Write-Host "  expected $expect"
        exit 1
    }
}
finally { Pop-Location }
