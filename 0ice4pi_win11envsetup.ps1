#setup_workspace.ps1
# Set TLS 1.2 for GitHub API compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallDir = "$env:USERPROFILE\oss-cad-suite"
$TempArchive = "$env:TEMP\oss-cad-suite.tgz"

# ==============================================================================
# 1. Install FOSS CAD Suite (YosysHQ OSS CAD Suite)
# ==============================================================================
Write-Host "==> [1/3] Fetching latest YosysHQ OSS CAD Suite..." -ForegroundColor Cyan

try {
    $ReleaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest"
    $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like "oss-cad-suite-windows-x64-*.tgz" } | Select-Object -First 1

    if (-not $Asset) {
        throw "Could not find a Windows x64 package in the latest release."
    }

    $DownloadUrl = $Asset.browser_download_url
    Write-Host "Found release: $($Asset.name)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to fetch GitHub release metadata: $_"
    exit 1
}

if (-not (Test-Path "$InstallDir\bin\yosys.exe")) {
    Write-Host "Downloading OSS CAD Suite (this may take a moment)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempArchive -UseBasicParsing

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    Write-Host "Extracting package using built-in tar..." -ForegroundColor Cyan
    tar -xzf $TempArchive -C $InstallDir --strip-components=1

    if (Test-Path $TempArchive) {
        Remove-Item -Path $TempArchive -Force
    }
} else {
    Write-Host "OSS CAD Suite already installed at $InstallDir." -ForegroundColor Green
}

# Add toolchain bin folder to User PATH
$BinDir = "$InstallDir\bin"
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BinDir*") {
    Write-Host "Adding $BinDir to User PATH..." -ForegroundColor Cyan
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$BinDir", "User")
    $env:Path = "$env:Path;$BinDir"
}

# ==============================================================================
# 2. Generate MicroPython Firmware Script (`main.py` / `esp32_sram_loader.py`)
# ==============================================================================
Write-Host "==> [2/3] Writing MicroPython script (esp32_sram_loader.py)..." -ForegroundColor Cyan

$MicroPythonCode = @'
import machine
import sys
import time

# Pin configuration mapped to Lightside iCE40 Shield header
PIN_CREST = 9   # R18 (Header Pin 18)
PIN_MOSI  = 11  # R19 (Header Pin 19)
PIN_SCK   = 12  # R23 (Header Pin 23)
PIN_SS    = 10  # R24 (Header Pin 24)
PIN_DONE  = 8   # R22 (Header Pin 22)

crest = machine.Pin(PIN_CREST, machine.Pin.OUT, value=1)
ss    = machine.Pin(PIN_SS, machine.Pin.OUT, value=1)
done  = machine.Pin(PIN_DONE, machine.Pin.IN)

spi = machine.SPI(
    1,
    baudrate=10000000,
    polarity=0,
    phase=0,
    sck=machine.Pin(PIN_SCK),
    mosi=machine.Pin(PIN_MOSI)
)

def load_sram():
    # 1. Read 4-byte binary payload length header
    size_bytes = sys.stdin.buffer.read(4)
    if not size_bytes or len(size_bytes) < 4:
        return
    total_bytes = int.from_bytes(size_bytes, "big")

    # 2. Enter Slave SPI Mode (SS MUST be LOW before/during CRESET pulse)
    ss.value(0)
    crest.value(0)
    time.sleep_us(10)
    crest.value(1)
    time.sleep_ms(2) # Wait >=1200us for internal SRAM clear

    # 3. Stream binary directly from USB RX buffer into SPI MOSI
    bytes_written = 0
    chunk_size = 512
    buf = bytearray(chunk_size)

    while bytes_written < total_bytes:
        to_read = min(chunk_size, total_bytes - bytes_written)
        view = memoryview(buf)[:to_read]
        read_count = sys.stdin.buffer.readinto(view)
        if read_count:
            spi.write(view[:read_count])
            bytes_written += read_count

    # 4. Finalize config (CS HIGH + send >= 49 dummy clock cycles)
    ss.value(1)
    spi.write(b'\xff' * 8)

    # 5. Check configuration status pin
    time.sleep_ms(1)
    if done.value() == 1:
        sys.stdout.buffer.write(b"SUCCESS\n")
    else:
        sys.stdout.buffer.write(b"FAILED\n")

# Main USB CDC receiver loop
sys.stdout.write("READY\n")
while True:
    cmd = sys.stdin.buffer.read(1)
    if cmd == b'P':
        load_sram()
        sys.stdout.write("READY\n")
'@

Set-Content -Path ".\esp32_sram_loader.py" -Value $MicroPythonCode -Encoding UTF8

# ==============================================================================
# 3. Generate PC Host Streamer Script (`bitstream_loader.py`)
# ==============================================================================
Write-Host "==> [3/3] Writing Host Loader script (bitstream_loader.py)..." -ForegroundColor Cyan

$HostLoaderCode = @'
import sys
import time
import serial

COM_PORT = "COM3"
BITSTREAM_FILE = "hardware.bin"

def upload_bitstream(port, filepath):
    try:
        ser = serial.Serial(port, 115200, timeout=2)
    except Exception as e:
        print(f"Error opening port {port}: {e}")
        sys.exit(1)

    time.sleep(1)

    with open(filepath, "rb") as f:
        data = f.read()

    size = len(data)
    print(f"Streaming {size} bytes to ESP32-S3 on {port}...")

    # Send trigger byte 'P' + 4-byte big-endian length header
    ser.write(b'P')
    ser.write(size.to_bytes(4, byteorder='big'))

    # Stream bitstream chunks
    chunk_size = 512
    for i in range(0, size, chunk_size):
        ser.write(data[i:i + chunk_size])

    response = ser.readline().decode().strip()
    print(f"FPGA SRAM Status: {response}")
    ser.close()

if __name__ == "__main__":
    com = sys.argv[2] if len(sys.argv) > 2 else COM_PORT
    bin_file = sys.argv[1] if len(sys.argv) > 1 else BITSTREAM_FILE
    upload_bitstream(com, bin_file)
'@

Set-Content -Path ".\bitstream_loader.py" -Value $HostLoaderCode -Encoding UTF8

Write-Host "`nSetup complete!" -ForegroundColor Green
Write-Host "Created files in current directory:" -ForegroundColor Yellow
Write-Host "  1. esp32_sram_loader.py (MicroPython script for ESP32-S3)"
Write-Host "  2. bitstream_loader.py   (PC Python streaming script)"