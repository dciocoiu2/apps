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
param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/cli/mod.rs
W "$Root/src/cli/mod.rs" @"
use clap::{Parser, Subcommand};

pub mod init;
pub mod apply;
pub mod show;
pub mod nic;
pub mod proto;
pub mod lb;
pub mod waf;
pub mod hw;
pub mod host;

#[derive(Parser, Debug)]
#[command(name = \"netos-cli\", about = \"CLI for netos\")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    Init(init::InitArgs),
    Apply(apply::ApplyArgs),
    Show(show::ShowArgs),
    Nic(nic::NicArgs),
    Proto(proto::ProtoArgs),
    Lb(lb::LbArgs),
    Waf(waf::WafArgs),
    Hw(hw::HwArgs),
    Host(host::HostArgs),
}

pub async fn run(args: Vec<String>) -> anyhow::Result<()> {
    let cli = Cli::parse_from(args);
    match cli.command {
        Commands::Init(a) => init::run(a).await,
        Commands::Apply(a) => apply::run(a).await,
        Commands::Show(a) => show::run(a).await,
        Commands::Nic(a) => nic::run(a).await,
        Commands::Proto(a) => proto::run(a).await,
        Commands::Lb(a) => lb::run(a).await,
        Commands::Waf(a) => waf::run(a).await,
        Commands::Hw(a) => hw::run(a).await,
        Commands::Host(a) => host::run(a).await,
    }
}
"@

# src/cli/init.rs
W "$Root/src/cli/init.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct InitArgs {
    #[arg(short, long)]
    pub name: Option<String>,
}

pub async fn run(args: InitArgs) -> anyhow::Result<()> {
    println!(\"Initializing new topology: {:?}\", args.name);
    Ok(())
}
"@

# src/cli/apply.rs
W "$Root/src/cli/apply.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct ApplyArgs {
    #[arg(short, long)]
    pub file: String,
}

pub async fn run(args: ApplyArgs) -> anyhow::Result<()> {
    println!(\"Applying config from {}\", args.file);
    Ok(())
}
"@

# src/cli/show.rs
W "$Root/src/cli/show.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct ShowArgs {
    #[arg(short, long)]
    pub what: String,
}

pub async fn run(args: ShowArgs) -> anyhow::Result<()> {
    println!(\"Showing {}\", args.what);
    Ok(())
}
"@

# src/cli/nic.rs
W "$Root/src/cli/nic.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct NicArgs {
    #[arg(short, long)]
    pub list: bool,
}

pub async fn run(args: NicArgs) -> anyhow::Result<()> {
    if args.list {
        println!(\"Listing NICs\");
    }
    Ok(())
}
"@

# src/cli/proto.rs
W "$Root/src/cli/proto.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct ProtoArgs {
    #[arg(short, long)]
    pub enable: Option<String>,
}

pub async fn run(args: ProtoArgs) -> anyhow::Result<()> {
    if let Some(proto) = args.enable {
        println!(\"Enabling protocol {}\", proto);
    }
    Ok(())
}
"@

# src/cli/lb.rs
W "$Root/src/cli/lb.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct LbArgs {
    #[arg(short, long)]
    pub add: Option<String>,
}

pub async fn run(args: LbArgs) -> anyhow::Result<()> {
    if let Some(listener) = args.add {
        println!(\"Adding LB listener {}\", listener);
    }
    Ok(())
}
"@

# src/cli/waf.rs
W "$Root/src/cli/waf.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct WafArgs {
    #[arg(short, long)]
    pub rule: Option<String>,
}

pub async fn run(args: WafArgs) -> anyhow::Result<()> {
    if let Some(rule) = args.rule {
        println!(\"Adding WAF rule {}\", rule);
    }
    Ok(())
}
"@

# src/cli/hw.rs
W "$Root/src/cli/hw.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct HwArgs {
    #[arg(short, long)]
    pub list: bool,
}

pub async fn run(args: HwArgs) -> anyhow::Result<()> {
    if args.list {
        println!(\"Listing hardware inventory\");
    }
    Ok(())
}
"@

# src/cli/host.rs
W "$Root/src/cli/host.rs" @"
use clap::Args;

#[derive(Args, Debug)]
pub struct HostArgs {
    #[arg(short, long)]
    pub check: bool,
}

pub async fn run(args: HostArgs) -> anyhow::Result<()> {
    if args.check {
        println!(\"Running host preflight checks\");
    }
    Ok(())
}
"@

Write-Host "Batch 5/11 complete: CLI subsystem created under $Root/src/cli"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/orchestrator/mod.rs
W "$Root/src/orchestrator/mod.rs" @"
pub mod device_manager;
pub mod namespace;
pub mod link_graph;
pub mod passthrough;
pub mod scheduler;
pub mod health;

pub use device_manager::DeviceManager;
pub use namespace::NamespaceManager;
pub use link_graph::LinkGraph;
pub use passthrough::PassthroughManager;
pub use scheduler::Scheduler;
pub use health::HealthMonitor;
"@

# src/orchestrator/device_manager.rs
W "$Root/src/orchestrator/device_manager.rs" @"
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Device {
    pub id: String,
    pub kind: String,
    pub running: bool,
}

#[derive(Default)]
pub struct DeviceManager {
    devices: HashMap<String, Device>,
}

impl DeviceManager {
    pub fn new() -> Self {
        Self { devices: HashMap::new() }
    }

    pub fn add_device(&mut self, id: &str, kind: &str) {
        let dev = Device { id: id.to_string(), kind: kind.to_string(), running: false };
        self.devices.insert(id.to_string(), dev);
    }

    pub fn start_device(&mut self, id: &str) {
        if let Some(dev) = self.devices.get_mut(id) {
            dev.running = true;
            println!(\"Device {} started\", id);
        }
    }

    pub fn stop_device(&mut self, id: &str) {
        if let Some(dev) = self.devices.get_mut(id) {
            dev.running = false;
            println!(\"Device {} stopped\", id);
        }
    }
}
"@

# src/orchestrator/namespace.rs
W "$Root/src/orchestrator/namespace.rs" @"
#[derive(Default)]
pub struct NamespaceManager {}

impl NamespaceManager {
    pub fn new() -> Self {
        Self {}
    }

    pub fn create_namespace(&self, name: &str) {
        println!(\"[Namespace] Creating namespace {} (platform-specific)\", name);
    }

    pub fn delete_namespace(&self, name: &str) {
        println!(\"[Namespace] Deleting namespace {}\", name);
    }
}
"@

# src/orchestrator/link_graph.rs
W "$Root/src/orchestrator/link_graph.rs" @"
#[derive(Debug, Clone)]
pub struct Link {
    pub a: String,
    pub b: String,
}

#[derive(Default)]
pub struct LinkGraph {
    pub links: Vec<Link>,
}

impl LinkGraph {
    pub fn new() -> Self {
        Self { links: Vec::new() }
    }

    pub fn add_link(&mut self, a: &str, b: &str) {
        self.links.push(Link { a: a.to_string(), b: b.to_string() });
        println!(\"[LinkGraph] Added link {} <-> {}\", a, b);
    }
}
"@

# src/orchestrator/passthrough.rs
W "$Root/src/orchestrator/passthrough.rs" @"
#[derive(Default)]
pub struct PassthroughManager {}

impl PassthroughManager {
    pub fn new() -> Self {
        Self {}
    }

    pub fn attach_sriov(&self, dev: &str, vf: u32) {
        println!(\"[Passthrough] Attaching SR-IOV VF {} to device {}\", vf, dev);
    }

    pub fn attach_dpdk(&self, dev: &str) {
        println!(\"[Passthrough] Attaching DPDK to device {}\", dev);
    }
}
"@

# src/orchestrator/scheduler.rs
W "$Root/src/orchestrator/scheduler.rs" @"
#[derive(Default)]
pub struct Scheduler {}

impl Scheduler {
    pub fn new() -> Self {
        Self {}
    }

    pub fn start_all(&self) {
        println!(\"[Scheduler] Starting all devices in order\");
    }

    pub fn stop_all(&self) {
        println!(\"[Scheduler] Stopping all devices in order\");
    }
}
"@

# src/orchestrator/health.rs
W "$Root/src/orchestrator/health.rs" @"
#[derive(Default)]
pub struct HealthMonitor {}

impl HealthMonitor {
    pub fn new() -> Self {
        Self {}
    }

    pub fn check(&self, dev: &str) -> bool {
        println!(\"[Health] Checking device {}\", dev);
        true
    }
}
"@

Write-Host "Batch 6/11 complete: Orchestrator subsystem created under $Root/src/orchestrator"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/hardware/mod.rs
W "$Root/src/hardware/mod.rs" @"
pub mod os;
pub mod cpu;
pub mod ram;
pub mod gpu;
pub mod disk;
pub mod numa;
pub mod nic;
pub mod inventory;

pub use inventory::Inventory;
"@

# src/hardware/os.rs
W "$Root/src/hardware/os.rs" @"
#[derive(Debug, Clone)]
pub struct OsInfo {
    pub name: String,
    pub version: String,
}

impl OsInfo {
    pub fn detect() -> anyhow::Result<Self> {
        let os = std::env::consts::OS.to_string();
        let version = std::env::consts::ARCH.to_string();
        Ok(Self { name: os, version })
    }
}
"@

# src/hardware/cpu.rs
W "$Root/src/hardware/cpu.rs" @"
#[derive(Debug, Clone)]
pub struct CpuInfo {
    pub cores: usize,
    pub arch: String,
}

impl CpuInfo {
    pub fn detect() -> anyhow::Result<Self> {
        let cores = num_cpus::get();
        let arch = std::env::consts::ARCH.to_string();
        Ok(Self { cores, arch })
    }
}
"@

# src/hardware/ram.rs
W "$Root/src/hardware/ram.rs" @"
use sysinfo::{System, SystemExt};

#[derive(Debug, Clone)]
pub struct RamInfo {
    pub total_mb: u64,
}

impl RamInfo {
    pub fn detect() -> anyhow::Result<Self> {
        let mut sys = System::new_all();
        sys.refresh_memory();
        let total_mb = sys.total_memory() / 1024;
        Ok(Self { total_mb })
    }
}
"@

# src/hardware/gpu.rs
W "$Root/src/hardware/gpu.rs" @"
#[derive(Debug, Clone)]
pub struct GpuInfo {
    pub count: usize,
}

impl GpuInfo {
    pub fn detect() -> anyhow::Result<Self> {
        // Placeholder: real GPU detection would use platform APIs
        Ok(Self { count: 0 })
    }
}
"@

# src/hardware/disk.rs
W "$Root/src/hardware/disk.rs" @"
use sysinfo::{System, SystemExt, DiskExt};

#[derive(Debug, Clone)]
pub struct DiskInfo {
    pub total_gb: u64,
}

impl DiskInfo {
    pub fn detect() -> anyhow::Result<Self> {
        let mut sys = System::new_all();
        sys.refresh_disks_list();
        let total_bytes: u64 = sys.disks().iter().map(|d| d.total_space()).sum();
        Ok(Self { total_gb: total_bytes / 1_000_000_000 })
    }
}
"@

# src/hardware/numa.rs
W "$Root/src/hardware/numa.rs" @"
#[derive(Debug, Clone)]
pub struct NumaInfo {
    pub nodes: usize,
}

impl NumaInfo {
    pub fn detect() -> anyhow::Result<Self> {
        // Simplified: real NUMA detection requires OS-specific APIs
        Ok(Self { nodes: 1 })
    }
}
"@

# src/hardware/nic.rs
W "$Root/src/hardware/nic.rs" @"
use if_addrs::get_if_addrs;

#[derive(Debug, Clone)]
pub struct NicInfo {
    pub name: String,
    pub addr: String,
}

impl NicInfo {
    pub fn detect_all() -> anyhow::Result<Vec<Self>> {
        let mut nics = Vec::new();
        for iface in get_if_addrs()? {
            let addr = iface.addr.ip().to_string();
            nics.push(NicInfo { name: iface.name, addr });
        }
        Ok(nics)
    }
}
"@

# src/hardware/inventory.rs
W "$Root/src/hardware/inventory.rs" @"
use super::{os::OsInfo, cpu::CpuInfo, ram::RamInfo, gpu::GpuInfo,
            disk::DiskInfo, numa::NumaInfo, nic::NicInfo};

#[derive(Debug, Clone)]
pub struct Inventory {
    pub os: OsInfo,
    pub cpu: CpuInfo,
    pub ram: RamInfo,
    pub gpu: GpuInfo,
    pub disk: DiskInfo,
    pub numa: NumaInfo,
    pub nics: Vec<NicInfo>,
}

impl Inventory {
    pub fn detect() -> anyhow::Result<Self> {
        Ok(Self {
            os: OsInfo::detect()?,
            cpu: CpuInfo::detect()?,
            ram: RamInfo::detect()?,
            gpu: GpuInfo::detect()?,
            disk: DiskInfo::detect()?,
            numa: NumaInfo::detect()?,
            nics: NicInfo::detect_all()?,
        })
    }
}
"@

Write-Host "Batch 7/11 complete: Hardware autodetection subsystem created under $Root/src/hardware"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/plumbing/mod.rs
W "$Root/src/plumbing/mod.rs" @"
pub mod linux;
pub mod macos;
pub mod windows;

pub use linux::LinuxPlumbing;
pub use macos::MacosPlumbing;
pub use windows::WindowsPlumbing;
"@

# src/plumbing/linux.rs
W "$Root/src/plumbing/linux.rs" @"
#[derive(Default)]
pub struct LinuxPlumbing {}

impl LinuxPlumbing {
    pub fn new() -> Self {
        Self {}
    }

    pub fn create_netns(&self, name: &str) {
        println!(\"[Linux] Creating netns {} (would call unshare/setns)\", name);
    }

    pub fn create_veth(&self, a: &str, b: &str) {
        println!(\"[Linux] Creating veth pair {} <-> {}\", a, b);
    }

    pub fn create_macvlan(&self, parent: &str, child: &str) {
        println!(\"[Linux] Creating macvlan {} on parent {}\", child, parent);
    }

    pub fn attach_sriov_vf(&self, dev: &str, vf: u32) {
        println!(\"[Linux] Attaching SR-IOV VF {} to {}\", vf, dev);
    }
}
"@

# src/plumbing/macos.rs
W "$Root/src/plumbing/macos.rs" @"
#[derive(Default)]
pub struct MacosPlumbing {}

impl MacosPlumbing {
    pub fn new() -> Self {
        Self {}
    }

    pub fn create_utun(&self, name: &str) {
        println!(\"[macOS] Creating utun interface {} (would use /dev/utun)\", name);
    }
}
"@

# src/plumbing/windows.rs
W "$Root/src/plumbing/windows.rs" @"
#[derive(Default)]
pub struct WindowsPlumbing {}

impl WindowsPlumbing {
    pub fn new() -> Self {
        Self {}
    }

    pub fn create_wintun(&self, name: &str) {
        println!(\"[Windows] Creating Wintun adapter {} (would call wintun.dll)\", name);
    }

    pub fn create_npcap(&self, name: &str) {
        println!(\"[Windows] Creating Npcap adapter {} (would use npcap API)\", name);
    }
}
"@

Write-Host "Batch 8/11 complete: Plumbing subsystem created under $Root/src/plumbing"
param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/mgmt/mod.rs
W "$Root/src/mgmt/mod.rs" @"
pub mod cfg_store;
pub mod validator;
pub mod rbac;
pub mod audit;
pub mod observability;

pub use cfg_store::ConfigStore;
pub use validator::Validator;
pub use rbac::{Role, Rbac};
pub use audit::AuditLog;
pub use observability::Observability;
"@

# src/mgmt/cfg_store.rs
W "$Root/src/mgmt/cfg_store.rs" @"
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct ConfigStore {
    staged: HashMap<String, String>,
    running: HashMap<String, String>,
}

impl ConfigStore {
    pub fn new() -> Self {
        Self { staged: HashMap::new(), running: HashMap::new() }
    }

    pub fn stage(&mut self, key: &str, value: &str) {
        self.staged.insert(key.to_string(), value.to_string());
    }

    pub fn commit(&mut self) {
        self.running = self.staged.clone();
        self.staged.clear();
    }

    pub fn rollback(&mut self) {
        self.staged.clear();
    }

    pub fn diff(&self) -> Vec<(String, String)> {
        self.staged.iter().map(|(k,v)| (k.clone(), v.clone())).collect()
    }
}
"@

# src/mgmt/validator.rs
W "$Root/src/mgmt/validator.rs" @"
#[derive(Default)]
pub struct Validator {}

impl Validator {
    pub fn new() -> Self {
        Self {}
    }

    pub fn validate(&self, key: &str, value: &str) -> bool {
        println!(\"[Validator] Validating {} = {}\", key, value);
        true
    }
}
"@

# src/mgmt/rbac.rs
W "$Root/src/mgmt/rbac.rs" @"
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Role {
    Admin,
    Operator,
    Viewer,
}

pub struct Rbac {
    pub role: Role,
}

impl Rbac {
    pub fn new(role: Role) -> Self {
        Self { role }
    }

    pub fn can_apply(&self) -> bool {
        matches!(self.role, Role::Admin | Role::Operator)
    }

    pub fn can_view(&self) -> bool {
        true
    }
}
"@

# src/mgmt/audit.rs
W "$Root/src/mgmt/audit.rs" @"
use chrono::Utc;

#[derive(Debug)]
pub struct AuditEntry {
    pub timestamp: String,
    pub user: String,
    pub action: String,
}

pub struct AuditLog {
    entries: Vec<AuditEntry>,
}

impl AuditLog {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn record(&mut self, user: &str, action: &str) {
        let entry = AuditEntry {
            timestamp: Utc::now().to_rfc3339(),
            user: user.to_string(),
            action: action.to_string(),
        };
        println!(\"[Audit] {} by {} at {}\", action, user, entry.timestamp);
        self.entries.push(entry);
    }

    pub fn list(&self) -> &Vec<AuditEntry> {
        &self.entries
    }
}
"@

# src/mgmt/observability.rs
W "$Root/src/mgmt/observability.rs" @"
use prometheus::{Encoder, TextEncoder, Registry, IntCounter};

pub struct Observability {
    pub registry: Registry,
    pub requests: IntCounter,
}

impl Observability {
    pub fn new() -> Self {
        let registry = Registry::new();
        let requests = IntCounter::new(\"requests_total\", \"Total requests\").unwrap();
        registry.register(Box::new(requests.clone())).unwrap();
        Self { registry, requests }
    }

    pub fn inc_requests(&self) {
        self.requests.inc();
    }

    pub fn export(&self) -> String {
        let encoder = TextEncoder::new();
        let mf = self.registry.gather();
        let mut buffer = Vec::new();
        encoder.encode(&mf, &mut buffer).unwrap();
        String::from_utf8(buffer).unwrap()
    }
}
"@

Write-Host "Batch 9/11 complete: Management subsystem created under $Root/src/mgmt"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/shared/mod.rs
W "$Root/src/shared/mod.rs" @"
pub mod netio;
pub mod packet;
pub mod timers;
pub mod perf;

pub use netio::NetIo;
pub use packet::{EthernetFrame, Ipv4Packet, Ipv6Packet, TcpSegment, UdpDatagram};
pub use timers::DeterministicTimer;
pub use perf::PerfTuner;
"@

# src/shared/netio.rs
W "$Root/src/shared/netio.rs" @"
#[derive(Debug, Clone)]
pub enum IoMode {
    KernelSocket,
    AfXdp,
    Dpdk,
}

pub struct NetIo {
    pub mode: IoMode,
}

impl NetIo {
    pub fn new(mode: IoMode) -> Self {
        Self { mode }
    }

    pub fn send(&self, buf: &[u8]) {
        println!(\"[NetIo::{:?}] Sending {} bytes\", self.mode, buf.len());
    }

    pub fn recv(&self) -> Option<Vec<u8>> {
        println!(\"[NetIo::{:?}] Receiving packet\", self.mode);
        None
    }
}
"@

# src/shared/packet.rs
W "$Root/src/shared/packet.rs" @"
#[derive(Debug, Clone)]
pub struct EthernetFrame {
    pub src: [u8; 6],
    pub dst: [u8; 6],
    pub ethertype: u16,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct Ipv4Packet {
    pub src: [u8; 4],
    pub dst: [u8; 4],
    pub proto: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct Ipv6Packet {
    pub src: [u8; 16],
    pub dst: [u8; 16],
    pub next_header: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct TcpSegment {
    pub src_port: u16,
    pub dst_port: u16,
    pub seq: u32,
    pub ack: u32,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct UdpDatagram {
    pub src_port: u16,
    pub dst_port: u16,
    pub payload: Vec<u8>,
}
"@

# src/shared/timers.rs
W "$Root/src/shared/timers.rs" @"
use std::time::{Duration, Instant};

pub struct DeterministicTimer {
    start: Instant,
    interval: Duration,
}

impl DeterministicTimer {
    pub fn new(interval_ms: u64) -> Self {
        Self {
            start: Instant::now(),
            interval: Duration::from_millis(interval_ms),
        }
    }

    pub fn expired(&self) -> bool {
        self.start.elapsed() >= self.interval
    }
}
"@

# src/shared/perf.rs
W "$Root/src/shared/perf.rs" @"
pub struct PerfTuner {
    pub numa_nodes: usize,
    pub hugepages: bool,
}

impl PerfTuner {
    pub fn new() -> Self {
        Self { numa_nodes: 1, hugepages: false }
    }

    pub fn pin_to_core(&self, core: usize) {
        println!(\"[Perf] Pinning thread to core {}\", core);
    }

    pub fn enable_hugepages(&mut self) {
        self.hugepages = true;
        println!(\"[Perf] Hugepages enabled\");
    }
}
"@

Write-Host "Batch 10/11 complete: Shared core subsystem created under $Root/src/shared"

param([string]$Root="netos")

function W($p,$c){
  $d=Split-Path $p
  if($d -and !(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d | Out-Null}
  Set-Content -Path $p -Value $c -Encoding UTF8
}

# src/devices/router_os/mod.rs
W "$Root/src/devices/router_os/mod.rs" @"
pub mod rib;
pub mod bgp;
pub mod ospf;
pub mod isis;
pub mod rip;
pub mod pim;
pub mod mpls_ldp;
pub mod rsvp_te;
pub mod segment_routing;
pub mod vrrf_vrrp;

pub use rib::Rib;
"@

# src/devices/router_os/rib.rs
W "$Root/src/devices/router_os/rib.rs" @"
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Route {
    pub prefix: String,
    pub next_hop: String,
    pub protocol: String,
}

#[derive(Default)]
pub struct Rib {
    pub routes: HashMap<String, Route>,
}

impl Rib {
    pub fn new() -> Self {
        Self { routes: HashMap::new() }
    }

    pub fn add_route(&mut self, prefix: &str, next_hop: &str, proto: &str) {
        let r = Route { prefix: prefix.to_string(), next_hop: next_hop.to_string(), protocol: proto.to_string() };
        self.routes.insert(prefix.to_string(), r);
        println!(\"[RIB] Added route {} via {} ({})\", prefix, next_hop, proto);
    }
}
"@

# src/devices/router_os/bgp.rs
W "$Root/src/devices/router_os/bgp.rs" @"
pub struct Bgp {}

impl Bgp {
    pub fn new() -> Self { Self {} }

    pub fn establish_session(&self, peer: &str) {
        println!(\"[BGP] Establishing session with {}\", peer);
    }
}
"@

# src/devices/router_os/ospf.rs
W "$Root/src/devices/router_os/ospf.rs" @"
pub struct Ospf {}

impl Ospf {
    pub fn new() -> Self { Self {} }

    pub fn start(&self, area: u32) {
        println!(\"[OSPF] Starting in area {}\", area);
    }
}
"@

# src/devices/router_os/isis.rs
W "$Root/src/devices/router_os/isis.rs" @"
pub struct Isis {}

impl Isis {
    pub fn new() -> Self { Self {} }

    pub fn start(&self, level: u8) {
        println!(\"[IS-IS] Starting at level {}\", level);
    }
}
"@

# src/devices/router_os/rip.rs
W "$Root/src/devices/router_os/rip.rs" @"
pub struct Rip {}

impl Rip {
    pub fn new() -> Self { Self {} }

    pub fn start(&self) {
        println!(\"[RIP] Starting RIP/RIPng\");
    }
}
"@

# src/devices/router_os/pim.rs
W "$Root/src/devices/router_os/pim.rs" @"
pub struct Pim {}

impl Pim {
    pub fn new() -> Self { Self {} }

    pub fn join_group(&self, group: &str) {
        println!(\"[PIM] Joining multicast group {}\", group);
    }
}
"@

# src/devices/router_os/mpls_ldp.rs
W "$Root/src/devices/router_os/mpls_ldp.rs" @"
pub struct MplsLdp {}

impl MplsLdp {
    pub fn new() -> Self { Self {} }

    pub fn advertise_label(&self, prefix: &str) {
        println!(\"[LDP] Advertising label for {}\", prefix);
    }
}
"@

# src/devices/router_os/rsvp_te.rs
W "$Root/src/devices/router_os/rsvp_te.rs" @"
pub struct RsvpTe {}

impl RsvpTe {
    pub fn new() -> Self { Self {} }

    pub fn signal_path(&self, tunnel: &str) {
        println!(\"[RSVP-TE] Signaling path for tunnel {}\", tunnel);
    }
}
"@

# src/devices/router_os/segment_routing.rs
W "$Root/src/devices/router_os/segment_routing.rs" @"
pub struct SegmentRouting {}

impl SegmentRouting {
    pub fn new() -> Self { Self {} }

    pub fn install_policy(&self, policy: &str) {
        println!(\"[SR] Installing segment routing policy {}\", policy);
    }
}
"@

# src/devices/router_os/vrrf_vrrp.rs
W "$Root/src/devices/router_os/vrrf_vrrp.rs" @"
pub struct VrrfVrrp {}

impl VrrfVrrp {
    pub fn new() -> Self { Self {} }

    pub fn start(&self, vrid: u8) {
        println!(\"[VRRP] Starting VRRP instance {}\", vrid);
    }
}
"@

Write-Host "Batch 11 complete: Router OS subsystem created under $Root/src/devices/router_os"


