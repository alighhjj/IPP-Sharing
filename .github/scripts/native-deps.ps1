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
