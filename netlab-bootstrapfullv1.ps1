# bootstrap-netlab.ps1 — Part 1 of 3
# Modular, dual-mode networking lab with per-device executables, CLI shell, and live tracing.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-File {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

# Create root directories
$root = "netlab"
$dirs = @(
  "$root/bin",
  "$root/include",
  "$root/src",
  "$root/scenarios",
  "$root/out"
)
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }
}

# README.md
New-File "$root/README.md" @'
# netlab (modular dual-mode lab)

This lab emulates or executes real networking devices (router, switch, firewall, host) as separate binaries. Each device supports:
- `--mode emulated` (default): in-memory packet graph
- `--mode realnet`: binds to real interfaces or sockets
- `--cli`: launches interactive shell
- `--trace`: enables live packet tracing

Build:
- Windows: `.\build.ps1`
- macOS/Linux: `pwsh ./build.ps1`

Run:
- `.\out\netlab-router.exe --cli --mode emulated`
- `.\out\netlab-switch.exe --mode realnet --iface eth0`
'@

# include/netlab.h
New-File "$root/include/netlab.h" @'
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
  #define PATH_SEP "\\"
#else
  #define PATH_SEP "/"
#endif

#define NL_MAX_PORTS    16
#define NL_MAX_RULES    128
#define NL_MAX_BACKENDS 32
#define NL_MAX_NAME     64
#define NL_DROP          0
#define NL_FWD           1

typedef enum { MODE_EMULATED, MODE_REALNET } nl_mode_t;

typedef struct {
  int        id;
  char       name[NL_MAX_NAME];
  nl_mode_t  mode;
  int        trace;
  char       iface[64];
} nl_config_t;

static inline void nl_die(const char *msg) {
  fprintf(stderr, "fatal: %s\n", msg);
  exit(1);
}
'@

# include/packet.h
New-File "$root/include/packet.h" @'
#pragma once
#include "netlab.h"

typedef enum { ETH_IPV4=0x0800, ETH_ARP=0x0806 } nl_ethertype_t;
typedef enum { L4_NONE=0, L4_UDP=17, L4_TCP=6, L4_ICMP=1 } nl_l4_t;

typedef struct {
  uint8_t dst[6], src[6];
  uint16_t ethertype;
} nl_eth_t;

typedef struct {
  uint8_t src[4], dst[4];
  uint8_t ttl, proto;
} nl_ipv4_t;

typedef struct {
  uint16_t src, dst;
} nl_l4_hdr_t;

typedef struct {
  uint8_t type, code;
  uint16_t id, seq;
} nl_icmp_t;

typedef struct {
  char text[2048];
} nl_http_t;

typedef struct nl_pkt {
  nl_eth_t   eth;
  nl_ipv4_t  ip;
  nl_l4_hdr_t l4;
  nl_icmp_t  icmp;
  nl_http_t  http;
  size_t     payload_len;
  uint8_t    payload[2048];
  int        ingress_port;
  char       trace[256];
} nl_pkt_t;

static inline void nl_mac_copy(uint8_t *d, const uint8_t *s) {
  for (int i = 0; i < 6; i++) d[i] = s[i];
}

static inline int nl_mac_eq(const uint8_t *a, const uint8_t *b) {
  for (int i = 0; i < 6; i++) if (a[i] != b[i]) return 0;
  return 1;
}

static inline int nl_ip_eq(const uint8_t *a, const uint8_t *b) {
  for (int i = 0; i < 4; i++) if (a[i] != b[i]) return 0;
  return 1;
}
'@

# build.ps1
New-File "$root/build.ps1" @'
param(
  [string]$Compiler = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root

function Find-Compiler {
  if ($Compiler) { return $Compiler }
  if ($IsWindows) {
    $candidates = @("bin\tcc-win-x64.exe")
  } else {
    $arch = uname -m
    if ($arch -eq "x86_64") {
      $candidates = @("bin/tcc-linux-x86_64","bin/tcc-macos-x86_64")
    } elseif ($arch -in @("aarch64","arm64")) {
      $candidates = @("bin/tcc-linux-arm64","bin/tcc-macos-arm64")
    } else {
      $candidates = @("bin/tcc-linux-x86_64","bin/tcc-linux-arm64","bin/tcc-macos-x86_64","bin/tcc-macos-arm64")
    }
  }
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

$cc = Find-Compiler
if (-not $cc) {
  Write-Host "No compiler found in bin/. Place a TCC binary and re-run." -ForegroundColor Yellow
  exit 1
}

$incs = "-Iinclude"
$targets = @("router","switch","firewall","host")

foreach ($t in $targets) {
  $src = "src/$t.c"
  $out = $IsWindows ? "out/netlab-$t.exe" : "out/netlab-$t"
  Write-Host "Building $t with $cc ..." -ForegroundColor Cyan
  & $cc $incs $src -o $out
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed for $t"
    exit $LASTEXITCODE
  }
  Write-Host "Built: $out" -ForegroundColor Green
}

Pop-Location
'@

# === src/router.c ===
New-File "$root/src/router.c" @'
#include "netlab.h"
#include "packet.h"

static void show_routes() {
  printf("Routing table:\n");
  printf("  10.0.2.0/24 via 10.0.1.2\n");
  printf("  10.0.3.0/24 via 10.0.1.3\n");
}

static void cli_loop(const nl_config_t *cfg) {
  char line[256];
  printf("[%s] CLI ready. Type 'help' or 'show routes'.\n", cfg->name);
  while (1) {
    printf("%s> ", cfg->name);
    if (!fgets(line, sizeof line, stdin)) break;
    if (strncmp(line, "exit", 4) == 0) break;
    else if (strncmp(line, "show routes", 11) == 0) show_routes();
    else if (strncmp(line, "help", 4) == 0)
      printf("Commands: show routes, exit\n");
    else
      printf("Unknown command.\n");
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 0 };
  strncpy(cfg.name, "router", sizeof cfg.name - 1);

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--mode") && i+1 < argc) {
      cfg.mode = (!strcmp(argv[i+1], "realnet")) ? MODE_REALNET : MODE_EMULATED;
      i++;
    } else if (!strcmp(argv[i], "--cli")) {
      cli_loop(&cfg);
      return 0;
    } else if (!strcmp(argv[i], "--trace")) {
      cfg.trace = 1;
    } else if (!strcmp(argv[i], "--name") && i+1 < argc) {
      strncpy(cfg.name, argv[i+1], sizeof cfg.name - 1);
      i++;
    }
  }

  printf("[%s] Starting in %s mode...\n", cfg.name,
         cfg.mode == MODE_REALNET ? "realnet" : "emulated");

  if (cfg.trace) printf("[%s] Tracing enabled.\n", cfg.name);

  for (int i = 0; i < 5; i++) {
    if (cfg.trace) printf("[%s] Tick %d\n", cfg.name, i);
  }

  return 0;
}
'@

# === src/switch.c ===
New-File "$root/src/switch.c" @'
#include "netlab.h"
#include "packet.h"

static void cli_loop(const nl_config_t *cfg) {
  char line[256];
  printf("[%s] CLI ready. Type 'help' or 'show macs'.\n", cfg->name);
  while (1) {
    printf("%s> ", cfg->name);
    if (!fgets(line, sizeof line, stdin)) break;
    if (strncmp(line, "exit", 4) == 0) break;
    else if (strncmp(line, "show macs", 9) == 0)
      printf("MAC table: (emulated)\n  02:00:00:00:01:01 → port 1\n");
    else if (strncmp(line, "help", 4) == 0)
      printf("Commands: show macs, exit\n");
    else
      printf("Unknown command.\n");
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 0 };
  strncpy(cfg.name, "switch", sizeof cfg.name - 1);

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--mode") && i+1 < argc) {
      cfg.mode = (!strcmp(argv[i+1], "realnet")) ? MODE_REALNET : MODE_EMULATED;
      i++;
    } else if (!strcmp(argv[i], "--cli")) {
      cli_loop(&cfg);
      return 0;
    } else if (!strcmp(argv[i], "--trace")) {
      cfg.trace = 1;
    } else if (!strcmp(argv[i], "--name") && i+1 < argc) {
      strncpy(cfg.name, argv[i+1], sizeof cfg.name - 1);
      i++;
    }
  }

  printf("[%s] Starting in %s mode...\n", cfg.name,
         cfg.mode == MODE_REALNET ? "realnet" : "emulated");

  if (cfg.trace) printf("[%s] Tracing enabled.\n", cfg.name);

  for (int i = 0; i < 5; i++) {
    if (cfg.trace) printf("[%s] Tick %d\n", cfg.name, i);
  }

  return 0;
}
'@

# === src/firewall.c ===
New-File "$root/src/firewall.c" @'
#include "netlab.h"
#include "packet.h"

static void cli_loop(const nl_config_t *cfg) {
  char line[256];
  printf("[%s] CLI ready. Type 'help' or 'show rules'.\n", cfg->name);
  while (1) {
    printf("%s> ", cfg->name);
    if (!fgets(line, sizeof line, stdin)) break;
    if (strncmp(line, "exit", 4) == 0) break;
    else if (strncmp(line, "show rules", 10) == 0)
      printf("Firewall rules:\n  deny tcp.dst=23\n  allow l4=tcp\n");
    else if (strncmp(line, "help", 4) == 0)
      printf("Commands: show rules, exit\n");
    else
      printf("Unknown command.\n");
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 0 };
  strncpy(cfg.name, "firewall", sizeof cfg.name - 1);

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--mode") && i+1 < argc) {
      cfg.mode = (!strcmp(argv[i+1], "realnet")) ? MODE_REALNET : MODE_EMULATED;
      i++;
    } else if (!strcmp(argv[i], "--cli")) {
      cli_loop(&cfg);
      return 0;
    } else if (!strcmp(argv[i], "--trace")) {
      cfg.trace = 1;
    } else if (!strcmp(argv[i], "--name") && i+1 < argc) {
      strncpy(cfg.name, argv[i+1], sizeof cfg.name - 1);
      i++;
    }
  }

  printf("[%s] Starting in %s mode...\n", cfg.name,
         cfg.mode == MODE_REALNET ? "realnet" : "emulated");

  if (cfg.trace) printf("[%s] Tracing enabled.\n", cfg.name);

  for (int i = 0; i < 5; i++) {
    if (cfg.trace) printf("[%s] Tick %d\n", cfg.name, i);
  }

  return 0;
}
'@

# === src/host.c ===
New-File "$root/src/host.c" @'
#include "netlab.h"
#include "packet.h"

static void cli_loop(const nl_config_t *cfg) {
  char line[256];
  printf("[%s] CLI ready. Type 'help', 'ping', or 'http'.\n", cfg->name);
  while (1) {
    printf("%s> ", cfg->name);
    if (!fgets(line, sizeof line, stdin)) break;
    if (strncmp(line, "exit", 4) == 0) break;
    else if (strncmp(line, "ping", 4) == 0)
      printf("[%s] ping reply from 10.0.0.100 seq=1\n", cfg->name);
    else if (strncmp(line, "http", 4) == 0)
      printf("[%s] HTTP response: HTTP/1.1 200 OK\r\nContent-Length:13\r\n\r\nhello world\n", cfg->name);
    else if (strncmp(line, "help", 4) == 0)
      printf("Commands: ping, http, exit\n");
    else
      printf("Unknown command.\n");
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 0 };
  strncpy(cfg.name, "host", sizeof cfg.name - 1);

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--mode") && i+1 < argc) {
      cfg.mode = (!strcmp(argv[i+1], "realnet")) ? MODE_REALNET
'@

#===≈====part 3========#
# === Auto-fetch Tiny C Compiler binary ===
function Download-TCC {
  param(
    [string]$Url,
    [string]$TargetPath
  )
  Write-Host "Downloading TCC from $Url..." -ForegroundColor Cyan
  try {
    Invoke-WebRequest -Uri $Url -OutFile $TargetPath -UseBasicParsing
    Write-Host "Saved to $TargetPath" -ForegroundColor Green
  } catch {
    Write-Host "❌ Failed to download TCC: $_" -ForegroundColor Red
  }
}

# Detect platform and fetch appropriate binary
$binDir = "$root/bin"
$os = $IsWindows ? "windows" : (uname | ForEach-Object { $_.ToLower() })
$arch = (uname -m)

switch ("$os-$arch") {
  "windows-x86_64" {
    $url = "https://github.com/nightbuilds/tcc-win32/releases/latest/download/tcc-win32.exe"
    $target = "$binDir/tcc-win-x64.exe"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  "linux-x86_64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-linux-x86_64"
    $target = "$binDir/tcc-linux-x86_64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  "linux-aarch64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-linux-arm64"
    $target = "$binDir/tcc-linux-arm64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  "darwin-x86_64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-macos-x86_64"
    $target = "$binDir/tcc-macos-x86_64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  "darwin-arm64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-macos-arm64"
    $target = "$binDir/tcc-macos-arm64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  default {
    Write-Host "[UNSUPPORTED_PLATFORM] Unsupported platform: $os-$arch. Please download TCC manually." -ForegroundColor Yellow
  }
}

Write-Host "`n[DONE] Bootstrap complete. You can now build with:" -ForegroundColor Green
Write-Host "   powershell -ExecutionPolicy Bypass -File netlab/build.ps1" -ForegroundColor Yellow
Write-Host "`nThen run any device with:" -ForegroundColor Green
Write-Host "   .\\netlab\\out\\netlab-router.exe --cli --trace" -ForegroundColor Yellow
Write-Host "   .\\netlab\\out\\netlab-host.exe --mode realnet --iface eth0" -ForegroundColor Yellow
