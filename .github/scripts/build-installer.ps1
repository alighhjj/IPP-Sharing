# Builds the Windows distribution for a single architecture.
#
# Produces, in -OutputDir:
#   * IPP-Sharing-<version>-<arch>.zip        portable bundle
#   * IPP-Sharing-<version>-<arch>-setup.exe  installer (Inno Setup)
#   * config.example.yaml, README.md, LICENSE.md, COMMIT.txt
#
# The installer step is skipped with a warning if Inno Setup is unavailable,
# so the portable zip is always produced.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$ShortSha = "",
    # Lets the PR/preview workflow reuse this script for staging without paying
    # the Inno Setup compile every run.
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# --- architecture mapping -----------------------------------------------------
switch ($Target) {
    "x86_64-pc-windows-msvc" { $arch = "x86_64"; $innoArch = "x64compatible" }
    "i686-pc-windows-msvc"   { $arch = "x86";    $innoArch = "x86compatible" }
    default { throw "Unsupported target: $Target" }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$releaseDir = Join-Path $repoRoot "target/$Target/release"
$bundleName = "IPP-Sharing-$Version-$arch"

# -OutputDir may be absolute (the workflow passes one) or repo-relative.
if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $outPath = $OutputDir
} else {
    $outPath = Join-Path $repoRoot $OutputDir
}
$outPath = [System.IO.Path]::GetFullPath($outPath)

Write-Host "=== Packaging IPP Sharing $Version ($arch) ===" -ForegroundColor Cyan
Write-Host "Target     : $Target"
Write-Host "Release dir: $releaseDir"
Write-Host "Output dir : $outPath"

if (-not (Test-Path $releaseDir)) {
    throw "Release directory not found: $releaseDir"
}

# --- stage a clean bundle -----------------------------------------------------
$stage = Join-Path $repoRoot "build/stage-$arch"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $outPath | Out-Null

foreach ($exe in @("ipp-sharing-gui.exe", "ipp-sharing.exe")) {
    $src = Join-Path $releaseDir $exe
    if (-not (Test-Path $src)) { throw "Missing build output: $src" }
    Copy-Item $src $stage
    Write-Host ("  + {0} ({1:N1} MB)" -f $exe, ((Get-Item $src).Length / 1MB))
}

# PDFium is linked as a dynamic library by winprint's `pdfium` feature, so the
# executables fail to start with STATUS_DLL_NOT_FOUND unless pdfium.dll sits
# next to them. Cargo drops it in the build script's OUT_DIR, whose path
# contains a moving hash and version — hence the wildcard search.
$pdfium = Get-ChildItem -Path (Join-Path $releaseDir "build") -Recurse `
    -Filter "pdfium.dll" -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($pdfium) {
    Copy-Item $pdfium.FullName $stage
    Write-Host ("  + pdfium.dll ({0:N1} MB)" -f ($pdfium.Length / 1MB))
} else {
    # Warn rather than fail: a build with --no-default-features --features
    # winpdf does not need it.
    Write-Warning "pdfium.dll not found under $releaseDir\build — PDF printing will not work in this bundle."
}

Copy-Item (Join-Path $repoRoot "README.md") $stage
Copy-Item (Join-Path $repoRoot "LICENSE.md") $stage

$exampleConfig = Join-Path $repoRoot "config.example.yaml"
if (Test-Path $exampleConfig) { Copy-Item $exampleConfig $stage }

# Ship a per-bundle commit marker for traceability.
$sha = if ($ShortSha) { $ShortSha } else { "unknown" }
"IPP Sharing $Version ($arch)`nCommit: $sha`nBuilt: $(Get-Date -Format 'u')" |
    Out-File -Encoding utf8 (Join-Path $stage "BUILD-INFO.txt")

# --- portable zip -------------------------------------------------------------
$zipPath = Join-Path $outPath "$bundleName.zip"
Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Portable bundle: $zipPath" -ForegroundColor Green

# --- installer ----------------------------------------------------------------
if ($SkipInstaller) {
    Write-Host "Skipping installer generation (-SkipInstaller)." -ForegroundColor Yellow
    Write-Host "Artifacts in ${outPath}:" -ForegroundColor Green
    Get-ChildItem $outPath | Select-Object Name, Length
    return
}

$iscc = $null
foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
    if ($candidate -and (Test-Path $candidate)) { $iscc = $candidate; break }
}
if (-not $iscc) {
    # Fall back to PATH lookup. Accept both the canonical name and, for
    # non-Windows development environments, the extension-less `iscc`.
    foreach ($name in @("ISCC.exe", "iscc.exe", "iscc")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $iscc = $cmd.Source; break }
    }
}

if (-not $iscc) {
    Write-Warning "Inno Setup not found; skipping installer generation (portable zip is still available)."
    Write-Host "Artifacts in ${outPath}:" -ForegroundColor Green
    Get-ChildItem $outPath | Select-Object Name, Length
    return
}

$issTemplate = Join-Path $repoRoot ".github/installer/ipp-sharing.iss"
$issGenerated = Join-Path $repoRoot "build/ipp-sharing-$arch.iss"

# Inno Setup wants native absolute paths with doubled backslashes. Under Wine,
# Unix paths must first be translated to drive-letter form, otherwise the
# compiler treats them as relative to the script. Doing this before the
# backslash doubling keeps the two transformations from interfering.
function ConvertTo-InnoPath([string]$p) {
    $full = [System.IO.Path]::GetFullPath($p)
    if (-not $IsWindows) {
        $converted = (& winepath -w $full 2>$null)
        if ($converted) { $full = $converted }
    }
    return $full.Replace('\', '\\')
}

$issContent = Get-Content $issTemplate -Raw
$issContent = $issContent.Replace("@APP_VERSION@", $Version)
$issContent = $issContent.Replace("@STAGE_DIR@", (ConvertTo-InnoPath $stage))
$issContent = $issContent.Replace("@OUTPUT_DIR@", (ConvertTo-InnoPath $outPath))
$issContent = $issContent.Replace("@OUTPUT_BASE@", "$bundleName-setup")
$issContent = $issContent.Replace("@ARCH@", $innoArch)
$issContent = $issContent.Replace("@ICON_FILE@", (ConvertTo-InnoPath (Join-Path $repoRoot "icons/app.ico")))
$issContent = $issContent.Replace("@LICENSE_FILE@", (ConvertTo-InnoPath (Join-Path $repoRoot "LICENSE.md")))
$issContent = $issContent.Replace("@REPO_ROOT@", (ConvertTo-InnoPath (Join-Path $repoRoot ".github/installer")))
$issContent = $issContent.Replace("@APP_EXE@", "ipp-sharing-gui.exe")
$issContent | Out-File -Encoding utf8 $issGenerated

Write-Host "Running Inno Setup compiler: $iscc" -ForegroundColor Cyan

# Under Wine the compiler is still a Windows binary, so it needs a drive-letter
# path. On a real Windows runner $issGenerated is already one.
$issArg = $issGenerated
if (-not $IsWindows) {
    $issArg = (& winepath -w $issGenerated 2>$null)
    if (-not $issArg) { $issArg = $issGenerated }
}

& $iscc $issArg
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setupExe = Join-Path $outPath "$bundleName-setup.exe"
if (-not (Test-Path $setupExe)) { throw "Installer was not produced: $setupExe" }
$setupSize = (Get-Item $setupExe).Length
# A setup binary that is suspiciously small means compression or staging went
# wrong; better to fail here than to publish a broken download.
if ($setupSize -lt 1MB) {
    throw "Installer looks truncated ($setupSize bytes): $setupExe"
}
Write-Host ("Installer: {0} ({1:N1} MB)" -f $setupExe, ($setupSize / 1MB)) -ForegroundColor Green

Write-Host "Artifacts in ${outPath}:" -ForegroundColor Green
Get-ChildItem $outPath | Select-Object Name, Length
