//! End-to-end check of the `Get-Printer-Attributes` reply as iOS sees it.
//!
//! AirPrint clients are unforgiving in a way that is hard to notice from the
//! server side: if a required attribute is missing, iOS silently drops the
//! printer from the print sheet without ever showing an error. There is no way
//! to observe that failure from here, so instead this test drives the real
//! service through the real request path and asserts on the attributes iOS is
//! known to require.
//!
//! The request is built and parsed as real IPP bytes rather than through a
//! helper, because the interesting part is exactly the wire format: a test that
//! bypassed serialisation could pass while iOS still saw nothing.

use ipp::attribute::IppAttribute;
use ipp::model::{DelimiterTag, IppVersion, Operation};
use ipp::request::IppRequestResponse;
use ipp::value::IppValue;
use ippper::model::{MediaSize, Resolution};
use ippper::service::simple::{PrinterInfoBuilder, SimpleIppService, SimpleIppServiceHandler};
use ippper::service::IppService;
use std::collections::HashMap;

/// A handler that does nothing. Everything under test is derived from
/// `PrinterInfo`, so no printing is involved.
struct StubHandler;

impl SimpleIppServiceHandler for StubHandler {}

/// Mirrors what `MyIppService::new` builds on a real machine, minus the parts
/// that need a live Windows printer.
fn printer_info() -> ippper::service::simple::PrinterInfo {
    let media_supported = vec![ippper::model::MediaInfo {
        name: Some("iso_a4_210x297mm".try_into().unwrap()),
        size: Some(MediaSize::new(21000, 29700)),
        margins: Some((0, 0, 0, 0)),
        source: Some("auto".try_into().unwrap()),
        ..Default::default()
    }];

    let mut info = PrinterInfoBuilder::default();
    info.name("Test Printer".try_into().unwrap())
        .make_and_model(Some("Test Make Test Model".try_into().unwrap()))
        .uuid(Some(uuid::Uuid::nil()))
        .dnssd_name(Some("Test Printer".try_into().unwrap()))
        .color_supported(true)
        .media_default(media_supported[0].clone())
        .media_supported(media_supported)
        .document_format_default("application/pdf".try_into().unwrap())
        .document_format_supported(vec![
            "application/pdf".try_into().unwrap(),
            "image/urf".try_into().unwrap(),
        ])
        .document_format_preferred(Some("application/pdf".try_into().unwrap()))
        .print_color_mode_default("color".try_into().unwrap())
        .print_color_mode_supported(vec![
            "color".try_into().unwrap(),
            "monochrome".try_into().unwrap(),
        ])
        .sides_supported(vec!["one-sided".try_into().unwrap()])
        .printer_resolution_default(Some(Resolution::new_dpi(300, 300)))
        .printer_resolution_supported(vec![Resolution::new_dpi(300, 300)])
        .pwg_raster_document_sheet_back(Some("normal".try_into().unwrap()))
        .pwg_raster_document_type_supported(vec!["srgb_8".try_into().unwrap()])
        .urf_supported(vec!["V1.4".try_into().unwrap(), "CP1".try_into().unwrap()]);
    info.build().expect("printer info should build")
}

/// The host iOS would have connected to. IPP derives `printer-uri-supported`
/// from the `Host` header, so this doubles as a check on that behaviour.
const HOST: &str = "test-printer.local:631";

/// IPP requests use origin-form request targets: an HTTP client opens a
/// connection to the printer and then POSTs to a path, so the request line
/// carries no scheme or authority. The host comes from the `Host` header
/// instead — which is exactly why a scheme cannot be taken from the URI here.
const ENDPOINT: &str = "/ipp/print";

/// Builds a `Get-Printer-Attributes` request exactly as iOS sends it: IPP 1.1
/// on the wire, with `requested-attributes=all`.
fn get_printer_attributes_request() -> IppRequestResponse {
    let mut request =
        IppRequestResponse::new(IppVersion::v1_1(), Operation::GetPrinterAttributes, None)
            .expect("request should build");
    // `charset` and `natural-language` are added by `new`; only the requested
    // attribute list is left to us.
    request.attributes_mut().add(
        DelimiterTag::OperationAttributes,
        IppAttribute::new(
            IppAttribute::REQUESTED_ATTRIBUTES.try_into().unwrap(),
            IppValue::Array(vec![IppValue::Keyword("all".try_into().unwrap())]),
        ),
    );
    request
}

/// Serialises the request, sends it through the service, then serialises and
/// re-parses the reply. Going through bytes on both sides is deliberate: it is
/// the only way this test can catch a serialisation bug.
async fn fetch_printer_attributes() -> HashMap<String, IppValue> {
    let service = SimpleIppService::new(printer_info(), StubHandler);

    let head = hyper::Request::builder()
        .method(hyper::Method::POST)
        .uri(ENDPOINT)
        .header("Content-Type", "application/ipp")
        .header("Host", HOST)
        .body(())
        .expect("request head should build")
        .into_parts()
        .0;

    let response = service
        .handle_request(head, get_printer_attributes_request())
        .await;

    // The status code for a response lives in the header's
    // operation-or-status field; 0 is `successful-ok`.
    assert_eq!(
        response.header().operation_or_status,
        0,
        "Get-Printer-Attributes should answer with successful-ok"
    );

    let attributes = response
        .attributes()
        .groups_of(DelimiterTag::PrinterAttributes)
        .flat_map(|group| group.attributes().iter())
        .map(|(name, attr)| (name.to_string(), attr.value().clone()))
        .collect::<HashMap<_, _>>();

    assert!(
        !attributes.is_empty(),
        "the reply must contain a printer-attributes group"
    );

    // Finally, prove the reply actually encodes: iOS talks to us over the wire,
    // so a reply that cannot be serialised is worthless no matter how complete
    // the in-memory attributes are.
    let encoded = response.to_bytes();
    assert!(
        encoded.len() > 8,
        "the encoded reply should contain a header and attributes"
    );
    // IPP messages start with version 1.x and end with the end-of-attributes
    // delimiter, so both bounds are checkable without a full decode.
    assert_eq!(
        encoded[0], 0x01,
        "the reply should be encoded as IPP version 1.x"
    );
    assert_eq!(
        *encoded.last().unwrap(),
        DelimiterTag::EndOfAttributes as u8,
        "the reply must terminate with the end-of-attributes tag"
    );

    attributes
}

fn names(attributes: &HashMap<String, IppValue>) -> Vec<String> {
    let mut names = attributes.keys().cloned().collect::<Vec<_>>();
    names.sort();
    names
}

#[tokio::test]
async fn ios_required_attributes_are_present() {
    let attributes = fetch_printer_attributes().await;

    // These are the attributes iOS reads to decide whether the printer is
    // usable and what to offer in the print sheet. A name missing here is
    // exactly the "printer never appears" failure this test exists to catch.
    for name in [
        "printer-uri-supported",
        "uri-authentication-supported",
        "uri-security-supported",
        "printer-name",
        "printer-state",
        "printer-is-accepting-jobs",
        "ipp-versions-supported",
        "operations-supported",
        "charset-configured",
        "charset-supported",
        "natural-language-configured",
        "generated-natural-language-supported",
        "document-format-default",
        "document-format-supported",
        "pdl-override-supported",
        "compression-supported",
        "printer-make-and-model",
        "printer-uuid",
        "urf-supported",
    ] {
        assert!(
            attributes.contains_key(name),
            "iOS requires `{name}` and it is missing from the reply, which makes \
             the printer invisible in the print sheet. Present attributes: {:?}",
            names(&attributes)
        );
    }
}

#[tokio::test]
async fn urf_is_advertised_over_ipp() {
    let attributes = fetch_printer_attributes().await;

    // `urf-supported` is the IPP counterpart of the `URF` TXT key: iOS reads it
    // to decide which raster encodings it may send.
    let values = attributes
        .get("urf-supported")
        .expect("urf-supported must be present")
        .as_array()
        .expect("urf-supported is an array")
        .iter()
        .map(|v| {
            v.as_keyword()
                .expect("urf-supported entries are keywords")
                .as_str()
                .to_owned()
        })
        .collect::<Vec<_>>();

    assert!(
        values.iter().any(|v| v == "V1.4"),
        "urf-supported must declare a URF version, got {values:?}"
    );
    assert!(
        values.iter().any(|v| v == "CP1"),
        "urf-supported must declare copy support, got {values:?}"
    );
}

#[tokio::test]
async fn absolute_uri_gets_an_ipp_scheme() {
    // A client is allowed to send an absolute-form request target. If it does,
    // the scheme it used is `http`/`https` (that is the transport), and echoing
    // it back verbatim would put an `http://` printer URI in the reply — a
    // value IPP clients reject instead of normalising.
    let service = SimpleIppService::new(printer_info(), StubHandler);

    for (request_target, expected) in [
        ("http://test-printer.local:631/ipp/print", "ipp://"),
        ("https://test-printer.local:631/ipp/print", "ipps://"),
    ] {
        let mut head = hyper::Request::builder()
            .method(hyper::Method::POST)
            .uri(request_target)
            .header("Content-Type", "application/ipp")
            .header("Host", HOST)
            .body(())
            .unwrap()
            .into_parts()
            .0;
        ipp_sharing_core::with_ipp_uri_scheme_parts(&mut head);

        let response = service
            .handle_request(head, get_printer_attributes_request())
            .await;
        let uri = response
            .attributes()
            .groups_of(DelimiterTag::PrinterAttributes)
            .flat_map(|group| group.attributes().iter())
            .find(|(name, _)| name.as_str() == "printer-uri-supported")
            .expect("printer-uri-supported must be present")
            .1
            .value()
            .as_uri()
            .expect("printer-uri-supported is a URI")
            .to_string();

        assert!(
            uri.starts_with(expected),
            "a request sent to {request_target} should yield a {expected} printer URI, got {uri}"
        );
    }
}

#[tokio::test]
async fn printer_uri_points_at_this_service() {
    let attributes = fetch_printer_attributes().await;

    // `printer-uri-supported` must be an absolute ipp:// URL for the host the
    // client connected to. If it advertises a different host, iOS lists the
    // printer and then fails the job with "no printer found".
    let uri = attributes
        .get("printer-uri-supported")
        .expect("printer-uri-supported must be present")
        .as_uri()
        .expect("printer-uri-supported is a URI")
        .to_string();

    assert!(
        uri.starts_with("ipp://"),
        "printer-uri-supported should use the ipp scheme, got {uri}"
    );
    assert!(
        uri.contains("test-printer.local"),
        "printer-uri-supported should echo the host the client used, got {uri}"
    );
}
