# ==============================================================================
# 1. Display Power & Signal Wiring Diagram in Terminal
# ==============================================================================
Write-Host @"
===============================================================================
         WIRING DIAGRAM: ESP32-S3  <--->  iCE40 SHIELD (RPi HEADER)
===============================================================================
  ESP32-S3 Pin   |  RPi Header Pin  |  Shield Signal  |  Function
  -----------------------------------------------------------------------------
  3.3V or 5V     |  Pin 1 or Pin 2  |  3V3 / 5V       |  Shield Power
  GND            |  Pin 6 (or 9/14) |  GND            |  Common Ground (Mandatory)
  GPIO 9         |  Pin 18          |  R18            |  iCE_CREST (Reset)
  GPIO 10        |  Pin 24          |  R24            |  iCE_SS_B  (Slave Select)
  GPIO 11        |  Pin 19          |  R19            |  iCE_MOSI  (SPI Data)
  GPIO 12        |  Pin 23          |  R23            |  iCE_SCK   (SPI Clock)
  GPIO 8         |  Pin 22          |  R22            |  iCE_DONE  (Done Status)
===============================================================================
"@ -ForegroundColor Cyan

# ==============================================================================
# 2. Write top.v
# ==============================================================================
$TopVerilog = @'
module top (
    input  wire clk,
    output wire D1,
    output wire D2,
    output wire D3,
    output wire D4,
    output wire D5
);
    reg [23:0] counter = 24'd0;

    always @(posedge clk) begin
        counter <= counter + 1'b1;
    end

    assign D1 = counter[23]; // Blinks D1 (~1.4s cycle)
    assign D2 = 1'b0;
    assign D3 = 1'b0;
    assign D4 = 1'b0;
    assign D5 = 1'b0;
endmodule
'@
Set-Content -Path ".\top.v" -Value $TopVerilog -Encoding UTF8
Write-Host "[Created] top.v" -ForegroundColor Green

# ==============================================================================
# 3. Write shield.pcf
# ==============================================================================
$PCFContent = @'
set_io clk 21
set_io D1 99
set_io D2 98
set_io D3 97
set_io D4 96
set_io D5 95
'@
Set-Content -Path ".\shield.pcf" -Value $PCFContent -Encoding UTF8
Write-Host "[Created] shield.pcf" -ForegroundColor Green

# ==============================================================================
# 4. Write esp32_sram_loader.py (MicroPython)
# ==============================================================================
$ESP32Code = @'
import machine
import sys
import time

PIN_CREST = 9   # R18 (Pin 18)
PIN_MOSI  = 11  # R19 (Pin 19)
PIN_SCK   = 12  # R23 (Pin 23)
PIN_SS    = 10  # R24 (Pin 24)
PIN_DONE  = 8   # R22 (Pin 22)

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
    size_bytes = sys.stdin.buffer.read(4)
    if not size_bytes or len(size_bytes) < 4:
        return
    total_bytes = int.from_bytes(size_bytes, "big")

    # Enter Slave SPI mode
    ss.value(0)
    crest.value(0)
    time.sleep_us(10)
    crest.value(1)
    time.sleep_ms(2)

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

    ss.value(1)
    spi.write(b'\xff' * 8)

    time.sleep_ms(1)
    if done.value() == 1:
        sys.stdout.buffer.write(b"SUCCESS\n")
    else:
        sys.stdout.buffer.write(b"FAILED\n")

sys.stdout.write("READY\n")
while True:
    cmd = sys.stdin.buffer.read(1)
    if cmd == b'P':
        load_sram()
        sys.stdout.write("READY\n")
'@
Set-Content -Path ".\esp32_sram_loader.py" -Value $ESP32Code -Encoding UTF8
Write-Host "[Created] esp32_sram_loader.py" -ForegroundColor Green

# ==============================================================================
# 5. Write bitstream_loader.py (Host Tool)
# ==============================================================================
$HostCode = @'
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

    ser.write(b'P')
    ser.write(size.to_bytes(4, byteorder='big'))

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
Set-Content -Path ".\bitstream_loader.py" -Value $HostCode -Encoding UTF8
Write-Host "[Created] bitstream_loader.py" -ForegroundColor Green
Write-Host "`nAll project files generated successfully!" -ForegroundColor Yellow