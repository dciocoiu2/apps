#main.py
#see ice4pi.pcf 
# use ice4pi_winloader.py program.bin <port> to load
import machine
import sys
import time

# Pin assignments matched to your PCF signals
PIN_CREST = 9  # Connected to R18 (iCE_CREST)
PIN_MOSI = 11  # Connected to R19 (iCE_MOSI)
PIN_SCK = 12  # Connected to R23 (iCE_SCK)
PIN_SS = 10  # Connected to R24 (iCE_SS_B)
PIN_DONE = 8  # Connected to R22 (iCE_DONE) [Optional]

crest = machine.Pin(PIN_CREST, machine.Pin.OUT, value=1)
ss = machine.Pin(PIN_SS, machine.Pin.OUT, value=1)
done = machine.Pin(PIN_DONE, machine.Pin.IN)

# Initialize SPI (iCE40 supports up to 20MHz in slave mode)
spi = machine.SPI(
    1,
    baudrate=10000000,
    polarity=0,
    phase=0,
    sck=machine.Pin(PIN_SCK),
    mosi=machine.Pin(PIN_MOSI),
)


def load_sram():
    # 1. Read 4-byte size header from host
    size_bytes = sys.stdin.buffer.read(4)
    if not size_bytes or len(size_bytes) < 4:
        return
    total_bytes = int.from_bytes(size_bytes, "big")

    # 2. Enter Slave SPI Mode: CS must be LOW before/during CRESET pulse
    ss.value(0)
    crest.value(0)
    time.sleep_us(10)  # Hold reset low
    crest.value(1)
    time.sleep_ms(2)  # Wait >= 1200us for iCE40 SRAM clear

    # 3. Stream binary directly from USB serial RX buffer -> SPI MOSI
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

    # 4. Finalize SRAM config: SS high + send 49+ dummy clocks
    ss.value(1)
    spi.write(b"\xff" * 8)  # 64 clock cycles

    # 5. Check if FPGA successfully loaded configuration into SRAM
    time.sleep_ms(1)
    if done.value() == 1:
        sys.stdout.buffer.write(b"SUCCESS\n")
    else:
        sys.stdout.buffer.write(b"FAILED\n")


# Serial listener loop
sys.stdout.write("READY\n")
while True:
    cmd = sys.stdin.buffer.read(1)
    if cmd == b"P":  # Programming trigger signal
        load_sram()
        sys.stdout.write("READY\n")
