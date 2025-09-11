Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-File {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

# === PART 1: Detect OS and Architecture ===
$os = if ($IsWindows) { "windows" } else { (uname).ToLower() }
$arch = (uname -m)

# === PART 2: Create Directory Structure ===
$root = "netlab"
$dirs = @("$root/bin", "$root/include", "$root/src", "$root/configs", "$root/out")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

# === PART 3: Generate Shared Header (OS-Aware) ===
$header = @()
$header += "#pragma once"
$header += "#include <stdio.h>"
$header += "#include <stdlib.h>"
$header += "#include <string.h>"
$header += "#include <stdint.h>"

if ($os -eq "windows") {
  $header += "#define NL_PLATFORM_WINDOWS"
  $header += "#include <windows.h>"
} else {
  $header += "#define NL_PLATFORM_POSIX"
  $header += "#include <unistd.h>"
  $header += "#include <fcntl.h>"
  $header += "#include <sys/ioctl.h>"
  $header += "#include <net/if.h>"
  $header += "#include <linux/if_tun.h>"
}

$header += ""
$header += "#define NL_MAX_NAME 64"
$header += "#define NL_MAX_PAYLOAD 2048"
$header += "#define NL_MAX_DEVICES 16"
$header += ""
$header += "typedef enum { MODE_EMULATED, MODE_REALNET } nl_mode_t;"
$header += ""
$header += "typedef struct {"
$header += "  char name[NL_MAX_NAME];"
$header += "  char iface[NL_MAX_NAME];"
$header += "  nl_mode_t mode;"
$header += "  int trace;"
$header += "} nl_config_t;"
$header += ""
$header += "typedef struct {"
$header += "  char src[NL_MAX_NAME];"
$header += "  char dst[NL_MAX_NAME];"
$header += "  size_t len;"
$header += "  uint8_t payload[NL_MAX_PAYLOAD];"
$header += "} nl_packet_t;"
$header += ""
$header += "typedef void (*nl_rx_fn)(nl_packet_t *pkt);"
$header += ""
$header += "typedef struct {"
$header += "  char name[NL_MAX_NAME];"
$header += "  nl_rx_fn rx;"
$header += "} nl_device_t;"
$header += ""
$header += "static nl_device_t nl_devices[NL_MAX_DEVICES];"
$header += "static int nl_device_count = 0;"
$header += ""
$header += "void nl_register(const char *name, nl_rx_fn rx) {"
$header += "  if (nl_device_count >= NL_MAX_DEVICES) {"
$header += "    fprintf(stderr, \"fatal: too many devices\\n\");"
$header += "    exit(1);"
$header += "  }"
$header += "  strncpy(nl_devices[nl_device_count].name, name, NL_MAX_NAME - 1);"
$header += "  nl_devices[nl_device_count].rx = rx;"
$header += "  nl_device_count++;"
$header += "}"
$header += ""
$header += "void nl_send(const char *dst, nl_packet_t *pkt) {"
$header += "  for (int i = 0; i < nl_device_count; i++) {"
$header += "    if (strcmp(nl_devices[i].name, dst) == 0) {"
$header += "      nl_devices[i].rx(pkt);"
$header += "      return;"
$header += "    }"
$header += "  }"
$header += "  fprintf(stderr, \"drop: no device named %s\\n\", dst);"
$header += "}"
$header += ""
$header += "void nl_cli_prompt(const char *name, const char *role) {"
$header += "  char line[256];"
$header += "  printf(\"[%s] CLI ready (%s). Type 'help', 'show', or 'exit'.\\n\", name, role);"
$header += "  while (1) {"
$header += "    printf(\"%s> \", name);"
$header += "    if (!fgets(line, sizeof line, stdin)) break;"
$header += "    if (strncmp(line, \"exit\", 4) == 0) break;"
$header += "    else if (strncmp(line, \"help\", 4) == 0)"
$header += "      printf(\"Commands: help, exit, show\\n\");"
$header += "    else if (strncmp(line, \"show\", 4) == 0)"
$header += "      printf(\"[%s] role: %s\\n\", name, role);"
$header += "    else"
$header += "      printf(\"Unknown command.\\n\");"
$header += "  }"
$header += "}"

$header += ""
$header += "int nl_bind_realnet(const char *iface) {"
if ($os -eq "windows") {
  $header += "  fprintf(stderr, \"Realnet mode not supported on Windows.\\n\");"
  $header += "  return -1;"
} else {
  $header += "  struct ifreq ifr;"
  $header += "  int fd = open(\"/dev/net/tun\", O_RDWR);"
  $header += "  if (fd < 0) { perror(\"open\"); return -1; }"
  $header += "  memset(&ifr, 0, sizeof(ifr));"
  $header += "  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;"
  $header += "  strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);"
  $header += "  if (ioctl(fd, TUNSETIFF, &ifr) < 0) { perror(\"ioctl\"); close(fd); return -1; }"
  $header += "  printf(\"🔌 Bound to real interface: %s\\n\", iface);"
  $header += "  return fd;"
}
$header += "}"

New-File "$root/include/netlab.h" ($header -join "`r`n")


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


# Part 5: Auto-download Tiny C Compiler (TCC)
function Download-TCC {
  param([string]$Url, [string]$TargetPath)
  Write-Host "Downloading TCC from $Url..."
  try {
    Invoke-WebRequest -Uri $Url -OutFile $TargetPath -UseBasicParsing
    Write-Host "Saved to $TargetPath"
  } catch {
    Write-Host "Failed to download TCC: $_"
  }
}

# Detect OS and architecture
$binDir = "$root/bin"
$os = if ($IsWindows) { "windows" } else { (uname).ToLower() }
$arch = (uname -m)

# Map to known TCC targets
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
  "darwin-x86_64" {
    $url = "https://github.com/tinycc/tinycc/releases/latest/download/tcc-macos-x86_64"
    $target = "$binDir/tcc-macos-x86_64"
    if (-not (Test-Path $target)) { Download-TCC $url $target }
  }
  default {
    Write-Host "Unsupported platform: $os-$arch. Please download TCC manually."
  }
}

# Completion Message
Write-Host ""
Write-Host "Bootstrap complete"
Write-Host "Source files: netlab/src/*.c"
Write-Host "Configs: netlab/configs/*.toml"
Write-Host "Headers: netlab/include/netlab.h"
Write-Host "TCC compiler: netlab/bin/"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Compile each device using TCC or your preferred C compiler"
Write-Host "2. Run any device with CLI: ./netlab-router.exe --mode emulated"
Write-Host "3. Switch to realnet mode with: --mode realnet --iface tap0"
