#bitstream_uploader.py
# uploads bin to ice4pi
# usage: bts_uploader.py < binary.bin> COMX
import sys
import time
import serial

COM_PORT = "COMX"  # Adjust for your( replaxe x with ESP32-S3 port in Windows Device Manager)
BITSTREAM = "hardware.bin"  # Output from icepack / yosys
def upload_bitstream(port, filepath):
    ser = serial.Serial(port, 115200, timeout=2)
    time.sleep(1)

    with open(filepath, "rb") as f:
        data = f.read()

    size = len(data)
    print(f"Sending {size} bytes to {port}...")

    # Send trigger 'P' + 4-byte big-endian binary length header
    ser.write(b"P")
    ser.write(size.to_bytes(4, byteorder="big"))

    # Stream bitstream chunks
    chunk_size = 512
    for i in range(0, size, chunk_size):
        ser.write(data[i : i + chunk_size])

    response = ser.readline().decode().strip()
    print(f"FPGA SRAM Status: {response}")
    ser.close()


if __name__ == "__main__":
    com = sys.argv[2] if len(sys.argv) > 2 else COM_PORT
    bin_file = sys.argv[1] if len(sys.argv) > 1 else BITSTREAM
    upload_bitstream(com, bin_file)
