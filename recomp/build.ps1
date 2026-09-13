# Builds the recompiler with whichever C# compiler this machine has.
# There is no .NET SDK installed, so we drive csc.exe directly and target
# the .NET Framework 4.x runtime that ships with Windows.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$candidates = @(
    "C:\Program Files\Microsoft Visual Studio\18\Insiders\MSBuild\Current\Bin\Roslyn\csc.exe",
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
)

$csc = $null
foreach ($c in $candidates) { if (Test-Path $c) { $csc = $c; break } }
if (-not $csc) { throw "No C# compiler found. Looked in: $($candidates -join '; ')" }

$out = Join-Path $root "bin"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force $out | Out-Null }

$sources = Get-ChildItem -Path (Join-Path $root "src") -Recurse -Filter *.cs | ForEach-Object { $_.FullName }
$exe = Join-Path $out "recomp.exe"

& $csc /nologo /langversion:latest /optimize+ /warn:4 /r:System.Drawing.dll /out:$exe $sources
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

Write-Host "built $exe  (csc: $(Split-Path -Leaf (Split-Path -Parent $csc)))"
