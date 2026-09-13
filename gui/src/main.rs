#![windows_subsystem = "windows"]

use clap::Parser;
use eframe::egui::{self, vec2, Align, ViewportCommand};
use egui::RichText;
use egui::{Align2, UiBuilder};
use egui_tracing::tracing_subscriber;
use egui_tracing::tracing_subscriber::layer::SubscriberExt;
use egui_tracing::tracing_subscriber::util::SubscriberInitExt;
use ipp_sharing_core::config::read_config;
use ipp_sharing_core::ipp_sharing;
use log::{error, info};
use std::env;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

#[derive(Parser, Clone)]
#[command(version, about, long_about = None)]
struct Opts {
    #[arg(short, long)]
    config: Option<String>,
}

fn default_config_file_path() -> anyhow::Result<PathBuf> {
    let mut path = env::current_exe()?;
    path.pop();
    path.push("config.yaml");
    Ok(path)
}

async fn app_main() -> anyhow::Result<()> {
    let opts = match Opts::try_parse() {
        Ok(opts) => opts,
        Err(error) => {
            return Err(anyhow::anyhow!(
                "failed to parse command line arguments: {}",
                error
            ))
        }
    };
    let config_path = match opts.config {
        Some(path) => PathBuf::from_str(path.as_str())?,
        None => default_config_file_path()
            .map_err(|e| anyhow::anyhow!("failed to get default config file path: {}", e))?,
    };
    let config = read_config(config_path.as_path()).await.map_err(|e| {
        anyhow::anyhow!(
            "failed to read config file {}: {}",
            config_path.display(),
            e
        )
    })?;

    info!("Config File: {}", config_path.display());
    ipp_sharing(&config).await?;

    Ok(())
}

fn main() {
    let collector = egui_tracing::EventCollector::default()
        .with_max_events(Some(1000))
        .with_max_level(tracing::Level::INFO);
    tracing_subscriber::registry()
        .with(collector.clone())
        .init();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();

    runtime.spawn(async {
        if let Err(e) = app_main().await {
            // This used to be a bare `error!`, which made every startup failure
            // invisible: the GUI is built with `windows_subsystem = "windows"`,
            // so there is no console to print to, and the in-window log panel
            // dies with the process. Users saw only a window that appeared and
            // vanished. Surface the whole anyhow chain instead — the outer
            // message alone ("failed to read config file …") hides the actual
            // cause buried a few levels down.
            let chain = e
                .chain()
                .map(|cause| cause.to_string())
                .collect::<Vec<_>>()
                .join("\n  → ");
            error!("Application error: {chain}");
            show_fatal_error(&chain);
        }
    });
    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../../icons/app.png")).ok();
    let mut options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_decorations(true)
            .with_maximized(true)
            .with_close_button(false)
            .with_active(true)
            .with_icon(icon.unwrap_or_default()),

        ..Default::default()
    };
    options.wgpu_options.wgpu_setup = preferred_wgpu_setup();
    eframe::run_native(
        "IPP Sharing",
        options,
        Box::new(|cc| {
            cc.egui_ctx.set_theme(egui::Theme::Dark);
            setup_fonts(&cc.egui_ctx);
            Ok(Box::new(MyApp::new(collector)))
        }),
    )
    .unwrap();

    runtime.shutdown_timeout(Duration::from_secs(1));
}

/// Shows a modal message box carrying a startup error.
///
/// Declared by hand rather than pulling in the `windows` crate: this is the only
/// Win32 call in the GUI crate, and `user32.dll` is loaded by every Windows GUI
/// process anyway, so a dependency would be all cost and no benefit.
///
/// Deliberately blocking. A startup failure means the background task that keeps
/// the process alive has already returned, so the message box must be shown
/// before `main` unwinds — otherwise the window would disappear before the user
/// could read anything.
fn show_fatal_error(message: &str) {
    // Not `MB_ICONERROR` alone: this fires when there is no usable renderer, and
    // on those machines the dialog is the only thing that will ever appear.
    const MB_OK: u32 = 0x0000_0000;
    const MB_ICONERROR: u32 = 0x0000_0010;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;
    const MB_TOPMOST: u32 = 0x0004_0000;

    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut core::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    let text = wide(&format!(
        "IPP Sharing could not start.\n\n{message}\n\n\
         If the window flashed and closed with no message, the graphics driver \
         may be too old; see the README for the WGPU_BACKEND workaround."
    ));
    let caption = wide("IPP Sharing");

    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            caption.as_ptr(),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST,
        );
    }
}

/// Builds the wgpu setup, avoiding the OpenGL backend unless the user asks for
/// it.
///
/// Why this is not the default: eframe ships `Backends::PRIMARY | Backends::GL`
/// out of the box, and on Intel's legacy Windows GL driver (Ivy Bridge and
/// earlier, driver 10.18.x) that GL backend does not merely lose a frame — wgpu
/// reports `Instance::new: failed to create Vulkan backend` and then dies with
/// "Handling wgpu errors as fatal by default". Because wgpu treats that class of
/// error as fatal, the process is terminated, so the user sees the window flash
/// and vanish with nothing on screen and nothing in any log.
///
/// Measured on an Intel HD Graphics 2500 (`10.18.10.4252`, OpenGL 4.0): the
/// default backend set crashed on the first frame, forcing `WGPU_BACKEND=dx12`
/// made it work with a software-rasterizer warning. DX12 has been part of
/// `Backends::PRIMARY` since Windows 10, so we simply exclude GL and keep DX12
/// and Vulkan in play.
///
/// `WGPU_BACKEND` still wins when it is set, so anyone who actually needs GL
/// (a machine where DX12 is the broken one) can restore it with
/// `set WGPU_BACKEND=gl`.
fn preferred_wgpu_setup() -> egui_wgpu::WgpuSetup {
    // `without_display_handle()` yields the normal eframe defaults, including
    // `wgpu::Backends::from_env().unwrap_or(PRIMARY | GL)`. Keep every field
    // except `backends` so we do not silently drop future upstream changes.
    let mut setup = egui_wgpu::WgpuSetup::without_display_handle();

    if std::env::var_os("WGPU_BACKEND").is_none() {
        if let egui_wgpu::WgpuSetup::CreateNew(create_new) = &mut setup {
            create_new.instance_descriptor.backends = wgpu::Backends::PRIMARY;
        }
    }

    setup
}

fn setup_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert(
        "MiSans".to_owned(),
        Arc::new(egui::FontData::from_static(include_bytes!(
            "../../fonts/MiSans-Regular.ttf"
        ))),
    );
    fonts
        .families
        .get_mut(&egui::FontFamily::Proportional)
        .unwrap()
        .insert(0, "MiSans".to_owned());
    fonts
        .families
        .get_mut(&egui::FontFamily::Monospace)
        .unwrap()
        .push("MiSans".to_owned());
    ctx.set_fonts(fonts);
}

struct MyApp {
    close_confirm_open: bool,
    start_time: std::time::Instant,
    collector: egui_tracing::EventCollector,
}

impl MyApp {
    fn new(collector: egui_tracing::EventCollector) -> Self {
        Self {
            close_confirm_open: false,
            start_time: std::time::Instant::now(),
            collector,
        }
    }
}

impl eframe::App for MyApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        ui.request_repaint_after(Duration::from_secs(1));
        egui::CentralPanel::default().show_inside(ui, |ui| {
            let app_rect = ui.max_rect();
            let heading_rect = {
                let mut rect = app_rect;
                rect.max.y = rect.min.y + 28.0;
                rect
            };
            ui.scope_builder(
                UiBuilder::new()
                    .max_rect(heading_rect)
                    .layout(egui::Layout::left_to_right(egui::Align::Max)),
                |ui| {
                    ui.spacing_mut().item_spacing.x = 0.0;
                    ui.heading(format!("IPP Sharing {}", env!("CARGO_PKG_VERSION")));
                    ui.add_space(8.0);
                    ui.label(format!(
                        "Uptime: {}",
                        humantime::format_duration(Duration::from_secs(
                            self.start_time.elapsed().as_secs()
                        ))
                    ));
                    ui.label(" | ");
                    ui.label("License: AGPLv3");
                    ui.label(" | ");
                    ui.hyperlink_to(
                        "Source Code",
                        "https://github.com/ArcticLampyrid/ipp-sharing",
                    );
                    ui.label(" | ");
                    ui.hyperlink_to("Sponsor", "https://afdian.com/a/alampy");
                },
            );
            ui.scope_builder(
                UiBuilder::new()
                    .max_rect(heading_rect)
                    .layout(egui::Layout::right_to_left(egui::Align::Max)),
                |ui| {
                    ui.spacing_mut().item_spacing.x = 0.0;

                    if ui.button(RichText::new("Exit").size(20.0)).clicked() {
                        self.close_confirm_open = true;
                    }
                },
            );
            egui::Window::new("Close Confirmation")
                .open(&mut self.close_confirm_open)
                .collapsible(false)
                .fixed_size(vec2(300.0, 100.0))
                .anchor(Align2::CENTER_CENTER, vec2(0.0, 0.0))
                .show(ui, |ui| {
                    ui.label("Are you sure you want to close?");
                    ui.with_layout(egui::Layout::right_to_left(Align::Min), |ui| {
                        if ui.button("Confirm").clicked() {
                            ui.ctx().send_viewport_cmd(ViewportCommand::Close);
                        }
                    });
                });
            ui.add(egui_tracing::Logs::new(self.collector.clone()));
        });
    }
}
