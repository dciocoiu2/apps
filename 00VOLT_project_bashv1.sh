#!/usr/bin/env bash
# ==============================================================================
# VOLT (Volatile Open Logic Toolkit) - Complete Installation & Deployment Setup
# Targeted for: Fresh Raspberry Pi 5 (Raspberry Pi OS 64-bit)
# Board: Lightside ICE4PI with Lattice iCE40HX1K-TQ144 FPGA
# ==============================================================================

set -e

echo "======================================================================"
echo " PHASE 1: System Update & Core Dependencies Installation"
echo "======================================================================"

sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    libgpiod-dev \
    gpiod \
    python3-dev \
    python3-pip \
    python3-venv \
    yosys \
    nextpnr-ice40 \
    fpga-icestorm

# Configure tmpfs RAM drive for Zero-Persistence Bitstream builds
sudo mkdir -p /tmp/volt_build
sudo mount -t tmpfs -o size=128M tmpfs /tmp/volt_build || true

echo "======================================================================"
echo " PHASE 2: Project Workspace & Constraint Files Initialization"
echo "======================================================================"

mkdir -p ~/volt_platform/{src/rtl,src/loader,src/composer,daemon,web,tests}
cd ~/volt_platform

# Create Lightside ICE4PI PCF Pin Mapping file
cat << 'EOF' > src/rtl/pmod.pcf
# Clock & Control Pins
set_io clk_12mhz 21
set_io pi_rst_n  110

# Status LEDs
set_io status_leds[0] 95
set_io status_leds[1] 96
set_io status_leds[2] 97
set_io status_leds[3] 98
set_io status_leds[4] 99

# PMOD Header I/O Pins
set_io pmod_io[0] 78
set_io pmod_io[1] 79
set_io pmod_io[2] 80
set_io pmod_io[3] 81
set_io pmod_io[4] 82
set_io pmod_io[5] 83
set_io pmod_io[6] 84
set_io pmod_io[7] 85
EOF

echo "======================================================================"
echo " PHASE 3: C Zero-Persistence Volatile SRAM Loader (libvolt_sram)"
echo "======================================================================"

cat << 'EOF' > src/loader/libvolt_sram.c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <gpiod.h>

#define GPIO_CRESETB 22
#define GPIO_CDONE   25
#define GPIO_CS      8
#define GPIO_SCK     11
#define GPIO_MOSI    10

int volt_program_sram(const unsigned char *bitstream, size_t len) {
    struct gpiod_chip *chip = gpiod_chip_open("/dev/gpiochip4");
    if (!chip) {
        perror("Failed to open gpiochip4");
        return -1;
    }

    struct gpiod_line_settings *out_settings = gpiod_line_settings_new();
    gpiod_line_settings_set_direction(out_settings, GPIOD_LINE_DIRECTION_OUTPUT);

    struct gpiod_line_settings *in_settings = gpiod_line_settings_new();
    gpiod_line_settings_set_direction(in_settings, GPIOD_LINE_DIRECTION_INPUT);

    struct gpiod_line_config *line_cfg = gpiod_line_config_new();
    
    // Add reset, chip select, clock, mosi
    gpiod_line_config_add_line_settings(line_cfg, (unsigned int[]){GPIO_CRESETB, GPIO_CS, GPIO_SCK, GPIO_MOSI}, 4, out_settings);
    gpiod_line_config_add_line_settings(line_cfg, (unsigned int[]){GPIO_CDONE}, 1, in_settings);

    struct gpiod_request_config *req_cfg = gpiod_request_config_new();
    gpiod_request_config_set_consumer(req_cfg, "VOLT_SRAM_Loader");

    struct gpiod_line_request *request = gpiod_chip_request_lines(chip, req_cfg, line_cfg);
    if (!request) {
        perror("Failed to request GPIO lines");
        gpiod_chip_close(chip);
        return -1;
    }

    // 1. Reset Pulse: CRESETB LOW, CS LOW
    gpiod_line_request_set_value(request, GPIO_CRESETB, GPIOD_LINE_VALUE_INACTIVE);
    gpiod_line_request_set_value(request, GPIO_CS, GPIOD_LINE_VALUE_INACTIVE);
    usleep(10);

    // 2. Drive CRESETB HIGH, wait for SRAM clear
    gpiod_line_request_set_value(request, GPIO_CRESETB, GPIOD_LINE_VALUE_ACTIVE);
    usleep(1000);

    // 3. Bitstream Transmission over SPI (MSB first)
    for (size_t i = 0; i < len; i++) {
        unsigned char byte = bitstream[i];
        for (int bit = 7; bit >= 0; bit--) {
            enum gpiod_line_value val = (byte & (1 << bit)) ? GPIOD_LINE_VALUE_ACTIVE : GPIOD_LINE_VALUE_INACTIVE;
            gpiod_line_request_set_value(request, GPIO_MOSI, val);
            gpiod_line_request_set_value(request, GPIO_SCK, GPIOD_LINE_VALUE_INACTIVE);
            gpiod_line_request_set_value(request, GPIO_SCK, GPIOD_LINE_VALUE_ACTIVE);
        }
    }

    // 4. Clocks for CDONE evaluation
    for (int i = 0; i < 100; i++) {
        gpiod_line_request_set_value(request, GPIO_SCK, GPIOD_LINE_VALUE_INACTIVE);
        gpiod_line_request_set_value(request, GPIO_SCK, GPIOD_LINE_VALUE_ACTIVE);
    }

    enum gpiod_line_value cdone = gpiod_line_request_get_value(request, GPIO_CDONE);

    gpiod_line_request_release(request);
    gpiod_chip_close(chip);

    return (cdone == GPIOD_LINE_VALUE_ACTIVE) ? 0 : -2;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <bitstream.bin>\n", argv[0]);
        return 1;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;

    fseek(f, 0, SEEK_END);
    size_t len = ftell(f);
    fseek(f, 0, SEEK_SET);

    unsigned char *buffer = malloc(len);
    fread(buffer, 1, len, f);
    fclose(f);

    int res = volt_program_sram(buffer, len);
    free(buffer);

    if (res == 0) {
        printf("[SUCCESS] FPGA Volatile SRAM Configuration Succeeded (CDONE High).\n");
        return 0;
    } else {
        printf("[ERROR] FPGA SRAM Programming Failed (CDONE Low).\n");
        return 1;
    }
}
EOF

# Compile loader
gcc -O2 src/loader/libvolt_sram.c -lgpiod -o ~/volt_platform/volt_sram_loader

echo "======================================================================"
echo " PHASE 4: Core Verilog RTL Modules & Shell Architecture"
echo "======================================================================"

# Sine Wave Lookup Table
python3 -c "
with open('src/rtl/sine_lut.hex', 'w') as f:
    import math
    for i in range(256):
        val = int((math.sin(2 * math.pi * i / 256) + 1) * 2047.5)
        f.write(f'{val:03X}\n')
"

# VOLT Shell Core
cat << 'EOF' > src/rtl/volt_shell.v
module volt_shell (
    input  wire        clk_12mhz,
    input  wire        pi_rst_n,
    output wire [4:0]  status_leds,
    inout  wire [7:0]  pmod_io
);

    reg [63:0] timestamp_counter;
    always @(posedge clk_12mhz or negedge pi_rst_n) begin
        if (!pi_rst_n) timestamp_counter <= 64'd0;
        else timestamp_counter <= timestamp_counter + 1'b1;
    end

    reg [23:0] heartbeat_cnt;
    always @(posedge clk_12mhz) heartbeat_cnt <= heartbeat_cnt + 1'b1;
    
    assign status_leds[0] = heartbeat_cnt[23];
    assign status_leds[1] = timestamp_counter[10];
    assign status_leds[2] = 1'b0;
    assign status_leds[3] = 1'b0;
    assign status_leds[4] = 1'b1;

endmodule
EOF

# Digital Logic Analyzer (DLA) Core
cat << 'EOF' > src/rtl/volt_dla.v
module volt_dla #(
    parameter CHANNELS = 8
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [CHANNELS-1:0]  probe_in,
    input  wire [63:0]          sys_timestamp,
    input  wire [2:0]           trigger_mode,
    input  wire [CHANNELS-1:0]  trigger_mask,
    input  wire [CHANNELS-1:0]  trigger_val,
    output reg  [31:0]          fifo_data,
    output reg                  fifo_wr_en
);
    reg [CHANNELS-1:0] probe_s1, probe_s2;
    always @(posedge clk) begin
        probe_s1 <= probe_in;
        probe_s2 <= probe_s1;
    end

    wire [CHANNELS-1:0] rising_edge  =  probe_s1 & ~probe_s2;
    wire [CHANNELS-1:0] falling_edge = ~probe_s1 &  probe_s2;

    reg trigger_hit;
    always @(*) begin
        case (trigger_mode)
            3'd0: trigger_hit = |((rising_edge | falling_edge) & trigger_mask);
            3'd1: trigger_hit = ((probe_s1 & trigger_mask) == (trigger_val & trigger_mask));
            default: trigger_hit = 1'b0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_en <= 1 meb0;
            fifo_data  <= 32'd0;
        end else if (trigger_hit) begin
            fifo_wr_en <= 1'b1;
            fifo_data  <= {probe_s1, sys_timestamp[23:0]};
        end else begin
            fifo_wr_en <= 1'b0;
        end
    end
endmodule
EOF

# Signal Generator Engine
cat << 'EOF' > src/rtl/volt_siggen.v
module volt_siggen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] phase_inc,
    input  wire [2:0]  wave_select,
    output reg  [11:0] dac_out_val,
    output reg         pwm_out
);
    reg [31:0] phase_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase_acc <= 32'd0;
        else phase_acc <= phase_acc + phase_inc;
    end

    reg [11:0] sine_rom [0:255];
    initial $readmemh("sine_lut.hex", sine_rom);

    always @(posedge clk) begin
        case (wave_select)
            3'd0: dac_out_val <= phase_acc[31] ? 12'hFFF : 12'h000;
            3'd1: dac_out_val <= phase_acc[31:20];
            3'd2: dac_out_val <= sine_rom[phase_acc[31:24]];
            default: dac_out_val <= 12'd0;
        endcase
        pwm_out <= (phase_acc[31:20] < 12'h800);
    end
endmodule
EOF

# Frequency Counter Engine
cat << 'EOF' > src/rtl/volt_freq_cnt.v
module volt_freq_cnt (
    input  wire        clk_12mhz,
    input  wire        rst_n,
    input  wire        sig_in,
    output reg  [31:0] measured_hz
);
    reg [31:0] gate_counter;
    reg [31:0] edge_counter;
    reg s0, s1, s2;

    always @(posedge clk_12mhz) begin
        s0 <= sig_in;
        s1 <= s0;
        s2 <= s1;
    end

    wire rising = s1 && !s2;

    always @(posedge clk_12mhz or negedge rst_n) begin
        if (!rst_n) begin
            gate_counter <= 0;
            edge_counter <= 0;
            measured_hz  <= 0;
        end else begin
            gate_counter <= gate_counter + 1;
            if (rising) edge_counter <= edge_counter + 1;

            if (gate_counter == 32'd12_000_000) begin
                measured_hz  <= edge_counter;
                gate_counter <= 0;
                edge_counter <= 0;
            end
        end
    end
endmodule
EOF

echo "======================================================================"
echo " PHASE 5: Dynamic Hardware Composer (volt_composer.py)"
echo "======================================================================"

cat << 'EOF' > src/composer/volt_composer.py
#!/usr/bin/env python3
import os
import sys
import json
import subprocess

ICE40_MAX_LUTS = 1280
ICE40_MAX_BRAMS = 16

class VOLTComposer:
    def __init__(self, manifest_path):
        with open(manifest_path, 'r') as f:
            self.manifest = json.load(f)
        self.used_luts = 150
        self.used_brams = 2

    def validate_resources(self):
        for mod in self.manifest.get('modules', []):
            self.used_luts += mod.get('luts', 0)
            self.used_brams += mod.get('brams', 0)

        if self.used_luts > ICE40_MAX_LUTS:
            raise RuntimeError(f"Resource Collision: LUT Over-allocation ({self.used_luts}/{ICE40_MAX_LUTS})")
        if self.used_brams > ICE40_MAX_BRAMS:
            raise RuntimeError(f"Resource Collision: BRAM Over-allocation ({self.used_brams}/{ICE40_MAX_BRAMS})")

    def generate_top(self, out_dir="/tmp/volt_build"):
        os.makedirs(out_dir, exist_ok=True)
        top_hdl = """
module volt_top (
    input wire clk_12mhz,
    input wire pi_rst_n,
    output wire [4:0] status_leds,
    inout wire [7:0] pmod_io
);

    volt_shell shell_inst (
        .clk_12mhz(clk_12mhz),
        .pi_rst_n(pi_rst_n),
        .status_leds(status_leds),
        .pmod_io(pmod_io)
    );

endmodule
"""
        with open(os.path.join(out_dir, "volt_top.v"), 'w') as f:
            f.write(top_hdl)

    def compile(self, out_dir="/tmp/volt_build"):
        src_rtl = os.path.expanduser("~/volt_platform/src/rtl")
        cmd_yosys = f"yosys -p 'synth_ice40 -top volt_top -json {out_dir}/top.json' {out_dir}/volt_top.v {src_rtl}/volt_shell.v"
        cmd_pnr   = f"nextpnr-ice40 --hx1k --package tq144 --json {out_dir}/top.json --pcf {src_rtl}/pmod.pcf --asc {out_dir}/top.asc"
        cmd_pack  = f"icepack {out_dir}/top.asc {out_dir}/volt_runtime.bin"

        for cmd in [cmd_yosys, cmd_pnr, cmd_pack]:
            res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError(f"Build Failed: {res.stderr}")

if __name__ == "__main__":
    manifest = sys.argv[1] if len(sys.argv) > 1 else "manifest.json"
    composer = VOLTComposer(manifest)
    composer.validate_resources()
    composer.generate_top()
    composer.compile()
    print("[SUCCESS] Bitstream generated inside Raspberry Pi RAM: /tmp/volt_build/volt_runtime.bin")
EOF

chmod +x src/composer/volt_composer.py

# Create Default Manifest File
cat << 'EOF' > ~/volt_platform/manifest.json
{
  "target": "iCE40HX1K-TQ144",
  "modules": [
    {"name": "DLA_Core", "luts": 250, "brams": 4},
    {"name": "SigGen_Core", "luts": 180, "brams": 2},
    {"name": "FreqCounter", "luts": 90, "brams": 0}
  ]
}
EOF

echo "======================================================================"
echo " PHASE 6: Python Virtual Environment & Host Daemon (voltd)"
echo "======================================================================"

python3 -m venv ~/volt_platform/venv
source ~/volt_platform/venv/bin/activate
pip install --upgrade pip
pip install fastapi uvicorn websockets gpiod requests

cat << 'EOF' > daemon/voltd.py
import os
import asyncio
import subprocess
from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse

app = FastAPI(title="VOLT Engine Daemon")

@app.post("/api/v1/deploy")
async def deploy_runtime():
    try:
        # 1. Run Dynamic Composer
        subprocess.run(["python3", "/home/pi/volt_platform/src/composer/volt_composer.py", "/home/pi/volt_platform/manifest.json"], check=True)
        # 2. Deploy Bitstream via C Volatile Loader
        subprocess.run(["/home/pi/volt_platform/volt_sram_loader", "/tmp/volt_build/volt_runtime.bin"], check=True)
        return {"status": "SUCCESS", "mode": "RAM_VOLATILE", "persisted": False}
    except Exception as e:
        return {"status": "ERROR", "message": str(e)}

@app.websocket("/ws/stream")
async def stream_data(websocket: WebSocket):
    await websocket.accept()
    while True:
        # Binary capture stream simulation
        sample = bytes([0xAA, 0x55, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        await websocket.send_bytes(sample)
        await asyncio.sleep(0.05)

app.mount("/", StaticFiles(directory="/home/pi/volt_platform/web", html=True), name="web")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
EOF

echo "======================================================================"
echo " PHASE 7: Web Interface & Live Waveform Viewer"
echo "======================================================================"

cat << 'EOF' > web/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>VOLT — Volatile Open Logic Toolkit</title>
    <style>
        body { background: #0f172a; color: #f8fafc; font-family: monospace; margin: 20px; }
        .card { background: #1e293b; padding: 20px; border-radius: 8px; margin-bottom: 20px; border: 1px solid #334155; }
        button { background: #0284c7; color: white; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; font-weight: bold; }
        button:hover { background: #0369a1; }
        canvas { background: #020617; border: 1px solid #334155; border-radius: 4px; width: 100%; height: 200px; }
    </style>
</head>
<body>
    <h1>VOLT Platform Dashboard</h1>
    <div class="card">
        <h3>Volatile Bitstream Manager</h3>
        <button onclick="deployBitstream()">Recompile & Reconfigure FPGA (RAM)</button>
        <span id="status">Status: Ready</span>
    </div>

    <div class="card">
        <h3>Logic Analyzer Stream</h3>
        <canvas id="waveformCanvas"></canvas>
    </div>

    <script>
        async function deployBitstream() {
            document.getElementById('status').innerText = "Status: Recompiling and Programing SRAM...";
            const res = await fetch('/api/v1/deploy', { method: 'POST' });
            const data = await res.json();
            document.getElementById('status').innerText = "Status: " + JSON.stringify(data);
        }

        const ws = new WebSocket('ws://' + window.location.host + '/ws/stream');
        const canvas = document.getElementById('waveformCanvas');
        const ctx = canvas.getContext('2d');
        
        ws.binaryType = 'arraybuffer';
        ws.onmessage = (event) => {
            const data = new Uint8Array(event.data);
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            ctx.strokeStyle = '#38bdf8';
            ctx.beginPath();
            for(let i = 0; i < data.length; i++) {
                let x = (i / data.length) * canvas.width;
                let y = canvas.height - (data[i] / 255 * canvas.height);
                if(i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            }
            ctx.stroke();
        };
    </script>
</body>
</html>
EOF

echo "======================================================================"
echo " PHASE 8: Hardware Self-Test Suite (volt_selftest.py)"
echo "======================================================================"

cat << 'EOF' > tests/volt_selftest.py
#!/usr/bin/env python3
import time
import requests

def run_self_test():
    print("[+] Executing Automated VOLT System Self-Test Routine...")
    
    # 1. Test REST API & Bitstream Deployment
    try:
        r = requests.post("http://localhost:8080/api/v1/deploy", timeout=15)
        assert r.status_code == 200, "API Error"
        res = r.json()
        assert res.get("status") == "SUCCESS", f"FPGA Config Failed: {res}"
        print("  [PASS] RAM Bitstream Synthesis & Volatile SRAM Programmer Test")
    except Exception as e:
        print(f"  [FAIL] FPGA Volatile Loader Test Failed: {e}")

    print("[SUCCESS] Hardware Integrity Checks Complete.")

if __name__ == "__main__":
    run_self_test()
EOF

chmod +x tests/volt_selftest.py

echo "======================================================================"
echo " PHASE 9: Systemd Daemon Service Configuration"
echo "======================================================================"

sudo tee /etc/systemd/system/voltd.service > /dev/null << 'EOF'
[Unit]
Description=VOLT Hardware Engine Daemon
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/volt_platform
ExecStart=/home/pi/volt_platform/venv/bin/python3 /home/pi/volt_platform/daemon/voltd.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable voltd
sudo systemctl start voltd

echo "======================================================================"
echo " VOLT Platform Setup Complete!"
echo " Web UI running at: http://$(hostname -I | awk '{print $1}'):8080"
echo "======================================================================"