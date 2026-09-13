# Collects the native DLLs a built Windows binary needs at runtime.
#
# Two of them are invisible to `cargo build` — nothing lands in the release
# directory, so a freshly built executable fails to start with
# STATUS_DLL_NOT_FOUND (0xC0000135, exit code -1073741515) until they are
# copied next to it:
#
#   * pdfium.dll — winprint's `pdfium` feature links it as a dylib
#     (`cargo:rustc-link-lib=dylib=pdfium`). The build script downloads it
#     into its own OUT_DIR, so it never lands in target/<triple>/release.
#
#   * dnssd.dll — bonjour-sys emits `#[link(name = "dnssd", kind = "raw-dylib")]`
#     for zero-config service discovery. raw-dylib creates a *startup* import
#     entry, not a manually-resolved one, so the loader demands the DLL before
#     main() runs — even when the config disables DNS-SD entirely.
#
# dnssd.dll ships with Apple's Bonjour (bundled with iTunes / Bonjour Print
# Services) and is not redistributable, so there is nothing to copy: we locate
# an installed copy for local test runs and otherwise tell the user to install
# Bonjour. `Get-NativeDependencyReport` makes that requirement explicit.
#
# Deliberately NO `Set-StrictMode` here: this file is dot-sourced, so such a
# call would leak into the caller's scope and change its behaviour (and on
# `-Version Latest` makes .NET method overload resolution fail). Callers that
# want strict mode set it themselves.

# The raw-dylib import means the loader needs this file present at startup.
$DnssdName = "dnssd.dll"

function Get-PdfiumDll {
    <#
    .SYNOPSIS
        Finds pdfium.dll inside a profile directory's build-script output.
    .PARAMETER ProfileDir
        The cargo profile directory, i.e. target/<triple>/release. Cargo keeps
        build-script output in <ProfileDir>/build.
    #>
    param([Parameter(Mandatory = $true)][string]$ProfileDir)

    $buildRoot = Join-Path $ProfileDir "build"
    if (-not (Test-Path $buildRoot)) { return $null }

    # The DLL sits at <build>/<crate>-<hash>/out/pdfium_binaries_<id>/pdfium.dll,
    # where the hash and build id both change between releases.
    return Get-ChildItem -Path $buildRoot -Recurse -Filter "pdfium.dll" -File `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-DnssdDll {
    <#
    .SYNOPSIS
        Locates an installed dnssd.dll (Apple Bonjour) on this machine.
    .DESCRIPTION
        Only used for local verification. CI runners do not have Bonjour, so
        this legitimately returns $null there.
    #>
    $candidates = @(
        "${env:ProgramFiles}\Bonjour\dnssd.dll"
        "${env:ProgramFiles(x86)}\Bonjour\dnssd.dll"
        "${env:CommonProgramFiles}\Apple\dnssd.dll"
        "$env:SystemRoot\System32\dnssd.dll"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return Get-Item -LiteralPath $c
        }
    }
    return $null
}

function Get-PeImportedDll {
    <#
    .SYNOPSIS
        Reads the names of the DLLs a PE file imports, without external tools.
    .DESCRIPTION
        dumpbin would do this, but it is not on PATH on a GitHub runner unless
        the MSVC environment is initialised with vcvarsall/Enter-VsDevShell.
        Parsing the import directory directly avoids that dependency entirely.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $names = New-Object System.Collections.Generic.List[string]

    # --- DOS header -> e_lfanew (offset 0x3C) ---
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Not a PE file: $Path"
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ([System.BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
        throw "Missing PE signature: $Path"
    }

    # --- COFF header: machine, section count, optional header size ---
    $coff = $peOffset + 4
    $sectionCount = [System.BitConverter]::ToUInt16($bytes, $coff + 2)
    $optionalSize = [System.BitConverter]::ToUInt16($bytes, $coff + 16)
    $optional = $coff + 20

    # PE32+ (0x20B) vs PE32 (0x10B) shifts the data directory base by 16 bytes.
    $magic = [System.BitConverter]::ToUInt16($bytes, $optional)
    $dataDirBase = if ($magic -eq 0x20B) { $optional + 112 } else { $optional + 96 }

    # Data directory entry 1 is the import table (RVA + size).
    $importRva = [System.BitConverter]::ToUInt32($bytes, $dataDirBase + 8)
    if ($importRva -eq 0) { return $names }   # nothing imported

    # --- map RVA -> file offset via the section table ---
    $sections = $optional + $optionalSize
    $rvaToOffset = $null
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $s = $sections + ($i * 40)
        $virtualSize = [System.BitConverter]::ToUInt32($bytes, $s + 8)
        $virtualAddr = [System.BitConverter]::ToUInt32($bytes, $s + 12)
        $rawSize     = [System.BitConverter]::ToUInt32($bytes, $s + 16)
        $rawPtr      = [System.BitConverter]::ToUInt32($bytes, $s + 20)
        $span = [Math]::Max($virtualSize, $rawSize)
        if ($importRva -ge $virtualAddr -and $importRva -lt ($virtualAddr + $span)) {
            $rvaToOffset = $rawPtr + ($importRva - $virtualAddr)
            break
        }
    }
    if ($null -eq $rvaToOffset) { throw "Could not map import RVA to a file offset: $Path" }

    # --- walk IMAGE_IMPORT_DESCRIPTOR entries (20 bytes each, 0-terminated) ---
    $cursor = $rvaToOffset
    while ($true) {
        $nameRva = [System.BitConverter]::ToUInt32($bytes, $cursor + 12)
        $firstThunk = [System.BitConverter]::ToUInt32($bytes, $cursor + 16)
        if ($nameRva -eq 0 -and $firstThunk -eq 0) { break }

        # Translate this descriptor's name RVA the same way.
        $nameOffset = $null
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $s = $sections + ($i * 40)
            $virtualSize = [System.BitConverter]::ToUInt32($bytes, $s + 8)
            $virtualAddr = [System.BitConverter]::ToUInt32($bytes, $s + 12)
            $rawSize     = [System.BitConverter]::ToUInt32($bytes, $s + 16)
            $rawPtr      = [System.BitConverter]::ToUInt32($bytes, $s + 20)
            $span = [Math]::Max($virtualSize, $rawSize)
            if ($nameRva -ge $virtualAddr -and $nameRva -lt ($virtualAddr + $span)) {
                $nameOffset = $rawPtr + ($nameRva - $virtualAddr)
                break
            }
        }
        if ($null -ne $nameOffset) {
            $end = $nameOffset
            while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
            $names.Add([System.Text.Encoding]::ASCII.GetString($bytes, $nameOffset, $end - $nameOffset))
        }

        $cursor += 20
        if ($cursor + 20 -gt $bytes.Length) { break }
    }

    return $names
}

function Test-PeImportsDll {
    <#
    .SYNOPSIS
        True when a PE file's import table references the given DLL name.
    .DESCRIPTION
        Matching is case-insensitive: import names are stored as written by the
        linker, so a binary may record ADVAPI32.dll while we ask for
        advapi32.dll.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DllName
    )
    foreach ($imported in (Get-PeImportedDll -Path $Path)) {
        if ($imported -and $imported.Trim() -ieq $DllName) { return $true }
    }
    return $false
}

function Copy-NativeDependencies {
    <#
    .SYNOPSIS
        Copies pdfium.dll next to the built binaries.
    .PARAMETER ProfileDir
        The cargo profile directory, i.e. target/<triple>/release.
    .OUTPUTS
        The list of DLLs that were copied.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir
    )

    $copied = @()

    $pdfium = Get-PdfiumDll -ProfileDir $ProfileDir
    if ($pdfium) {
        Copy-Item -LiteralPath $pdfium.FullName -Destination $ProfileDir -Force
        $copied += $pdfium.FullName
    }

    # dnssd.dll is never copied: it is not redistributable, and on a machine
    # that has Bonjour the loader finds it under Program Files on its own.
    return , $copied
}

function Get-NativeDependencyReport {
    <#
    .SYNOPSIS
        Describes which runtime DLLs are satisfied, for logging and to decide
        whether the built executable can actually be launched on this machine.
    .PARAMETER ProfileDir
        The cargo profile directory, i.e. target/<triple>/release.
    #>
    param([Parameter(Mandatory = $true)][string]$ProfileDir)

    $pdfium = Get-PdfiumDll -ProfileDir $ProfileDir
    $dnssd = Get-DnssdDll

    return [pscustomobject]@{
        PdfiumPath       = if ($pdfium) { $pdfium.FullName } else { $null }
        PdfiumBundled    = [bool]$pdfium        # we ship this one ourselves
        DnssdPath        = if ($dnssd) { $dnssd.FullName } else { $null }
        DnssdAvailable   = [bool]$dnssd         # local-only; never bundled
        CanLaunchLocally = ([bool]$pdfium -and [bool]$dnssd)
    }
}
