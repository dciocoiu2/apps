#!/usr/bin/env python3
"""
FULL CLUSTER COORDINATOR (Single File)
- CYD-style UI using PySide6 (Qt6)
- PCAP logging
- BLE initial config (Bleak)
- TCP telemetry + commands
- Unified JSON protocol
- Auto-disable ESP-NOW on non-IoT hosts
- No node firmware changes required
"""

import asyncio
import json
import platform
import socket
import sys
import time
from dataclasses import dataclass, field
from typing import Dict, Optional

# BLE
from bleak import BleakScanner, BleakClient

# Qt UI
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QTableWidget, QTableWidgetItem
)
from PySide6.QtCore import Qt, QTimer

# ============================================================
# PCAP LOGGER
# ============================================================

class PcapLogger:
    PCAP_GLOBAL_HEADER = bytes([
        0xd4, 0xc3, 0xb2, 0xa1,
        0x02, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0x00, 0x00,
        0x7f, 0x00, 0x00, 0x00
    ])

    def __init__(self, filename="cluster.pcap"):
        self.filename = filename
        self.f = open(filename, "wb")
        self.f.write(self.PCAP_GLOBAL_HEADER)

    def write_packet(self, payload: bytes):
        ts_sec = int(time.time())
        ts_usec = int((time.time() % 1) * 1_000_000)
        length = len(payload)

        hdr = (
            ts_sec.to_bytes(4, "little") +
            ts_usec.to_bytes(4, "little") +
            length.to_bytes(4, "little") +
            length.to_bytes(4, "little")
        )

        self.f.write(hdr)
        self.f.write(payload)
        self.f.flush()


# ============================================================
# NODE MODEL
# ============================================================

@dataclass
class Node:
    id: str
    chip: str
    role: str
    transport: str
    last_seen: float
    writer: Optional[asyncio.StreamWriter] = field(default=None)


class NodeRegistry:
    def __init__(self):
        self.nodes: Dict[str, Node] = {}

    def upsert(self, node_id: str, chip: str, role: str, transport: str,
               writer=None, ts=None):
        ts = ts or time.time()
        if node_id in self.nodes:
            n = self.nodes[node_id]
            n.chip = chip or n.chip
            n.role = role or n.role
            n.transport = transport or n.transport
            n.last_seen = ts
            if writer:
                n.writer = writer
        else:
            self.nodes[node_id] = Node(
                id=node_id,
                chip=chip,
                role=role,
                transport=transport,
                last_seen=ts,
                writer=writer,
            )

    def all(self):
        return list(self.nodes.values())


# ============================================================
# TCP COORDINATOR
# ============================================================

class TcpCoordinator:
    def __init__(self, registry: NodeRegistry, pcap: PcapLogger,
                 host="0.0.0.0", port=3333):
        self.registry = registry
        self.pcap = pcap
        self.host = host
        self.port = port

    async def handle_client(self, reader, writer):
        peer = writer.get_extra_info("peername")
        node_id = None
        print(f"[TCP] Node connected: {peer}")

        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                raw = line.strip()
                if not raw:
                    continue

                self.pcap.write_packet(raw)

                try:
                    msg = json.loads(raw.decode())
                except:
                    print(f"[TCP] Invalid JSON: {raw}")
                    continue

                if msg.get("src") == "node":
                    node_id = msg.get("id") or f"{peer}"
                    chip = msg.get("chip", "")
                    role = msg.get("role", "")
                    transport = msg.get("transport", "wifi")

                    self.registry.upsert(node_id, chip, role, transport,
                                         writer=writer)

                else:
                    print(f"[TCP] Non-node message: {msg}")

        finally:
            print(f"[TCP] Node disconnected: {peer}")
            if node_id and node_id in self.registry.nodes:
                self.registry.nodes[node_id].writer = None

    async def start(self):
        server = await asyncio.start_server(self.handle_client,
                                            self.host, self.port)
        print(f"[TCP] Listening on {self.host}:{self.port}")
        async with server:
            await server.serve_forever()


# ============================================================
# BLE CONFIGURATOR
# ============================================================

class BleConfigurator:
    CONFIG_SERVICE_UUID = "0000c0de-0000-1000-8000-00805f9b34fb"
    CONFIG_CHAR_UUID    = "0000c0cf-0000-1000-8000-00805f9b34fb"

    def __init__(self, hub_ip="192.168.4.1", hub_port=3333):
        self.hub_ip = hub_ip
        self.hub_port = hub_port

    async def configure_nodes(self):
        print("[BLE] Scanning...")
        devices = await BleakScanner.discover()

        for d in devices:
            if "ClusterNode" in (d.name or ""):
                print(f"[BLE] Found node: {d.address}")
                await self.configure_node(d.address)

    async def configure_node(self, address):
        print(f"[BLE] Connecting to {address}...")
        async with BleakClient(address) as client:
            if not await client.is_connected():
                print(f"[BLE] Failed to connect {address}")
                return

            cfg = {
                "cmd": "init_config",
                "hub_ip": self.hub_ip,
                "hub_port": self.hub_port,
                "role": "WIFI_BLE",
                "transport": "wifi",
            }
            payload = json.dumps(cfg).encode()

            print(f"[BLE] Sending config: {cfg}")
            await client.write_gatt_char(self.CONFIG_CHAR_UUID,
                                         payload, response=True)


# ============================================================
# OPTIONAL ESP-NOW BRIDGE (PI ONLY)
# ============================================================

class EspNowBridge:
    def __init__(self):
        self.enabled = self._detect_iot_host()

    def _detect_iot_host(self):
        sys = platform.system().lower()
        if "linux" in sys and "raspberry" in platform.uname().node.lower():
            return True
        return False

    async def start(self):
        if not self.enabled:
            print("[ESPNOW] Disabled (non-IoT host)")
            return
        print("[ESPNOW] Bridge active (requires attached ESP32)")


# ============================================================
# COMMAND API
# ============================================================

class CommandAPI:
    def __init__(self, registry: NodeRegistry):
        self.registry = registry

    async def send(self, node_id: str, cmd: dict):
        node = self.registry.nodes.get(node_id)
        if not node or not node.writer:
            print(f"[CMD] Node {node_id} not connected")
            return
        msg = json.dumps(cmd) + "\n"
        node.writer.write(msg.encode())
        await node.writer.drain()
        print(f"[CMD] Sent to {node_id}: {cmd}")


# ============================================================
# CYD-STYLE UI (Qt6)
# ============================================================

class CoordinatorUI(QWidget):
    def __init__(self, registry: NodeRegistry, cmd: CommandAPI):
        super().__init__()
        self.registry = registry
        self.cmd = cmd

        self.setWindowTitle("CYD Cluster Coordinator")
        self.resize(900, 600)

        layout = QVBoxLayout(self)

        # Status bar
        self.status = QLabel("Coordinator Running — Capture ON")
        layout.addWidget(self.status)

        # Node table
        self.nodeTable = QTableWidget(0, 5)
        self.nodeTable.setHorizontalHeaderLabels(
            ["ID", "Chip", "Role", "Transport", "Last Seen"]
        )
        layout.addWidget(self.nodeTable)

        # WiFi table
        self.wifiTable = QTableWidget(0, 4)
        self.wifiTable.setHorizontalHeaderLabels(
            ["SSID", "BSSID", "RSSI", "Ch"]
        )
        layout.addWidget(self.wifiTable)

        # BLE table
        self.bleTable = QTableWidget(0, 3)
        self.bleTable.setHorizontalHeaderLabels(
            ["MAC", "RSSI", "Node"]
        )
        layout.addWidget(self.bleTable)

        # IEEE table
        self.ieeeTable = QTableWidget(0, 3)
        self.ieeeTable.setHorizontalHeaderLabels(
            ["Node", "Ch", "Note"]
        )
        layout.addWidget(self.ieeeTable)

        # Buttons
        btnLayout = QHBoxLayout()

        self.btnRoleWifi = QPushButton("Role: WiFi")
        self.btnRoleBle = QPushButton("Role: BLE")
        self.btnRoleBoth = QPushButton("Role: Both")
        self.btnRoleMesh = QPushButton("Role: Mesh")

        self.btnTxWifi = QPushButton("Tx: WiFi")
        self.btnTxEsp = QPushButton("Tx: ESP-NOW")
        self.btnTxSpi = QPushButton("Tx: SPI")
        self.btnTxWire = QPushButton("Tx: Wired")

        btnLayout.addWidget(self.btnRoleWifi)
        btnLayout.addWidget(self.btnRoleBle)
        btnLayout.addWidget(self.btnRoleBoth)
        btnLayout.addWidget(self.btnRoleMesh)
        btnLayout.addWidget(self.btnTxWifi)
        btnLayout.addWidget(self.btnTxEsp)
        btnLayout.addWidget(self.btnTxSpi)
        btnLayout.addWidget(self.btnTxWire)

        layout.addLayout(btnLayout)

        # Timer to refresh UI
        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(500)

    def refresh(self):
        nodes = self.registry.all()

        self.nodeTable.setRowCount(len(nodes))
        for i, n in enumerate(nodes):
            self.nodeTable.setItem(i, 0, QTableWidgetItem(n.id))
            self.nodeTable.setItem(i, 1, QTableWidgetItem(n.chip))
            self.nodeTable.setItem(i, 2, QTableWidgetItem(n.role))
            self.nodeTable.setItem(i, 3, QTableWidgetItem(n.transport))
            self.nodeTable.setItem(i, 4, QTableWidgetItem(
                f"{int(time.time() - n.last_seen)}s"
            ))


# ============================================================
# MAIN
# ============================================================

async def main():
    registry = NodeRegistry()
    pcap = PcapLogger()
    tcp = TcpCoordinator(registry, pcap)
    ble = BleConfigurator()
    espnow = EspNowBridge()
    cmd = CommandAPI(registry)

    # Start TCP coordinator
    tcp_task = asyncio.create_task(tcp.start())

    # Start ESP-NOW bridge (if enabled)
    esp_task = asyncio.create_task(espnow.start())

    # BLE initial config
    await ble.configure_nodes()

    # Start Qt UI
    app = QApplication(sys.argv)
    ui = CoordinatorUI(registry, cmd)
    ui.show()

    loop = asyncio.get_event_loop()
    loop.run_in_executor(None, app.exec)

    await asyncio.gather(tcp_task, esp_task)


if __name__ == "__main__":
    asyncio.run(main())