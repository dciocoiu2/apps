param([string]$Root="netos")

# Define all directories we want to create
$dirs = @(
  "assets/icons",
  "assets/styles",
  "configs/examples",
  "src/app",
  "src/gui",
  "src/cli",
  "src/orchestrator",
  "src/hardware",
  "src/plumbing",
  "src/mgmt",
  "src/shared",
  "src/devices/router_os",
  "src/devices/switch_os",
  "src/devices/lb_os",
  "src/devices/firewall_os",
  "src/api",
  "src/topology",
  "src/security",
  "src/utils",
  "src/tests"
)

# Create the root directory
New-Item -ItemType Directory -Force -Path $Root | Out-Null

# Create each subdirectory
foreach ($d in $dirs) {
  New-Item -ItemType Directory -Force -Path "$Root/$d" | Out-Null
}

Write-Host "Batch 1/11 Directory structure created under $Root"
param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# Ensure root exists
if(!(Test-Path $Root)){New-Item -ItemType Directory -Force -Path $Root | Out-Null}

# Cargo.toml
W "$Root/Cargo.toml" @"
[package]
name = "netos"
version = "0.1.0"
edition = "2021"
license = "Apache-2.0"
description = "Cross-platform single-binary Rust networking platform with GUI, orchestration, devices, transactional config, RBAC, audit, and observability."

[dependencies]
# CLI & runtime
clap = { version = "4", features = ["derive"] }
anyhow = "1"
thiserror = "1"
tokio = { version = "1", features = ["rt-multi-thread","macros","net","signal","time"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["fmt","env-filter"] }
parking_lot = "0.12"
dashmap = "5"

# GUI
egui = "0.27"
eframe = { version = "0.27", features = ["wgpu"] }

# Serialization & config
serde = { version = "1", features = ["derive"] }
serde_json = "1"
serde_yaml = "0.9"

# Networking & HTTP API
hyper = { version = "0.14", features = ["full"] }
bytes = "1"
url = "2"

# TLS for LB
rustls = "0.23"
tokio-rustls = "0.25"
rcgen = "0.12"

# System info & hardware inventory
sysinfo = "0.30"
if-addrs = "0.7"
num_cpus = "1"
nix = "0.29"

# Observability
prometheus = "0.13"
opentelemetry = "0.23"
opentelemetry-otlp = "0.16"

# Misc
uuid = "1"
regex = "1"

[profile.release]
lto = "thin"
codegen-units = 1
opt-level = "z"
"@

# README.md
W "$Root/README.md" @"
# netos

Cross-platform, single-binary Rust networking platform with a VirtualBox-style GUI, device OSes (router/switch/firewall/load balancer), orchestration, transactional config, RBAC, audit, and observability.

## Features
- GUI with topology editor, device manager, console, metrics, snapshots.
- Orchestrator: Linux netns/veth/macvlan (SR-IOV), macOS utun, Windows Wintun/Npcap.
- Router OS: BGP, OSPFv2/v3, IS-IS, RIP, PIM, MPLS LDP/RSVP-TE, Segment Routing, VRF/VRRP.
- Switch OS: VLAN/QinQ, MAC learning, STP/RSTP/MSTP, LACP, LLDP, IGMP/MLD snooping, EVPN/VXLAN IRB.
- Load Balancer OS: L4 TCP/UDP, L7 HTTP reverse proxy, TLS termination, health checks, schedulers.
- Firewall OS: ACL engine, WAF rules/signatures.
- Config: transactional apply, validation, diff, rollback; RBAC; audit; Prometheus metrics; tracing.

## Build and Run
- Ensure Rust toolchain is installed (see SETUP_INSTRUCTIONS.txt).
- Build: `cargo build --release`
- Run GUI: `cargo run`
- Run CLI: `cargo run -- --nogui <subcommand>`

## Structure
See src/ for modules: app, gui, cli, orchestrator, hardware, plumbing, mgmt, shared, devices, api, topology, security, utils, tests.
"@

# LICENSE (Apache-2.0)
W "$Root/LICENSE" @"
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

Copyright (c) 2025 netos contributors

Licensed under the Apache License, Version 2.0 (the ""License"");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an ""AS IS"" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"@

# Makefile
W "$Root/Makefile" @"
.PHONY: all build run clean fmt clippy release

all: build

build:
	cargo build

run:
	cargo run

release:
	cargo build --release

fmt:
	cargo fmt

clippy:
	cargo clippy -- -D warnings

clean:
	cargo clean
"@

# SETUP_INSTRUCTIONS.txt
W "$Root/SETUP_INSTRUCTIONS.txt" @"
Environment setup for netos (Rust single-binary, cross-platform)

Windows (PowerShell):
1. Install PowerShell 7 (optional but recommended).
2. Install Rust: https://www.rust-lang.org/tools/install (rustup-init.exe)
3. Install build tools:
   - Winget: `winget install Git.Git`
   - LLVM: `winget install LLVM.LLVM`
   - CMake: `winget install Kitware.CMake`
4. Verify: `rustc --version`, `cargo --version`
5. Build: `cargo build --release`
6. Run GUI: `cargo run`
7. Run CLI: `cargo run -- --nogui <subcommand>`

macOS:
1. Install Homebrew: /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
2. Install tools: `brew install rustup-init git llvm cmake pkg-config`
3. Initialize Rust: `rustup-init -y`
4. Add targets (optional for Apple Silicon/Intel): 
   - `rustup target add x86_64-apple-darwin aarch64-apple-darwin`
5. Build: `cargo build --release`
6. Run: `cargo run`

Debian/Ubuntu:
1. `sudo apt update`
2. `sudo apt install -y build-essential git cmake pkg-config libssl-dev`
3. Install Rust: `curl https://sh.rustup.rs -sSf | sh -s -- -y`
4. Source Cargo env: `source $HOME/.cargo/env`
5. Optional cross targets: 
   - `rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu`
6. Build: `cargo build --release`
7. Run: `cargo run`

RHEL/CentOS/Fedora:
1. `sudo dnf groupinstall -y "Development Tools"`
2. `sudo dnf install -y git cmake pkgconf-pkg-config openssl-devel`
3. Install Rust: `curl https://sh.rustup.rs -sSf | sh -s -- -y`
4. Source Cargo env: `source $HOME/.cargo/env`
5. Optional targets:
   - `rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu`
6. Build: `cargo build --release`
7. Run: `cargo run`

Notes:
- netos is a single binary providing GUI and CLI modes; use `--nogui` for headless CLI.
- Linux networking features (netns, veth, macvlan, SR-IOV) require root privileges and supported hardware.
- Ensure you have appropriate permissions for macOS utun and Windows Wintun/Npcap adapters.
"@

Write-Host "Batch 2/11 complete: top-level files created under $Root"
param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# main.rs
W "$Root/src/main.rs" @"
mod app;
mod gui;
mod cli;
mod orchestrator;
mod hardware;
mod plumbing;
mod mgmt;
mod shared;
mod devices;
mod api;
mod topology;
mod security;
mod utils;

use clap::Parser;
use tracing_subscriber;

#[derive(Parser, Debug)]
#[command(name = "netos", about = "Cross-platform Rust networking OS")]
struct Args {
    /// Run without GUI
    #[arg(long)]
    nogui: bool,
    #[arg(last = true)]
    cli_args: Vec<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("info")
        .init();

    let args = Args::parse();

    if args.nogui {
        cli::run(args.cli_args).await?;
    } else {
        gui::run().await?;
    }

    Ok(())
}
"@

# src/app/mod.rs
W "$Root/src/app/mod.rs" @"
pub mod runtime;
pub mod state;
pub mod events;

pub use runtime::AppRuntime;
pub use state::AppState;
pub use events::{AppEvent, EventBus};
"@

# src/app/runtime.rs
W "$Root/src/app/runtime.rs" @"
use crate::app::{AppState, EventBus};
use crate::mgmt::cfg_store::ConfigStore;
use crate::hardware::inventory::Inventory;
use std::sync::Arc;
use parking_lot::RwLock;

pub struct AppRuntime {
    pub state: Arc<RwLock<AppState>>,
    pub events: EventBus,
    pub cfg: ConfigStore,
    pub inventory: Inventory,
}

impl AppRuntime {
    pub fn new() -> anyhow::Result<Self> {
        let inventory = Inventory::detect()?;
        let state = Arc::new(RwLock::new(AppState::default()));
        let events = EventBus::new();
        let cfg = ConfigStore::new();

        Ok(Self { state, events, cfg, inventory })
    }
}
"@

# src/app/state.rs
W "$Root/src/app/state.rs" @"
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct DeviceInfo {
    pub id: String,
    pub kind: String,
    pub running: bool,
}

#[derive(Debug, Default)]
pub struct AppState {
    pub devices: HashMap<String, DeviceInfo>,
    pub links: Vec<(String, String)>,
}
"@

# src/app/events.rs
W "$Root/src/app/events.rs" @"
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub enum AppEvent {
    DeviceStarted(String),
    DeviceStopped(String),
    LinkUp(String, String),
    LinkDown(String, String),
}

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<AppEvent>,
}

impl EventBus {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(1024);
        Self { tx }
    }

    pub fn publish(&self, ev: AppEvent) {
        let _ = self.tx.send(ev);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppEvent> {
        self.tx.subscribe()
    }
}
"@

Write-Host "Batch 3/11 complete: core application files created under $Root/src/app"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/gui/mod.rs
W "$Root/src/gui/mod.rs" @"
pub mod window;
pub mod topology_editor;
pub mod device_manager;
pub mod metrics_panel;
pub mod logs_view;
pub mod console;
pub mod snapshots;
pub mod settings;

pub async fn run() -> anyhow::Result<()> {
    let native_options = eframe::NativeOptions::default();
    eframe::run_native(
        "netos",
        native_options,
        Box::new(|cc| Box::new(window::NetOsApp::new(cc))),
    );
    Ok(())
}
"@

# src/gui/window.rs
W "$Root/src/gui/window.rs" @"
use eframe::egui;
use crate::gui::{topology_editor::TopologyEditor, device_manager::DeviceManager,
                 metrics_panel::MetricsPanel, logs_view::LogsView,
                 console::ConsoleView, snapshots::SnapshotsView, settings::SettingsView};

pub struct NetOsApp {
    topology: TopologyEditor,
    devices: DeviceManager,
    metrics: MetricsPanel,
    logs: LogsView,
    console: ConsoleView,
    snapshots: SnapshotsView,
    settings: SettingsView,
}

impl NetOsApp {
    pub fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        Self {
            topology: TopologyEditor::default(),
            devices: DeviceManager::default(),
            metrics: MetricsPanel::default(),
            logs: LogsView::default(),
            console: ConsoleView::default(),
            snapshots: SnapshotsView::default(),
            settings: SettingsView::default(),
        }
    }
}

impl eframe::App for NetOsApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("menu").show(ctx, |ui| {
            ui.heading("netos");
            if ui.button("Settings").clicked() {
                self.settings.open = true;
            }
        });

        egui::SidePanel::left("devices").show(ctx, |ui| {
            self.devices.ui(ui);
        });

        egui::SidePanel::right("metrics").show(ctx, |ui| {
            self.metrics.ui(ui);
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            self.topology.ui(ui);
        });

        egui::Window::new("Logs").open(&mut self.logs.open).show(ctx, |ui| {
            self.logs.ui(ui);
        });

        egui::Window::new("Console").open(&mut self.console.open).show(ctx, |ui| {
            self.console.ui(ui);
        });

        egui::Window::new("Snapshots").open(&mut self.snapshots.open).show(ctx, |ui| {
            self.snapshots.ui(ui);
        });

        egui::Window::new("Settings").open(&mut self.settings.open).show(ctx, |ui| {
            self.settings.ui(ui);
        });
    }
}
"@

# src/gui/topology_editor.rs
W "$Root/src/gui/topology_editor.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct TopologyEditor {}

impl TopologyEditor {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.label(\"Topology editor canvas (drag-and-drop devices, draw links)\");
        ui.separator();
        ui.label(\"[Future: interactive graph with devices and links]\");
    }
}
"@

# src/gui/device_manager.rs
W "$Root/src/gui/device_manager.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct DeviceManager {}

impl DeviceManager {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Devices\");
        if ui.button(\"Add Router\").clicked() {
            // TODO: integrate with orchestrator
        }
        if ui.button(\"Add Switch\").clicked() {}
        if ui.button(\"Add Firewall\").clicked() {}
        if ui.button(\"Add Load Balancer\").clicked() {}
    }
}
"@

# src/gui/metrics_panel.rs
W "$Root/src/gui/metrics_panel.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct MetricsPanel {}

impl MetricsPanel {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Metrics\");
        ui.label(\"CPU: 0% | RAM: 0MB | NIC: 0pps\");
    }
}
"@

# src/gui/logs_view.rs
W "$Root/src/gui/logs_view.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct LogsView {
    pub open: bool,
}

impl LogsView {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Logs\");
        ui.label(\"[Future: structured logs here]\");
    }
}
"@

# src/gui/console.rs
W "$Root/src/gui/console.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct ConsoleView {
    pub open: bool,
}

impl ConsoleView {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Console\");
        ui.label(\"[Future: interactive CLI shell]\");
    }
}
"@

# src/gui/snapshots.rs
W "$Root/src/gui/snapshots.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct SnapshotsView {
    pub open: bool,
}

impl SnapshotsView {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Snapshots\");
        if ui.button(\"Save Snapshot\").clicked() {}
        if ui.button(\"Restore Snapshot\").clicked() {}
    }
}
"@

# src/gui/settings.rs
W "$Root/src/gui/settings.rs" @"
use eframe::egui;

#[derive(Default)]
pub struct SettingsView {
    pub open: bool,
}

impl SettingsView {
    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.heading(\"Settings\");
        ui.label(\"[Future: preferences and overrides]\");
    }
}
"@

Write-Host "Batch 4/11 complete: GUI subsystem created under $Root/src/gui"
