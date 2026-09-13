//! Helpers for advertising the printer to Apple's AirPrint clients.
//!
//! AirPrint is not a separate protocol: it is IPP plus a set of expectations
//! about how the service is advertised over Bonjour. Two of those expectations
//! are enforced before iOS will even list a printer:
//!
//!   1. the `_ipp._tcp` service must carry a `_universal` subtype (advertised as
//!      `_universal._sub._ipp._tcp`), and
//!   2. the TXT record must contain a non-empty `URF` key.
//!
//! Missing either one makes the printer invisible in the iOS print sheet, with
//! no error shown anywhere — which is exactly the failure mode this module
//! exists to prevent.
//!
//! The same `URF` values also appear in the IPP reply as `urf-supported`, so
//! both are derived here from one source rather than being written out twice and
//! drifting apart.

use crate::attr::printer_resolution::all_supported_resolution_by_win;
use std::collections::BTreeSet;
use winprint::ticket::PrintCapabilities;

/// The `URF` capability string, e.g. `V1.4,CP1,W8,SRGB24,RS600,DM1`.
///
/// The value is Apple's own encoding, documented only loosely (it is derivable
/// from the `Get-Printer-Attributes` reply of a real AirPrint printer). Each
/// comma-separated entry is a capability class plus its parameters:
///
///   * `V1.4`   — the URF specification version we speak.
///   * `CP1`    — copy count support.
///   * `W8`     — 8-bit grayscale output.
///   * `SRGB24` — 24-bit sRGB colour. Added only when the device can actually
///     print colour, because advertising colour on a mono printer makes iOS
///     render in colour and then fail to rasterise.
///   * `RS...`  — supported resolutions in dpi, sorted ascending.
///   * `DM1`    — duplex mode 1.
///
/// iOS only checks that this key is present and non-empty before listing the
/// printer, but an inaccurate value leads to failed jobs later, so it is built
/// from the real device capabilities.
pub fn urf_capabilities(capabilities: &PrintCapabilities, color: bool) -> String {
    let mut parts = vec!["V1.4".to_owned(), "CP1".to_owned(), "W8".to_owned()];

    if color {
        parts.push("SRGB24".to_owned());
    }

    // Feed and cross-feed can differ (some printers only do 300x600 in one
    // direction), so the advertised set is the union of both axes — matching
    // what the IPP reply reports.
    let resolutions: BTreeSet<i32> =
        all_supported_resolution_by_win(capabilities.page_resolutions())
            .iter()
            .flat_map(|r| [r.cross_feed, r.feed])
            .filter(|dpi| *dpi > 0)
            .collect();
    if !resolutions.is_empty() {
        parts.push(format!(
            "RS{}",
            resolutions
                .into_iter()
                .map(|dpi| dpi.to_string())
                .collect::<Vec<_>>()
                .join("-")
        ));
    }

    parts.push("DM1".to_owned());
    parts.join(",")
}

/// The `pdl` TXT value: the document formats this service accepts, most
/// preferred first.
///
/// Order matters. iOS sends whichever format appears first in this list, so
/// `application/pdf` has to lead when PDF support is compiled in — otherwise
/// iOS picks a raster format and the far better PDF path (which preserves text
/// and vector content) is never used.
pub fn pdl_list() -> Vec<&'static str> {
    let mut pdl = Vec::new();
    if cfg!(any(feature = "winpdf", feature = "pdfium")) {
        pdl.push("application/pdf");
    }
    pdl.push("application/vnd.ms-xpsdocument");
    pdl.push("image/pwg-raster");
    pdl.push("image/urf");
    pdl
}

/// Whether the device can print in colour.
pub fn supports_color(capabilities: &PrintCapabilities) -> bool {
    use crate::attr::ipp_sys_predefined_map::IppSysPredefinedMap;
    use crate::attr::print_color_mode::PrintColorMap;
    PrintColorMap::all_supported_by_win(capabilities.page_output_colors()).contains(&"color")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pdl_always_offers_raster_formats() {
        let pdl = pdl_list();
        assert!(pdl.contains(&"image/urf"));
        assert!(pdl.contains(&"image/pwg-raster"));
        assert!(pdl.contains(&"application/vnd.ms-xpsdocument"));
    }

    #[test]
    fn pdl_prefers_pdf_when_available() {
        let pdl = pdl_list();
        if cfg!(any(feature = "winpdf", feature = "pdfium")) {
            assert_eq!(pdl[0], "application/pdf");
        }
    }
}
