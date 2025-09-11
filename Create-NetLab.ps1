Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
$labName         = 'netlab'
$compilerBaseUrl = 'https://github.com/tinycc/tinycc/releases/latest/download'
$compilerMap     = @{
  'windows-x86_64' = 'tcc-win32.exe'
  'linux-x86_64'   = 'tcc-linux-x86_64'
  'linux-aarch64'  = 'tcc-linux-arm64'
  'darwin-arm64'   = 'tcc-macos-arm64'
  'darwin-x86_64'  = 'tcc-macos-x86_64'
}

$layers = @(
  @{ name='l2switch'; role='L2 Switch'; next='router'  },
  @{ name='router';   role='L3 Router'; next='firewall'},
  @{ name='firewall'; role='L4 Firewall'; next='session'},
  @{ name='session';  role='L5 Session'; next='parser'},
  @{ name='parser';   role='L6 Parser'; next='app'    },
  @{ name='app';      role='L7 App';     next=''      }
)

$dirs = @('bin','include','src','configs','out') | ForEach-Object { Join-Path $labName $_ }

# -----------------------------------------------------------------------------
# UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
function New-File {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Get-PlatformKey {
  if ($IsWindows) { $os = 'windows' } else { $os = (uname).ToLower() }
  $arch = (uname -m)
  return "$os-$arch"
}

function Download-Compiler {
  param([string]$TargetPath)
  $platformKey = Get-PlatformKey
  if ($compilerMap.ContainsKey($platformKey)) {
    $filename = $compilerMap[$platformKey]
    $url      = "$compilerBaseUrl/$filename"
    Write-Host "Downloading compiler for $platformKey from $url..."
    try {
      Invoke-WebRequest -Uri $url -OutFile $TargetPath -UseBasicParsing
      Write-Host "Saved to $TargetPath"
    } catch {
      Write-Host "Failed to download compiler: $_"
    }
  } else {
    Write-Host "Unsupported platform: $platformKey. Please download compiler manually."
  }
}

# -----------------------------------------------------------------------------
# Step 1: Create Directory Structure
# -----------------------------------------------------------------------------
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }
}

# -----------------------------------------------------------------------------
# Step 2: Generate Shared Header (Platform-Aware)
# -----------------------------------------------------------------------------
$headerPath = Join-Path $labName 'include\netlab.h'
$platformKey = Get-PlatformKey
$isWindows   = $platformKey.StartsWith('windows')

$header = @()
$header += '#pragma once'
$header += '#include <stdio.h>'
$header += '#include <stdlib.h>'
$header += '#include <string.h>'
$header += '#include <stdint.h>'

if ($isWindows) {
  $header += '#include <windows.h>'
} else {
  $header += '#include <unistd.h>'
  $header += '#include <fcntl.h>'
  $header += '#include <sys/ioctl.h>'
  $header += '#include <net/if.h>'
  $header += '#include <linux/if_tun.h>'
}

$header += '#define NL_MAX_NAME 64'
$header += '#define NL_MAX_PAYLOAD 2048'
$header += '#define NL_MAX_DEVICES 16'

$header += 'typedef enum { MODE_EMULATED, MODE_REALNET } nl_mode_t;'
$header += 'typedef struct { char name[NL_MAX_NAME]; char iface[NL_MAX_NAME]; nl_mode_t mode; int trace; } nl_config_t;'
$header += 'typedef struct { char src[NL_MAX_NAME]; char dst[NL_MAX_NAME]; size_t len; uint8_t payload[NL_MAX_PAYLOAD]; } nl_packet_t;'
$header += 'typedef void (*nl_rx_fn)(nl_packet_t *pkt);'
$header += 'typedef struct { char name[NL_MAX_NAME]; nl_rx_fn rx; } nl_device_t;'
$header += 'static nl_device_t nl_devices[NL_MAX_DEVICES]; static int nl_device_count = 0;'

$header += 'void nl_register(const char *name, nl_rx_fn rx) {'
$header += '  if (nl_device_count >= NL_MAX_DEVICES) { fprintf(stderr, "fatal: too many devices\n"); exit(1); }'
$header += '  strncpy(nl_devices[nl_device_count].name, name, NL_MAX_NAME - 1);'
$header += '  nl_devices[nl_device_count].rx = rx;'
$header += '  nl_device_count++; }'

$header += 'void nl_send(const char *dst, nl_packet_t *pkt) {'
$header += '  for (int i = 0; i < nl_device_count; i++) {'
$header += '    if (strcmp(nl_devices[i].name, dst) == 0) { nl_devices[i].rx(pkt); return; }'
$header += '  }'
$header += '  fprintf(stderr, "drop: no device named %s\n", dst); }'

$header += 'void nl_cli_prompt(const char *name, const char *role) {'
$header += '  char line[256];'
$header += '  printf("[%s] CLI ready (%s). Type \'help\', \'show\', or \'exit\'.\n", name, role);'
$header += '  while (1) {'
$header += '    printf("%s> ", name);'
$header += '    if (!fgets(line, sizeof line, stdin)) break;'
$header += '    if (strncmp(line, "exit", 4) == 0) break;'
$header += '    else if (strncmp(line, "help", 4) == 0) printf("Commands: help, exit, show\n");'
$header += '    else if (strncmp(line, "show", 4) == 0) printf("[%s] role: %s\n", name, role);'
$header += '    else printf("Unknown command.\n");'
$header += '  }'
$header += '}'

$header += 'int nl_bind_realnet(const char *iface) {'
if ($isWindows) {
  $header += '  fprintf(stderr, "Realnet mode not supported on Windows.\n"); return -1;'
} else {
  $header += '  struct ifreq ifr; int fd = open("/dev/net/tun", O_RDWR);'
  $header += '  if (fd < 0) { perror("open"); return -1; }'
  $header += '  memset(&ifr, 0, sizeof(ifr)); ifr.ifr_flags = IFF_TAP | IFF_NO_PI;'
  $header += '  strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);'
  $header += '  if (ioctl(fd, TUNSETIFF, &ifr) < 0) { perror("ioctl"); close(fd); return -1; }'
  $header += '  printf("Bound to real interface: %s\n", iface); return fd;'
}
$header += '}'

New-File $headerPath ($header -join "`r`n")

# -----------------------------------------------------------------------------
# Step 3: Generate Device Source Files
# -----------------------------------------------------------------------------
foreach ($layer in $layers) {
  $name   = $layer.name
  $role   = $layer.role
  $next   = $layer.next
  $srcPath = Join-Path $labName "src\$name.c"

  $code = @"
#include "netlab.h"

static void ${name}_rx(nl_packet_t *pkt) {
  printf("[%s] received %zu bytes from %s\n", "$name", pkt->len, pkt->src);
  if (strlen("$next") > 0) {
    strcpy(pkt->src, "$name");
    strcpy(pkt->dst, "$next");
    nl_send("$next", pkt);
  }
}

int main(int argc, char **argv) {
  nl_config_t cfg = { .mode = MODE_EMULATED, .trace = 1 };
  strncpy(cfg.name, "$name", NL_MAX_NAME - 1);
  strncpy(cfg.iface, "tap0", NL_MAX_NAME - 1);

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
      cfg.mode = (strcmp(argv[i+1], "realnet") == 0) ? MODE_REALNET : MODE_EMULATED;
      i++;
    } else if (strcmp(argv[i], "--iface") == 0 && i + 1 < argc) {
      strncpy(cfg.iface, argv[i+1], NL_MAX_NAME - 1);
      i++;
    }
  }

  nl_register(cfg.name, ${name}_rx);
  printf("[%s] registered (%s)\n", cfg.name, "$role");

  if (cfg.mode == MODE_REALNET) {
    int fd = nl_bind_realnet(cfg.iface);
    if (fd >= 0) {
      uint8_t buf[NL_MAX_PAYLOAD];
      while (1) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len > 0) {
          nl_packet_t pkt = { .len = len };
          memcpy(pkt.payload, buf, len);
          strcpy(pkt.src, cfg.name);
         _t pkt = { .len = len };
          memcpy(pkt.payload, buf, len);
          strcpy(pkt.src, cfg.name);
          ${name}_rx(&pkt);
        }
      }
    }
  } else {
    if (strcmp(cfg.name, "app") == 0) {
      nl_packet_t pkt = { .len = 13 };
      memcpy(pkt.payload, "GET /index", 10);
      strcpy(pkt.src, "host");
      strcpy(pkt.dst, "l2switch");
      nl_send("l2switch", &pkt);
    }
    nl_cli_prompt(cfg.name, "$role");
  }

  return 0;
}
"@

  New-File $srcPath $code
}

# -----------------------------------------------------------------------------
# Step 4: Generate TOML Config Files
# -----------------------------------------------------------------------------
foreach ($layer in $layers) {
  $name       = $layer.name
  $next       = $layer.next
  $configPath = Join-Path $labName "configs\$name.toml"

  $lines = @()
  $lines += "name = `"$name`""
  $lines += "mode = `"emulated`""
  $lines += "trace = true"
  $lines += ""
  $lines += "[links]"
  $lines += "port0 = `"$next`""

  New-File $configPath ($lines -join "`r`n")
}

# -----------------------------------------------------------------------------
# Step 5: Download Platform-Specific Compiler
# -----------------------------------------------------------------------------
$binDir     = Join-Path $labName 'bin'
$platformKey = Get-PlatformKey
if ($compilerMap.ContainsKey($platformKey)) {
  $filename     = $compilerMap[$platformKey]
  $compilerPath = Join-Path $binDir $filename
  if (-not (Test-Path $compilerPath)) {
    Download-Compiler -TargetPath $compilerPath
  } else {
    Write-Host "Compiler already exists at $compilerPath"
  }
} else {
  Write-Host "Unsupported platform: $platformKey. Please download compiler manually."
}

# -----------------------------------------------------------------------------
# Final Step: Completion Message
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Lab generation complete"
Write-Host "Source files: $(Join-Path $labName 'src')"
Write-Host "Configs:      $(Join-Path $labName 'configs')"
Write-Host "Headers:      $(Join-Path $labName 'include')"
Write-Host "Compiler:     $(Join-Path $labName 'bin')"
Write-Host ""
Write-Host "Next steps:"
Write-Host " 1. Compile devices with the downloaded compiler or your toolchain"
Write-Host " 2. Run a device:   ./netlab-router.exe --mode emulated"
Write-Host " 3. For realnet:    --mode realnet --iface tap0 (requires TUN/TAP)"
Write-Host ""

# Step 6: Compile all device source files using TCC (Windows only)

$labName     = "netlab"
$srcDir      = Join-Path $labName "src"
$outDir      = Join-Path $labName "out"
$includeDir  = Join-Path $labName "include"
$binDir      = Join-Path $labName "bin"

# Locate TCC executable
$tccExe = Get-ChildItem -Path $binDir -Filter "tcc-win*.exe" | Select-Object -First 1
if (-not $tccExe) {
  Write-Host "TCC compiler not found in $binDir. Run Step 5 first."
  return
}

# Compile each .c file in src/
$sourceFiles = Get-ChildItem -Path $srcDir -Filter "*.c"
foreach ($file in $sourceFiles) {
  $name      = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
  $outputExe = Join-Path $outDir "$name.exe"
  $cmd       = "`"$($tccExe.FullName)`" -I`"$includeDir`" -o `"$outputExe`" `"$($file.FullName)`""

  Write-Host "Compiling $name.c -> $name.exe"
  Invoke-Expression $cmd
}

Write-Host ""
Write-Host "Build complete. Executables saved to: $outDir"
Write-Host "Run a device with: .\\netlab\\out\\router.exe --mode emulated"
