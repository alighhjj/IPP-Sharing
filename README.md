# IPP Sharing
IPP Sharing is a lightweight tool to share local Windows printers drivelessly via IPP protocol. While it is ideal for home users, it may not be as suitable for enterprise environments due to the absence of advanced features such as color management, custom paper sizes, user authentication, and audit logging.

This is a Windows-only tool, of course. For Linux and macOS users, CUPS (Common Unix Printing System) is recommended for IPP-based printer sharing, as it offers a more professional and feature-rich solution.

## Features
- **Lightweight and Easy to Use**: Designed for simplicity and quick setup.
- **Basic Print Ticket Support**: Includes standard media size, orientation, duplex printing, and color mode.
- **Apple AirPrint Compatibility**: Seamlessly integrates with Apple AirPrint for easy printing from Apple devices.
- **Driver-Free Client Setup**: No driver installation or PPD files required on the client side.
- **DNS-SD (Bonjour) Support**: Enables automatic service discovery for printers.
- **Two Frontends**: A tray-style GUI for everyday use and a CLI for scripting or headless setups.

## Installation

Grab the latest build from the [Releases page](https://github.com/ArcticLampyrid/ipp-sharing/releases).

| File | Description |
| --- | --- |
| `IPP-Sharing-<version>-x86_64-setup.exe` | Installer for 64-bit Windows (recommended). Adds Start Menu and optional desktop shortcuts, firewall rules, and an optional autostart entry. |
| `IPP-Sharing-<version>-x86_64.zip` | Portable bundle. Unzip anywhere and run — no installation, no registry writes. |
| `IPP-Sharing-<version>-x86-setup.exe` / `-x86.zip` | The same thing for 32-bit Windows. |

Both bundles contain:

- `ipp-sharing-gui.exe` — the graphical frontend.
- `ipp-sharing.exe` — the command-line frontend, useful for running as a service.
- `config.example.yaml` — a starting point for your `config.yaml`.
- `BUILD-INFO.txt` — the version and commit the bundle was built from.

Every release ships a `SHA256SUMS.txt`. Verify your download with:

```powershell
Get-FileHash .\IPP-Sharing-*-setup.exe -Algorithm SHA256
```

> [!NOTE]
> Installers are only Authenticode-signed when the signing secrets are present in the repository. If Windows SmartScreen warns about an unknown publisher, that is why — you can compare hashes against `SHA256SUMS.txt` instead.

### Prerequisites
Before using IPP Sharing, ensure the following requirements are met:
- **Operating System**: Windows 10 or later (required for Rust compatibility).
- **Apple Bonjour**: Required at runtime — see the note below. Download [Bonjour Print Services](https://support.apple.com/kb/DL999) (the `BonjourPSSetup.exe` installer), or install it with `winget install --id=Apple.BonjourPrintServices -e`. It also ships with [iTunes](https://support.apple.com/en-us/HT210384).

> [!IMPORTANT]
> Bonjour is **not optional**. The binaries import `dnssd.dll`, the Bonjour DNS-SD library, through a `raw-dylib` link. Windows resolves that import before the program starts, so without Bonjour installed **every** IPP Sharing command fails immediately with exit code `-1073741515` (`0xC0000135`, `STATUS_DLL_NOT_FOUND`) — even when `dnssd: false` disables service discovery, and even for `ipp-sharing --version`.
>
> The error is `The code execution cannot proceed because dnssd.dll was not found.` Because `dnssd.dll` ships with Bonjour and cannot be redistributed, it is not part of the portable bundle or the installer; Bonjour must be installed separately. The setup executable detects this and offers to download and install Bonjour for you; the portable zip does not, so unpack-and-run users must install it themselves.

### Step 1: Generate a Self-Signed Certificate
To enable TLS encryption, generate a self-signed certificate using `openssl`. Here’s an example command:

```shell
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out certificate.pem -days 365 -nodes
```

### Step 2: Download or Build the Binary
Download the prebuilt binary or compile it from the source. Place the binary in a directory and create a `config.yaml` file in the same folder. Below is an example configuration:

```yaml
server:
  addr:
    - "[::]:631"
    - "0.0.0.0:631"
  tls:
    # Specify the paths to your self-signed certificate and private key
    cert: "D:/ipp-sharing/certificate.pem"
    key: "D:/ipp-sharing/key.pem"
devices:
  - name: "Print To PDF (IppSharing)"
    info: "Print To PDF (IppSharing)"
    target: "Microsoft Print to PDF"
    # Generate a unique UUID for each printer
    uuid: "b27599fd-800c-409e-afe9-6dbbe11689ac"
    basepath: "/ipp/to_pdf"
    dnssd: true
```

> [!TIP]  
> The `uuid` field serves as a unique identifier for each printer. Generate a new UUID for every printer using [this UUID generator](https://www.uuidgenerator.net/).

### Step 3: Run the Tool
Execute the binary, and the printer should become available on any modern operating system that supports automatic printer discovery.

### Step 4: Configure Firewall (if applicable)
If a firewall is enabled, ensure that incoming connections are allowed on:
- **TCP Port 631** (for IPP)
- **UDP Port 5353** (for DNS-SD/Bonjour)

The installer can add these rules for you. For a manual install:

```powershell
netsh advfirewall firewall add rule name="IPP Sharing (IPP)" dir=in action=allow protocol=TCP localport=631
netsh advfirewall firewall add rule name="IPP Sharing (Bonjour)" dir=in action=allow protocol=UDP localport=5353
```

## Building from Source

```shell
cargo build --release
```

The workspace has three crates:

| Crate | Output | Purpose |
| --- | --- | --- |
| `core` | `ipp-sharing-core` | IPP service, print job handling, raster conversion |
| `cli` | `ipp-sharing.exe` | Command-line frontend |
| `gui` | `ipp-sharing-gui.exe` | egui/eframe desktop frontend |

`core` enables PDF printing via the `pdfium` feature by default, which statically links PDFium. Set `--no-default-features --features winpdf` to use the Windows built-in PDF renderer instead, which produces a much smaller binary at the cost of print fidelity.

## CI/CD

Every push and pull request runs [`.github/workflows/build.yml`](.github/workflows/build.yml), which lints (`rustfmt`, `clippy -D warnings`) and produces downloadable artifacts for both architectures.

Releases are cut by pushing a version tag, which triggers [`.github/workflows/release.yml`](.github/workflows/release.yml):

```shell
# 1. Bump `version` in cli/Cargo.toml, core/Cargo.toml and gui/Cargo.toml
# 2. Commit the change
# 3. Tag and push
git tag v0.1.0
git push origin v0.1.0
```

The pipeline then:

1. Fails fast if the tag does not match the crate versions, or if lint/format checks fail.
2. Builds `x86_64` and `x86` release binaries on `windows-latest` with statically linked CRT.
3. Packages a portable `.zip` and an Inno Setup `.exe` installer per architecture.
4. Publishes a GitHub Release with all assets plus `SHA256SUMS.txt`.

To re-run a release for an existing tag, use **Actions → Release → Run workflow**.

### Optional: code signing

Unsigned installers trigger SmartScreen warnings. To sign automatically, add these repository secrets — the installer step picks them up when present and is skipped otherwise:

| Secret | Meaning |
| --- | --- |
| `SIGNING_CERT_BASE64` | Base64-encoded `.pfx` code-signing certificate |
| `SIGNING_CERT_PASSWORD` | Password for the `.pfx` |

## Contributing

Contributions are welcome! Feel free to submit a pull request or open an issue if you encounter any problems.

## License
    Copyright (C) 2024-2025 alampy.com

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

This project is licensed under the AGPL-3.0 License. For more details, refer to the [LICENSE](LICENSE) file.

