# Master Deployment Guide: NEORV32 Nommu Linux on DE10-Lite
# (Python 3, Dropbear SSH, Opkg Package Manager, SD Card Rootfs, & Dual ENC28J60 Ethernet)

## SECTION 1: VirtualBox VM Setup & Specifications

Create a fresh Ubuntu VirtualBox virtual machine with these dedicated host resource allocations:
* Operating System: Ubuntu 24.04 LTS (64-bit)
* vCPUs: 4 Cores (Enables parallel compilation via make -j$(nproc))
* RAM: 8 GB (Prevents memory exhaustion during toolchain and kernel linking)
* Hard Disk: 50 GB (Dynamically allocated)
* Network Adapter: NAT
* Shared Folder Configuration:
  - Host Path: C:\fpga_projects
  - Folder Name: fpga_projects
  - Check Auto-mount and Make Permanent.
  - Inside Ubuntu, mount it to /mnt/shared:
    sudo mkdir -p /mnt/shared
    sudo mount -v -t vboxsf fpga_projects /mnt/shared

## SECTION 2: Linux-Side Automation Script (build_neorv32_linux.sh)

Save this script inside your VM as build_neorv32_linux.sh, make it executable (chmod +x build_neorv32_linux.sh), and run it.

#!/bin/bash
# ==============================================================================
# NEORV32 Nommu Linux, Python 3, Opkg, SSH & Dual Ethernet Automated Build Script
# ==============================================================================
set -e

WORK_DIR="$HOME/neorv32_build_env"
SHARED_OUT="/mnt/shared/output"
mkdir -p "$WORK_DIR" "$SHARED_OUT"
cd "$WORK_DIR"

echo "=== [1/5] Installing Host Build Dependencies ==="
sudo apt update && sudo apt install -y \
    build-essential git bison flex libssl-dev libelf-dev bc libncurses-dev \
    u-boot-tools device-tree-compiler cpio wget curl libgmp-dev libmpfr-dev \
    libmpc-dev texinfo gawk libtool automake pkg-config libexpat1-dev python3 python3-pip

echo "=== [2/5] Cloning Buildroot (for rootfs with Python 3, SSH, and Opkg) ==="
if [ ! -d "buildroot" ]; then
    git clone --depth 1 --branch 2024.02.x https://github.com/buildroot/buildroot.git buildroot
fi

echo "=== [3/5] Configuring Buildroot for RISC-V 32-bit Nommu, Python 3, SSH & Opkg ==="
cd buildroot

cat << 'EOF' > configs/neorv32_full_defconfig
BR2_riscv=y
BR2_riscv_custom=y
BR2_riscv_isa_custom_rv32imac=y
BR2_BINFMT_FLAT=y
BR2_PACKAGE_PYTHON3=y
BR2_PACKAGE_PYTHON3_PYC_COMPILER=y
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_OPKG=y
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="120M"
EOF

make neorv32_full_defconfig
make -j$(nproc)

cp output/images/rootfs.ext4 "$SHARED_OUT/rootfs.ext4"

echo "=== [4/5] Cloning Linux Kernel & Compiling Nommu Image with SPI, SD, and Ethernet Drivers ==="
cd "$WORK_DIR"
if [ ! -d "linux" ]; then
    git clone --depth 1 --branch linux-6.6.y https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
fi
cd linux

make ARCH=riscv mrproper
make ARCH=riscv defconfig

scripts/config --disable CONFIG_MMU
scripts/config --enable CONFIG_BINFMT_FLAT
scripts/config --set-str CONFIG_PAGE_OFFSET "0x40000000"
scripts/config --enable CONFIG_SPI
scripts/config --enable CONFIG_SPI_MASTER
scripts/config --enable CONFIG_MMC
scripts/config --enable CONFIG_MMC_SPI
scripts/config --enable CONFIG_NET
scripts/config --enable CONFIG_INET
scripts/config --enable CONFIG_NETDEVICES
scripts/config --enable CONFIG_ETHERNET
scripts/config --enable CONFIG_ENC28J60

make ARCH=riscv CROSS_COMPILE=riscv64-unknown-elf- olddefconfig
make ARCH=riscv CROSS_COMPILE=riscv64-unknown-elf- -j$(nproc) Image

cp arch/riscv/boot/Image "$SHARED_OUT/Image"

echo "=== [5/5] Generating NEORV32 Device Tree Blob (.dtb) with Shared SPI Bus ==="
cd "$WORK_DIR"
cat << 'EOF' > neorv32.dts
/dts-v1/;
/ {
    compatible = "neorv32,soc";
    #address-cells = <1>;
    #size-cells = <1>;
    
    cpu0: cpu@0 {
        device_type = "cpu";
        compatible = "riscv";
        riscv,isa = "rv32imac";
        riscv,pm-type = "rv32";
        reg = <0>;
        status = "okay";
    };

    memory@40000000 {
        device_type = "memory";
        reg = <0x40000000 0x04000000>; /* 64MB SDRAM */
    };

    soc {
        #address-cells = <1>;
        #size-cells = <1>;
        compatible = "simple-bus";
        ranges;

        serial0: serial@ffe00000 {
            compatible = "neorv32,uart0";
            reg = <0xffe00000 0x400>;
            status = "okay";
            current-speed = <115200>;
        };

        spi0: spi@ffe00200 {
            compatible = "neorv32,spi";
            reg = <0xffe00200 0x400>;
            #address-cells = <1>;
            #size-cells = <0>;
            status = "okay";

            mmc-card@0 {
                compatible = "mmc-spi-slot";
                reg = <0>;
                spi-max-frequency = <10000000>;
            };

            ethernet@1 {
                compatible = "microchip,enc28j60";
                reg = <1>;
                spi-max-frequency = <12000000>;
            };

            ethernet@2 {
                compatible = "microchip,enc28j60";
                reg = <2>;
                spi-max-frequency = <12000000>;
            };
        };
    };
};
EOF

dtc -I dts -O dtb -o neorv32.dtb neorv32.dts
cp neorv32.dtb "$SHARED_OUT/neorv32.dtb"

echo "=== Build Complete! Artifacts synced to Windows at C:\fpga_projects\output ==="

## SECTION 3: Physical Hardware Wiring Instructions

Make all connections using jumper wires between the DE10-Lite Arduino header pins and your breakout modules (operate modules at 3.3V logic):

1. Arduino Giga R1 Serial Bridge:
   - DE10-Lite `ARDUINO_IO[1]` (TX)  -> Giga Pin `0` (RX1)
   - DE10-Lite `ARDUINO_IO[0]` (RX)  <- Giga Pin `1` (TX1)
   - DE10-Lite `GND`                <-> Giga `GND`

2. Shared SPI Bus (MicroSD Card Reader & Dual ENC28J60 Modules):
   - **Shared Clock (SCK):** DE10-Lite `ARDUINO_IO[13]` connected to SCK on SD Card, Eth #1, and Eth #2.
   - **Shared MOSI (Data In):** DE10-Lite `ARDUINO_IO[11]` connected to MOSI/SI on SD Card, Eth #1, and Eth #2.
   - **Shared MISO (Data Out):** DE10-Lite `ARDUINO_IO[12]` connected to MISO/SO on SD Card, Eth #1, and Eth #2.
   - **Chip Select 0 (MicroSD):** DE10-Lite `ARDUINO_IO[2]` -> CS on SD Card Reader.
   - **Chip Select 1 (Eth #1 -> eth0):** DE10-Lite `ARDUINO_IO[10]` -> CS on ENC28J60 Module #1.
   - **Chip Select 2 (Eth #2 -> eth1):** DE10-Lite `ARDUINO_IO[9]`  -> CS on ENC28J60 Module #2.
   - **Power & Ground:** DE10-Lite `3.3V` and `GND` distributed to all modules (ensure a solid external 3.3V supply if power draw exceeds board limits).

Upload this transparent bridge sketch to your Arduino Giga R1 via Arduino IDE:

void setup() {
  Serial.begin(115200);   // Native USB connection to Windows 11 PC
  Serial1.begin(115200);  // Hardware serial connected to DE10-Lite pins 0 and 1
}

void loop() {
  if (Serial1.available()) {
    Serial.write(Serial1.read());
  }
  if (Serial.available()) {
    Serial1.write(Serial.read());
  }
}

## SECTION 4: Quartus Prime Fresh Installation Guide (Windows 11)

1. Download: Download Quartus Prime Lite Edition (v23.1 or v20.1.1) from Intel.
2. Path Selection: Install to a clean path outside OneDrive (e.g., C:\intelFPGA_lite\23.1). Avoid spaces.
3. Component Selection: Check Quartus Prime Lite Edition, MAX 10 FPGA Device Support, and ModelSim-Intel FPGA Edition.
4. Drivers: Connect DE10-Lite, direct Windows Device Manager to C:\intelFPGA_lite\23.1\quartus\drivers\usb-blaster-2.

## SECTION 5: Quartus Project Setup, Generation & Execution

1. Create Project: Open Quartus Prime Lite, create project in C:\fpga_projects\hardware. Target Family: MAX 10. Device: 10M50DAF484C7G.
2. Integrate NEORV32 & SPI/SDRAM IP: Unpack NEORV32 core files, the DE10-Lite SDRAM controller module, and enable internal SPI controller generics in the processor instantiation.
3. Configure Processor Generics: In top-level VHDL wrapper, set:
   - CPU_EXTENSION_RISCV_M = true
   - CPU_EXTENSION_RISCV_A = true
   - CPU_EXTENSION_RISCV_C = true
   - Base boot address mapped to 0x40000000.
4. Pin Assignments (.qsf): Map 50MHz clock, SDRAM pins, UART0 TX/RX, and shared SPI bus / Chip Select lines to physical pins.
5. Compilation & Programming: Click Start Compilation, open Quartus Programmer, select USB-Blaster, and program the `.sof` bitstream. (Note: Because this is a `.sof` file loaded into volatile SRAM, power-cycling the board will completely clear your configuration and revert the FPGA back to its original factory default state).
6. SD Card Preparation: Flash `rootfs.ext4` onto your microSD card partition, and place `Image` and `neorv32.dtb` in the boot files directory.
7. Execution & Remote Access: Plug the SD card into your reader module, open your Windows terminal connected to the Arduino Giga R1 COM port at 115200 8N1, reset the FPGA, and boot up Linux. Assign an IP address (`ifconfig eth0 <IP>`), SSH in (`ssh root@<IP>`), and use `opkg` or run Python 3 and C GPIO mmap scripts remotely!