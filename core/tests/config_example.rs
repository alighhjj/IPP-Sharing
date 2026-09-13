// Verifies that the shipped config.example.yaml stays in sync with the
// ConfigRoot deserializer. A config that ships broken is worse than no config.

#[test]
fn example_config_parses() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../config.example.yaml");
    let content = std::fs::read_to_string(path).expect("config.example.yaml must exist");
    let config: ipp_sharing_core::config::ConfigRoot =
        serde_yaml_ng::from_str(&content).expect("config.example.yaml must deserialize");
    assert!(
        !config.devices.is_empty(),
        "example config should define a device"
    );
    assert_eq!(config.devices[0].target, "Microsoft Print to PDF");
}
