use crate::airprint;
use crate::config::DeviceConfig;
use log::{error, info};
use std::thread;
use std::time::Duration;
use winprint::ticket::PrintCapabilities;
use zeroconf::event_loop::TEventLoop;
use zeroconf::service::TMdnsService;
use zeroconf::txt_record::TTxtRecord;
use zeroconf::{MdnsService, ServiceType, TxtRecord};

/// The capabilities a printer is advertised with.
///
/// This has to be resolved on the sharing thread rather than read from
/// `DeviceConfig`, because AirPrint's TXT record describes what the *device*
/// can do (colour, duplex, resolutions) and that only comes from the Windows
/// print capabilities.
pub struct DnssdCapabilities {
    pub urf: String,
    pub color: bool,
    pub duplex: bool,
}

pub fn serve_dnssd(
    device_config: &DeviceConfig,
    port: u16,
    type_name: &str,
    capabilities: PrintCapabilities,
) {
    let device_config = device_config.clone();
    let type_name = type_name.to_string();
    thread::spawn(move || {
        let color = airprint::supports_color(&capabilities);
        // `duplexes()` is an iterator, so it has to be consumed to be tested.
        let duplex = capabilities.duplexes().next().is_some();
        let caps = DnssdCapabilities {
            urf: airprint::urf_capabilities(&capabilities, color),
            color,
            duplex,
        };
        if let Err(e) = serve_dnssd_thread(&device_config, port, type_name.as_str(), caps) {
            error!("Failed to serve DNS-SD for {}: {}", device_config.name, e);
        }
    });
}

fn serve_dnssd_thread(
    device_config: &DeviceConfig,
    port: u16,
    type_name: &str,
    caps: DnssdCapabilities,
) -> anyhow::Result<()> {
    // The `universal` subtype is what iOS looks for: it browses
    // `_universal._sub._ipp._tcp` when populating the print sheet, and a service
    // registered under plain `_ipp._tcp` alone is never listed. `with_sub_types`
    // emits both the base type and the `<sub>._sub.<type>` pointer, so this one
    // line is the difference between "visible on iOS" and "invisible".
    let sub_types = vec!["universal"];
    let service_type = ServiceType::with_sub_types(type_name, "tcp", sub_types)?;
    let mut service = MdnsService::new(service_type, port);
    service.set_name(device_config.name.as_str());
    service.set_txt_record(build_txt_record(device_config, &caps)?);
    service.set_context(Box::new((
        type_name.to_string(),
        device_config.name.clone(),
    )));
    service.set_registered_callback(Box::new(|result, context| {
        let context = context.unwrap();
        let (type_name, device_name) = context.downcast_ref::<(String, String)>().unwrap();
        match result {
            Ok(_) => info!("DNS-SD registered for {} {}", type_name, device_name),
            Err(e) => error!(
                "Failed to register DNS-SD for {} {}: {}",
                type_name, device_name, e
            ),
        }
    }));
    let event_loop = service.register()?;
    loop {
        event_loop.poll(Duration::from_secs(0x7fffffff))?;
    }
}

/// Builds the Bonjour TXT record for a printer.
///
/// Split out from [`serve_dnssd_thread`] because the record is the entire
/// contract with AirPrint clients — the rest of that function is mDNS
/// plumbing — and a record that is wrong in one key makes the printer silently
/// invisible. Keeping it separate makes it testable.
fn build_txt_record(
    device_config: &DeviceConfig,
    caps: &DnssdCapabilities,
) -> anyhow::Result<TxtRecord> {
    let values = txt_record_values(device_config, caps);
    let mut txt_record = TxtRecord::new();
    for (key, value) in values {
        txt_record.insert(key, value.as_str())?;
    }
    Ok(txt_record)
}

/// The key/value pairs a printer is announced with, in insertion order.
///
/// Returning plain strings rather than filling a `TxtRecord` keeps the contents
/// of the announcement decoupled from Bonjour: building a `TxtRecord` requires
/// `dnssd.dll` to be loadable, so anything that touched one would be untestable
/// on a machine without Bonjour — which includes CI.
fn txt_record_values(
    device_config: &DeviceConfig,
    caps: &DnssdCapabilities,
) -> Vec<(&'static str, String)> {
    vec![
        ("txtvers", "1".to_string()),
        ("qtotal", "1".to_string()),
        // `rp` is the IPP resource path clients append to the host. The leading
        // slash is stripped because it is added back when the URL is assembled.
        (
            "rp",
            device_config
                .basepath
                .as_str()
                .strip_prefix('/')
                .unwrap_or(device_config.basepath.as_str())
                .to_string(),
        ),
        ("ty", device_config.make_and_model.clone()),
        ("product", device_config.make_and_model.clone()),
        ("priority", "0".to_string()),
        ("pdl", airprint::pdl_list().join(",")),
        ("note", String::new()),
        ("UUID", device_config.uuid.hyphenated().to_string()),
        // --- AirPrint-specific keys ---------------------------------------
        //
        // Without a non-empty `URF` iOS will not list the printer at all, even
        // when the service is otherwise perfectly reachable. Listing
        // `image/urf` inside `pdl` is not a substitute: that only says we
        // accept the format, whereas this dedicated key is what the print
        // sheet actually checks.
        ("URF", caps.urf.clone()),
        // Human-readable colour/duplex flags. iOS shows these and, more
        // importantly, uses them to decide which options the print sheet
        // offers.
        ("Color", bool_flag(caps.color)),
        ("Duplex", bool_flag(caps.duplex)),
        // Bit field describing the device class. 0x8090C4 is the conventional
        // value for a colour-capable IPP printer that reports its own
        // attributes; the low bits mirror the standard Windows
        // printer-capabilities flags.
        ("printer-type", "0x8090C4".to_string()),
        // 3 == idle. The print sheet greys out printers that are not idle.
        ("printer-state", "3".to_string()),
        // `air=none` states that the queue requires no authentication. Omitting
        // the key entirely makes some clients attempt credentials; `none` is
        // the value Apple's own documentation and CUPS both emit for an open
        // queue.
        ("air", "none".to_string()),
    ]
}

/// Bonjour booleans are the single characters `T`/`F`, not `true`/`false`.
fn bool_flag(value: bool) -> String {
    if value { "T" } else { "F" }.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::DeviceConfig;

    fn device_config() -> DeviceConfig {
        DeviceConfig {
            name: "Test Printer".to_string(),
            info: "Test printer".to_string(),
            target: "Test Printer".to_string(),
            uuid: uuid::Uuid::nil(),
            basepath: "/ipp/print".to_string(),
            dnssd: true,
            make_and_model: "Test Make Test Model".to_string(),
        }
    }

    fn capabilities(urf: &str, color: bool, duplex: bool) -> DnssdCapabilities {
        DnssdCapabilities {
            urf: urf.to_string(),
            color,
            duplex,
        }
    }

    fn value_of<'a>(values: &'a [(&str, String)], key: &str) -> Option<&'a str> {
        values
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v.as_str())
    }

    fn keys(values: &[(&str, String)]) -> Vec<String> {
        let mut keys = values
            .iter()
            .map(|(k, _)| (*k).to_string())
            .collect::<Vec<_>>();
        keys.sort();
        keys
    }

    #[test]
    fn announcement_carries_the_keys_airprint_requires() {
        let values = txt_record_values(&device_config(), &capabilities("V1.4,CP1,W8", true, true));

        // `URF` is the make-or-break key: without a non-empty value iOS does not
        // list the printer at all, and it reports nothing that explains why.
        let urf = value_of(&values, "URF").expect("URF must be present");
        assert!(!urf.is_empty(), "URF must not be empty, iOS ignores it");

        // The remaining keys are what the print sheet uses to build its UI and
        // to decide which options to offer.
        for key in [
            "txtvers",
            "qtotal",
            "rp",
            "ty",
            "product",
            "priority",
            "pdl",
            "note",
            "UUID",
            "URF",
            "Color",
            "Duplex",
            "printer-type",
            "printer-state",
            "air",
        ] {
            assert!(
                value_of(&values, key).is_some(),
                "`{key}` is missing from the AirPrint announcement; present: {:?}",
                keys(&values)
            );
        }
    }

    #[test]
    fn pdl_advertises_urf_and_pwg_raster() {
        let values = txt_record_values(&device_config(), &capabilities("V1.4", false, false));
        let pdl = value_of(&values, "pdl").expect("pdl must be present");

        // `image/urf` here is what lets an AirPrint client send Apple Raster
        // directly instead of rasterising to PWG-Raster first.
        assert!(
            pdl.contains("image/urf"),
            "pdl should offer image/urf: {pdl}"
        );
        assert!(
            pdl.contains("image/pwg-raster"),
            "pdl should offer image/pwg-raster: {pdl}"
        );
    }

    #[test]
    fn rp_matches_the_configured_basepath_without_a_leading_slash() {
        let values = txt_record_values(&device_config(), &capabilities("V1.4", false, false));

        // `rp` is the IPP resource path clients append to the host. A leading
        // slash makes it resolve to //ipp/print and the connection fails.
        assert_eq!(value_of(&values, "rp"), Some("ipp/print"));
    }

    #[test]
    fn color_and_duplex_are_reported_per_device() {
        let color = txt_record_values(&device_config(), &capabilities("V1.4", true, false));
        assert_eq!(value_of(&color, "Color"), Some("T"));
        assert_eq!(value_of(&color, "Duplex"), Some("F"));

        let mono = txt_record_values(&device_config(), &capabilities("V1.4", false, true));
        assert_eq!(value_of(&mono, "Color"), Some("F"));
        assert_eq!(value_of(&mono, "Duplex"), Some("T"));
    }

    #[test]
    fn advertised_urf_is_passed_through_verbatim() {
        // The TXT value and the IPP `urf-supported` attribute are produced by
        // the same builder, so whatever it says must appear here unmodified.
        let urf = "V1.4,CP1,W8,SRGB24,RS300-600,DM1";
        let values = txt_record_values(&device_config(), &capabilities(urf, true, true));

        assert_eq!(value_of(&values, "URF"), Some(urf));
    }

    #[test]
    fn printer_state_is_idle_and_the_queue_is_open() {
        let values = txt_record_values(&device_config(), &capabilities("V1.4", false, false));

        // A non-idle printer is greyed out in the print sheet, and a queue that
        // does not declare `air=none` makes some clients stop to ask for
        // credentials that this service never accepts.
        assert_eq!(value_of(&values, "printer-state"), Some("3"));
        assert_eq!(value_of(&values, "air"), Some("none"));
    }

    #[test]
    fn uuid_is_the_hyphenated_form_of_the_configured_value() {
        let values = txt_record_values(&device_config(), &capabilities("V1.4", false, false));

        // Clients key their cached printer entries on this, so it has to be a
        // stable, well-formed UUID string rather than a debug representation.
        assert_eq!(
            value_of(&values, "UUID"),
            Some("00000000-0000-0000-0000-000000000000")
        );
    }
}
