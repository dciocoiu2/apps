# bootstrap-netlab.ps1 — Modular Networking Lab with CLI, IPC, Configs, Realnet Support
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-File {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

# === PART 1: Directory Structure ===
$root = "netlab"
$dirs = @("$root/bin", "$root/include", "$root/src", "$root/configs", "$root/out")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

# === PART 2: Shared Header ===
New-File "$root/include/netlab.h" @'
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_tun.h>
#endif

#define NL_MAX_NAME 64
#define NL_MAX_PAYLOAD 2048
#define NL_MAX_DEVICES 16

typedef enum { MODE_EMULATED, MODE_REALNET } nl_mode_t;

typedef struct {
  char name[NL_MAX_NAME];
  char iface[NL_MAX_NAME];
  nl_mode_t mode;
  int trace;
} nl_config_t;

typedef struct {
  char src[NL_MAX_NAME];
  char dst[NL_MAX_NAME];
  size_t len;
  uint8_t payload[NL_MAX_PAYLOAD];
} nl_packet_t;

typedef void (*nl_rx_fn)(nl_packet_t *pkt);

typedef struct {
  char name[NL_MAX_NAME];
  nl_rx_fn rx;
} nl_device_t;

static nl_device_t nl_devices[NL_MAX_DEVICES];
static int nl_device_count = 0;

void nl_register(const char *name, nl_rx_fn rx) {
  if (nl_device_count >= NL_MAX_DEVICES) {
    fprintf(stderr, "fatal: too many devices\n");
    exit(1);
  }
  strncpy(nl_devices[nl_device_count].name, name, NL_MAX_NAME - 1);
  nl_devices[nl_device_count].rx = rx;
  nl_device_count++;
}

void nl_send(const char *dst, nl_packet_t *pkt) {
  for (int i = 0; i < nl_device_count; i++) {
    if (strcmp(nl_devices[i].name, dst) == 0) {
      nl_devices[i].rx(pkt);
      return;
    }
  }
  fprintf(stderr, "drop: no device named %s\n", dst);
}

void nl_cli_prompt(const char *name, const char *role) {
  char line[256];
  printf("[%s] CLI ready (%s). Type 'help', 'show', or 'exit'.\n", name, role);
  while (1) {
    printf("%s> ", name);
    if (!fgets(line, sizeof line, stdin)) break;
    if (strncmp(line, "exit", 4) == 0) break;
    else if (strncmp(line, "help", 4) == 0)
      printf("Commands: help, exit, show\n");
    else if (strncmp(line, "show", 4) == 0) {
      if (strcmp(role, "L2 Switch") == 0) printf("MAC table: 02:00:00:00:01:01 → port 1\n");
      else if (strcmp(role, "L3 Router") == 0) printf("Routes: 10.0.2.0/24 via 10.0.1.1\n");
      else if (strcmp(role, "L4 Firewall") == 0) printf("Rules: allow tcp dst=80, deny udp\n");
      else if (strcmp(role, "L5 Session") == 0) printf("Sessions: NAT 192.168.0.2 → 10.0.0.2\n");
      else if (strcmp(role, "L6 Parser") == 0) printf("Parsed: HTTP GET /index.html\n");
      else if (strcmp(role, "L7 App") == 0) printf("App: HTTP 200 OK\n");
      else printf("Nothing to show.\n");
    } else
      printf("Unknown command.\n");
  }
}

int nl_bind_realnet(const char *iface) {
#ifdef _WIN32
  fprintf(stderr, "Realnet mode not supported on Windows.\n");
  return -1;
#else
  struct ifreq ifr;
  int fd = open("/dev/net/tun", O_RDWR);
  if (fd < 0) { perror("open"); return -1; }
  memset(&ifr, 0, sizeof(ifr));
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
  if (ioctl(fd, TUNSETIFF, &ifr) < 0) { perror("ioctl"); close(fd); return -1; }
  printf("🔌 Bound to real interface: %s\n", iface);
  return fd;
#endif
}
'@

# === PART 3: Device Source Files (L2–L7) ===
$layers = @(
  @{name="l2switch"; role="L2 Switch"; next="router"},
  @{name="router"; role="L3 Router"; next="firewall"},
  @{name="firewall"; role="L4 Firewall"; next="session"},
  @{name="session"; role="L5 Session"; next="parser"},
  @{name="parser"; role="L6 Parser"; next="app"},
  @{name="app"; role="L7 App"; next=""}
)

foreach ($layer in $layers) {
  $name = $layer.name
  $role = $layer.role
  $next = $layer.next
  $code = @"
#include \"netlab.h\"

static void ${name}_rx(nl_packet_t *pkt) {
  printf(\"[%s] received %zu bytes from %s\\n\", \"$name\", pkt->len, pkt->src);
  if (strlen(\"$next\") > 0) {
    strcpy(pkt->src, \"$name\");
    strcpy(pkt->dst, \"$next\");
    nl_send(\"$next\", pkt);
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 1 };
  strncpy(cfg.name, \"$name\", NL_MAX_NAME - 1);
  strncpy(cfg.iface, \"tap0\", NL_MAX_NAME - 1);

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], \"--mode\") == 0 && i + 1 < argc) {
      cfg.mode = (strcmp(argv[i+1], \"realnet\") == 0) ? MODE_REALNET : MODE_EMULATED;
      i++;
    } else if (strcmp(argv[i], \"--iface\") == 0 && i + 1 < argc) {
      strncpy(cfg.iface, argv[i+1], NL_MAX_NAME - 1);
      i++;
    }
  }

  nl_register(cfg.name, ${name}_rx);
  printf(\"[%s] registered (%s)\\n\", cfg.name, \"$role\");

  if (cfg.mode == MODE_REALNET) {
    int fd = nl_bind_realnet(cfg.iface);
    if (fd >= 0) {
      uint8_t buf[2048];
      while (1) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len > 0) {
          nl_packet_t pkt = { .len = len };
          memcpy(pkt.payload, buf, len);
          strcpy(pkt.src, cfg.name);
          ${name}_rx(&pkt);
        }
      }
    }
  } else {
    if (strcmp(cfg.name, \"app\") == 0) {
      nl_packet_t pkt = { .len = 13 };
      memcpy(pkt.payload, \"GET /index\", 10);
      strcpy(pkt.src, \"host\");
      strcpy(pkt.dst, \"l2switch\");
      nl_send(\"l2switch\", &pkt);
    }
    nl_cli_prompt(cfg.name, \"$role\");
  }

  return 0;
}
"@
  New-File "$root/src/$name.c" $code
}


# === PART 4: Config Files (.toml) ===
foreach ($layer in $layers) {
  $name = $layer.name
  $next = $layer.next

  $lines = @()
  $lines += "name = `"$name`""
  $lines += "mode = `"emulated`""
  $lines += "trace = true"
  $lines += ""
  $lines += "[links]"
  $lines += "port0 = `"$next`""

  $tomlPath = "$root/configs/$name.toml"
  $content = $lines -join "`r`n"
  New-File $tomlPath $content
}

#=========OPTIONAL TINYC FETCHER====#

# === PART 5: Auto-download Tiny C Compiler (TCC) ===
function Download-TCC {
  param([string]$Url, [string]$TargetPath)
  Write-Host "Downloading TCC from $Url..." -ForegroundColor Cyan
  try {
    Invoke-WebRequest -Uri $Url -OutFile $TargetPath -UseBasicParsing
    Write-Host "Saved to $TargetPath" -ForegroundColor Green
  } catch {
    Write-Host "Failed to download TCC: $_" -ForegroundColor Red
  }
}

$binDir = "$root/bin"
$os = if ($IsWindows) { "windows" } else { (uname).ToLower() }
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
  "darwin-arm64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-macos-arm64"
    $target = "$binDir/tcc-macos-arm64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  default {
    Write-Host "Unsupported platform: $os-$arch. Please download TCC manually." -ForegroundColor Yellow
  }
}

# === Completion Message ===
Write-Host "`n Bootstrap complete!" -ForegroundColor Green
Write-Host "Source files: netlab/src/*.c" -ForegroundColor Yellow
Write-Host "Configs: netlab/configs/*.toml" -ForegroundColor Yellow
Write-Host "Headers: netlab/include/netlab.h" -ForegroundColor Yellow
Write-Host "TCC compiler: netlab/bin/" -ForegroundColor Yellow
Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "1. Compile each device using TCC or your preferred C compiler" -ForegroundColor Cyan
Write-Host "2. Run any device with CLI: ./netlab-router.exe --mode emulated" -ForegroundColor Cyan
Write-Host "3. Switch to realnet mode with: --mode realnet --iface tap0" -ForegroundColor Cyan