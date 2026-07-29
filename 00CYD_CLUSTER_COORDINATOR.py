#!/usr/bin/env python3
"""
FULL CLUSTER COORDINATOR (Single File)
- BLE initial config (Bleak)
- TCP telemetry + commands
- Unified JSON protocol
- PCAP logging
- Web UI (Flask): dashboard + map
- Per-node traces
- Filters (SSID/BSSID/channel/RSSI/node)
- Export (GeoJSON + JSON)
- Auto-disable ESP-NOW on non-IoT hosts
- No node firmware changes required
"""

import asyncio
import json
import platform
import time
from dataclasses import dataclass, field
from typing import Dict, Optional, List

from threading import Thread

from bleak import BleakScanner, BleakClient
from flask import Flask, render_template_string, jsonify, request

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
# NODE + SCAN MODEL
# ============================================================

@dataclass
class Node:
    id: str
    chip: str
    role: str
    transport: str
    last_seen: float
    writer: Optional[asyncio.StreamWriter] = field(default=None)


@dataclass
class WifiScanEntry:
    node_id: str
    ssid: str
    bssid: str
    rssi: int
    channel: int
    ts: float
    lat: Optional[float] = None
    lon: Optional[float] = None


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


class ScanStore:
    def __init__(self):
        self.wifi_scans: List[WifiScanEntry] = []

    def add_wifi_scan(self, node_id: str, ssid: str, bssid: str,
                      rssi: int, channel: int,
                      lat: float = None, lon: float = None):
        self.wifi_scans.append(
            WifiScanEntry(
                node_id=node_id,
                ssid=ssid,
                bssid=bssid,
                rssi=rssi,
                channel=channel,
                ts=time.time(),
                lat=lat,
                lon=lon,
            )
        )

    def all_wifi(self) -> List[WifiScanEntry]:
        return self.wifi_scans

    def filtered_wifi(self,
                      node_id: Optional[str] = None,
                      ssid: Optional[str] = None,
                      bssid: Optional[str] = None,
                      min_rssi: Optional[int] = None,
                      max_rssi: Optional[int] = None,
                      channel: Optional[int] = None) -> List[WifiScanEntry]:
        out = []
        for s in self.wifi_scans:
            if node_id and s.node_id != node_id:
                continue
            if ssid and ssid not in s.ssid:
                continue
            if bssid and bssid.lower() not in s.bssid.lower():
                continue
            if channel and s.channel != channel:
                continue
            if min_rssi is not None and s.rssi < min_rssi:
                continue
            if max_rssi is not None and s.rssi > max_rssi:
                continue
            out.append(s)
        return out

    def per_node_traces(self) -> Dict[str, List[WifiScanEntry]]:
        traces: Dict[str, List[WifiScanEntry]] = {}
        for s in self.wifi_scans:
            traces.setdefault(s.node_id, []).append(s)
        for node_id in traces:
            traces[node_id].sort(key=lambda e: e.ts)
        return traces


# ============================================================
# TCP COORDINATOR
# ============================================================

class TcpCoordinator:
    def __init__(self, registry: NodeRegistry, pcap: PcapLogger,
                 scan_store: ScanStore,
                 host="0.0.0.0", port=3333):
        self.registry = registry
        self.pcap = pcap
        self.scan_store = scan_store
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

                    msg_type = msg.get("type")

                    if msg_type == "scan_wifi":
                        ssid   = msg.get("ssid", "")
                        bssid  = msg.get("bssid", "")
                        rssi   = int(msg.get("rssi", 0))
                        ch     = int(msg.get("ch", 0))
                        lat    = msg.get("lat")
                        lon    = msg.get("lon")
                        self.scan_store.add_wifi_scan(
                            node_id, ssid, bssid, rssi, ch,
                            lat=lat, lon=lon
                        )

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
# WEB UI (Flask)
# ============================================================

app = Flask(__name__)

DASHBOARD_HTML = """
<!doctype html>
<html>
<head>
  <title>Cluster Dashboard</title>
  <style>
    body { font-family: sans-serif; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1em; }
    th, td { border: 1px solid #ccc; padding: 4px; font-size: 12px; }
    input { margin: 2px; }
  </style>
</head>
<body>
  <h1>Cluster Dashboard</h1>

  <h2>Filters</h2>
  <form method="get" action="/">
    Node ID: <input name="node_id" value="{{ filters.node_id or '' }}">
    SSID: <input name="ssid" value="{{ filters.ssid or '' }}">
    BSSID: <input name="bssid" value="{{ filters.bssid or '' }}">
    Min RSSI: <input name="min_rssi" value="{{ filters.min_rssi or '' }}">
    Max RSSI: <input name="max_rssi" value="{{ filters.max_rssi or '' }}">
    Channel: <input name="channel" value="{{ filters.channel or '' }}">
    <button type="submit">Apply</button>
  </form>

  <p>
    Export:
    <a href="/export/json">JSON</a> |
    <a href="/export/geojson">GeoJSON</a> |
    <a href="/map">Map view</a>
  </p>

  <h2>Nodes</h2>
  <table>
    <tr><th>ID</th><th>Chip</th><th>Role</th><th>Transport</th><th>Last Seen</th></tr>
    {% for n in nodes %}
    <tr>
      <td>{{ n.id }}</td>
      <td>{{ n.chip }}</td>
      <td>{{ n.role }}</td>
      <td>{{ n.transport }}</td>
      <td>{{ (now - n.last_seen)|int }}s</td>
    </tr>
    {% endfor %}
  </table>

  <h2>WiFi Scans</h2>
  <table>
    <tr><th>Node</th><th>SSID</th><th>BSSID</th><th>RSSI</th><th>Ch</th><th>Age</th></tr>
    {% for s in scans %}
    <tr>
      <td>{{ s.node_id }}</td>
      <td>{{ s.ssid }}</td>
      <td>{{ s.bssid }}</td>
      <td>{{ s.rssi }}</td>
      <td>{{ s.channel }}</td>
      <td>{{ (now - s.ts)|int }}s</td>
    </tr>
    {% endfor %}
  </table>

  <h2>Per-node traces</h2>
  {% for node_id, trace in traces.items() %}
    <h3>{{ node_id }}</h3>
    <table>
      <tr><th>Time</th><th>SSID</th><th>BSSID</th><th>RSSI</th><th>Ch</th></tr>
      {% for s in trace %}
      <tr>
        <td>{{ s.ts }}</td>
        <td>{{ s.ssid }}</td>
        <td>{{ s.bssid }}</td>
        <td>{{ s.rssi }}</td>
        <td>{{ s.channel }}</td>
      </tr>
      {% endfor %}
    </table>
  {% endfor %}
</body>
</html>
"""

MAP_HTML = """
<!doctype html>
<html>
<head>
  <title>Cluster Map</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet"
        href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <style>
    body { margin: 0; padding: 0; }
    #map { width: 100vw; height: 100vh; }
  </style>
</head>
<body>
<div id="map"></div>
<script>
  const map = L.map('map').setView([0, 0], 2);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19
  }).addTo(map);

  const params = new URLSearchParams(window.location.search);
  const url = '/api/map_data?' + params.toString();

  fetch(url)
    .then(r => r.json())
    .then(data => {
      if (data.length > 0) {
        const first = data[0];
        map.setView([first.lat, first.lon], 10);
      }
      data.forEach(d => {
        const circle = L.circleMarker([d.lat, d.lon], {
          radius: d.size,
          color: d.color,
          fillColor: d.color,
          fillOpacity: 0.7
        }).addTo(map);
        circle.bindPopup(
          `SSID: ${d.ssid}<br>` +
          `BSSID: ${d.bssid}<br>` +
          `RSSI: ${d.rssi}<br>` +
          `Ch: ${d.channel}<br>` +
          `Node: ${d.node_id}`
        );
      });
    });
</script>
</body>
</html>
"""

# globals set in main()
registry: NodeRegistry = None
scan_store: ScanStore = None

@app.route("/")
def dashboard():
    now = time.time()
    nodes = registry.all()

    node_id = request.args.get("node_id") or None
    ssid = request.args.get("ssid") or None
    bssid = request.args.get("bssid") or None
    min_rssi = request.args.get("min_rssi")
    max_rssi = request.args.get("max_rssi")
    channel = request.args.get("channel")

    def to_int_or_none(v):
        try:
            return int(v)
        except:
            return None

    min_rssi_i = to_int_or_none(min_rssi)
    max_rssi_i = to_int_or_none(max_rssi)
    channel_i = to_int_or_none(channel)

    scans = scan_store.filtered_wifi(
        node_id=node_id,
        ssid=ssid,
        bssid=bssid,
        min_rssi=min_rssi_i,
        max_rssi=max_rssi_i,
        channel=channel_i,
    )

    traces = scan_store.per_node_traces()

    filters = {
        "node_id": node_id,
        "ssid": ssid,
        "bssid": bssid,
        "min_rssi": min_rssi,
        "max_rssi": max_rssi,
        "channel": channel,
    }

    return render_template_string(DASHBOARD_HTML,
                                  nodes=nodes,
                                  scans=scans,
                                  traces=traces,
                                  now=now,
                                  filters=filters)

@app.route("/map")
def map_view():
    return render_template_string(MAP_HTML)

@app.route("/api/map_data")
def map_data():
    node_id = request.args.get("node_id") or None
    ssid = request.args.get("ssid") or None
    bssid = request.args.get("bssid") or None
    min_rssi = request.args.get("min_rssi")
    max_rssi = request.args.get("max_rssi")
    channel = request.args.get("channel")

    def to_int_or_none(v):
        try:
            return int(v)
        except:
            return None

    min_rssi_i = to_int_or_none(min_rssi)
    max_rssi_i = to_int_or_none(max_rssi)
    channel_i = to_int_or_none(channel)

    scans = scan_store.filtered_wifi(
        node_id=node_id,
        ssid=ssid,
        bssid=bssid,
        min_rssi=min_rssi_i,
        max_rssi=max_rssi_i,
        channel=channel_i,
    )

    data = []
    for s in scans:
        lon = (s.channel - 1) * 5.0 if s.lon is None else s.lon
        lat = (s.rssi + 100) * 0.1 if s.lat is None else s.lat

        if s.rssi > -50:
            color = "green"
        elif s.rssi > -70:
            color = "orange"
        else:
            color = "red"

        size = max(4, min(12, int((100 + s.rssi) / 5)))

        data.append({
            "node_id": s.node_id,
            "ssid": s.ssid,
            "bssid": s.bssid,
            "rssi": s.rssi,
            "channel": s.channel,
            "lat": lat,
            "lon": lon,
            "color": color,
            "size": size,
        })
    return jsonify(data)

@app.route("/export/json")
def export_json():
    scans = scan_store.all_wifi()
    out = []
    for s in scans:
        out.append({
            "node_id": s.node_id,
            "ssid": s.ssid,
            "bssid": s.bssid,
            "rssi": s.rssi,
            "channel": s.channel,
            "ts": s.ts,
            "lat": s.lat,
            "lon": s.lon,
        })
    return jsonify(out)

@app.route("/export/geojson")
def export_geojson():
    scans = scan_store.all_wifi()
    features = []
    for s in scans:
        lon = s.lon if s.lon is not None else (s.channel - 1) * 5.0
        lat = s.lat if s.lat is not None else (s.rssi + 100) * 0.1
        features.append({
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [lon, lat],
            },
            "properties": {
                "node_id": s.node_id,
                "ssid": s.ssid,
                "bssid": s.bssid,
                "rssi": s.rssi,
                "channel": s.channel,
                "ts": s.ts,
            }
        })
    return jsonify({
        "type": "FeatureCollection",
        "features": features
    })


# ============================================================
# MAIN
# ============================================================

async def main():
    global registry, scan_store
    registry = NodeRegistry()
    scan_store = ScanStore()
    pcap = PcapLogger()
    tcp = TcpCoordinator(registry, pcap, scan_store)
    ble = BleConfigurator()
    espnow = EspNowBridge()
    cmd = CommandAPI(registry)

    tcp_task = asyncio.create_task(tcp.start())
    esp_task = asyncio.create_task(espnow.start())

    await ble.configure_nodes()

    def run_flask():
        app.run(host="0.0.0.0", port=8080, debug=False)

    flask_thread = Thread(target=run_flask, daemon=True)
    flask_thread.start()

    await asyncio.gather(tcp_task, esp_task)


if __name__ == "__main__":
    asyncio.run(main())