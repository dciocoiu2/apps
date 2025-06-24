# === PART 1: Initial Project Structure ===

$root = "amqp_broker"
$dirs = @(
    "$root", "$root\core", "$root\util", "$root\cluster",
    "$root\api", "$root\api\web", "$root\plugins", "tests", "$root\tests\brokers"
)

foreach ($d in $dirs) {
    if (!(Test-Path $d)) {
        New-Item -ItemType Directory $d | Out-Null
    }
}

function Write-CodeFile {
    param ([string]$Path, [string]$Content)
    $dir = Split-Path $Path
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory $dir -Force | Out-Null
    }
    Set-Content -Path $Path -Value $Content -Encoding UTF8
}

# === settings.json ===
@{
    tls = $false
    cert_file = "cert.pem"
    key_file  = "key.pem"
    jwt_secret = "secret"
    join_host = ""
    join_port = ""
    web_gui = $true
    admin_port = 15672
    users = @{ admin = "admin" }
    enable_plugins = $true
    enable_mqtt = $true
    enable_websockets = $true
} | ConvertTo-Json -Depth 3 | Set-Content "$root\settings.json"
# === config.py ===
Write-CodeFile "$root\config.py" @"
import json, os
def load_settings():
    with open(os.path.join(os.path.dirname(__file__), 'settings.json')) as f:
        return json.load(f)
"@

# === util\logging.py ===
Write-CodeFile "$root\util\logging.py" @"
import time
from util.logs import add_log

LEVELS = {'DEBUG': 0, 'INFO': 1, 'WARN': 2, 'ERROR': 3}
COLOR = {'DEBUG': '\033[36m', 'INFO': '\033[32m', 'WARN': '\033[33m', 'ERROR': '\033[31m', 'RESET': '\033[0m'}

def log(level, msg, **ctx):
    if LEVELS[level] < LEVELS['DEBUG']: return
    ts = time.strftime('%H:%M:%S')
    meta = ' '.join(f'{k}={v}' for k,v in ctx.items())
    print(f"[{ts}] [{COLOR[level]}{level}{COLOR['RESET']}] {msg} {meta}")
    add_log(level, msg, **ctx)

def info(m, **c): log('INFO', m, **c)
def debug(m, **c): log('DEBUG', m, **c)
def warn(m, **c): log('WARN', m, **c)
def error(m, **c): log('ERROR', m, **c)
"@

# === util\logs.py ===
Write-CodeFile "$root\util\logs.py" @"
from collections import deque
import time

log_history = deque(maxlen=500)

def add_log(level, msg, **ctx):
    log_history.append({
        'time': time.strftime('%Y-%m-%d %H:%M:%S'),
        'level': level,
        'msg': msg,
        'context': ctx
    })

def get_logs():
    return list(log_history)
"@

# === util\metrics.py ===
Write-CodeFile "$root\util\metrics.py" @"
from collections import defaultdict
import time

stats = defaultdict(lambda: {'enq': 0, 'del': 0, 'lat': []})

def enqueue(q, ts):
    stats[q]['enq'] += 1
    stats[q]['lat'].append(time.time() - ts)

def deliver(q):
    stats[q]['del'] += 1

def snapshot():
    return {
        'queues': {
            q: {
                'enqueued': s['enq'],
                'delivered': s['del'],
                'avg_latency': round(sum(s['lat']) / len(s['lat']), 3) if s['lat'] else 0
            }
            for q, s in stats.items()
        }
    }
"@

# === util\security.py ===
Write-CodeFile "$root\util\security.py" @"
import ssl

def build_tls_context(certfile, keyfile):
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(certfile, keyfile)
    return ctx
"@

# === util\plugins.py ===
Write-CodeFile "$root\util\plugins.py" @"
import importlib.util, os

hooks = {
    'on_start': [],
    'on_enqueue': [],
    'on_cluster_event': []
}

def load_plugins():
    for fname in os.listdir('plugins'):
        if fname.endswith('.py'):
            path = os.path.join('plugins', fname)
            name = fname[:-3]
            spec = importlib.util.spec_from_file_location(name, path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for h in hooks:
                if hasattr(mod, h):
                    hooks[h].append(getattr(mod, h))

def trigger(hook, *args, **kwargs):
    for fn in hooks.get(hook, []):
        try:
            fn(*args, **kwargs)
        except Exception as e:
            print(f"[Plugin error] {fn.__name__}: {e}")
"@

# === core\queue.py ===
Write-CodeFile "$root\core\queue.py" @"
import time
from collections import deque
from util.metrics import enqueue, deliver
from util.plugins import trigger

queues = {}

class Queue:
    def __init__(self, name):
        self.name = name
        self.q = deque()
        self.c = []

    def enqueue(self, msg):
        ts = time.time()
        self.q.append((msg, ts))
        enqueue(self.name, ts)
        trigger('on_enqueue', queue=self.name, message=msg)
        self._deliver()

    def register(self, fn):
        self.c.append(fn)
        self._deliver()

    def _deliver(self):
        while self.q and self.c:
            msg, _ = self.q.popleft()
            for fn in self.c: fn(msg)
            deliver(self.name)

def get_or_create_queue(name):
    if name not in queues:
        queues[name] = Queue(name)
    return queues[name]
"@
# === cluster\peerlink.py ===
Write-CodeFile "$root\cluster\peerlink.py" @"
import time, threading, requests
from util.plugins import trigger

PEERS = {}
NODE_ID = 'node-' + str(int(time.time()))

def register_peer(node_id, host, port):
    if node_id != NODE_ID:
        PEERS[node_id] = {'host': host, 'port': port, 'last_seen': time.time()}
        trigger('on_cluster_event', event='join', peer=node_id)

def join_network(host, port):
    try:
        r = requests.post(f"http://{host}:{port}/join", json={
            'node_id': NODE_ID,
            'host': 'localhost',
            'port': 5672
        })
        for peer in r.json().get('peers', []):
            register_peer(**peer)
    except Exception as e:
        print(f"[Join fail] {e}")

def heartbeat_loop():
    while True:
        time.sleep(10)
        for nid, p in list(PEERS.items()):
            try:
                r = requests.get(f"http://{p['host']}:{p['port']}/ping", timeout=2)
                if r.status_code == 200:
                    p['last_seen'] = time.time()
                else:
                    PEERS.pop(nid, None)
                    trigger('on_cluster_event', event='drop', peer=nid)
            except:
                PEERS.pop(nid, None)
                trigger('on_cluster_event', event='drop', peer=nid)

def start_heartbeat():
    threading.Thread(target=heartbeat_loop, daemon=True).start()
"@

# === cluster\replicator.py ===
Write-CodeFile "$root\cluster\replicator.py" @"
import uuid, time, requests
from cluster.peerlink import PEERS

REPL_CACHE = set()

def replicate(queue, body):
    payload = {
        'queue': queue,
        'body': body,
        'msg_id': str(uuid.uuid4()),
        'expires': time.time() + 60
    }
    for p in PEERS.values():
        try:
            requests.post(f"http://{p['host']}:{p['port']}/replicate", json=payload, timeout=2)
        except:
            pass

def handle(payload, enqueue_fn):
    if payload['msg_id'] in REPL_CACHE or time.time() > payload['expires']:
        return False
    REPL_CACHE.add(payload['msg_id'])
    enqueue_fn(payload['queue'], payload['body'])
    return True
"@
Write-CodeFile "$root\api\http_api.py" @"
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from core.queue import get_or_create_queue
from cluster.peerlink import register_peer, PEERS, NODE_ID
from cluster.replicator import handle as handle_rep
from util.metrics import snapshot
from util.logs import get_logs

class APIHandler(BaseHTTPRequestHandler):
    def _send(self, code, data, typ='json'):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json' if typ == 'json' else 'text/html')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode() if typ == 'json' else data)

    def do_GET(self):
        path = self.path
        if path == '/metrics':
            return self._send(200, snapshot())
        elif path == '/topology':
            return self._send(200, {'self': NODE_ID, 'peers': list(PEERS.keys())})
        elif path == '/ping':
            return self._send(200, {'pong': True})
        elif path == '/logs':
            return self._send(200, get_logs())
        elif path.startswith('/web'):
            fn = path[5:] or 'index.html'
            file_path = os.path.join(os.path.dirname(__file__), 'web', fn)
            if os.path.exists(file_path):
                mime = 'text/html' if fn.endswith('.html') else 'application/javascript'
                with open(file_path, 'rb') as f:
                    return self._send(200, f.read(), mime)
            return self._send(404, {'error': 'file not found'})
        elif path == '/':
            with open(os.path.join(os.path.dirname(__file__), 'web', 'index.html'), 'rb') as f:
                return self._send(200, f.read(), 'text/html')
        else:
            return self._send(404, {'error': 'unknown path'})

    def do_POST(self):
        l = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(l).decode()
        try:
            payload = json.loads(raw)
        except:
            return self._send(400, {'error': 'Invalid JSON'})
        if self.path == '/join':
            id, h, p = payload.get('node_id'), payload.get('host'), payload.get('port')
            if id and h and p:
                register_peer(id, h, p)
                return self._send(200, {'joined': True})
            return self._send(400, {'error': 'Missing fields'})
        elif self.path == '/replicate':
            ok = handle_rep(payload, lambda q, b: get_or_create_queue(q).enqueue(b))
            return self._send(200, {'status': 'ok' if ok else 'skipped'})
        else:
            return self._send(404, {'error': 'unknown POST endpoint'})

def run_http_api():
    HTTPServer(('0.0.0.0', 15672), APIHandler).serve_forever()
"@
Write-CodeFile "$root\api\web\index.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>AMQP Broker Dashboard</title>
  <script src='dashboard.js' defer></script>
</head>
<body>
  <h1>AMQP Broker Dashboard</h1>
  <section><h2>Queue Metrics</h2><pre id='metrics'></pre></section>
  <section><h2>Topology</h2><pre id='topology'></pre>
    <form id='joinForm'>
      <input name='host' placeholder='Host' />
      <input name='port' placeholder='Port' />
      <button>Join Cluster</button>
    </form>
  </section>
  <section><h2>Recent Logs</h2><pre id='logs'></pre></section>
  <a href="/web/stats.html">📈 Live Charts</a>
</body>
</html>
"@
Write-CodeFile "$root\api\web\dashboard.js" @"
async function load(path) {
  try { const r = await fetch(path); return await r.json(); }
  catch (e) { return {}; }
}

async function refresh() {
  const m = await load('/metrics');
  const t = await load('/topology');
  const l = await load('/logs');

  document.getElementById('metrics').textContent = JSON.stringify(m, null, 2);
  document.getElementById('topology').textContent = JSON.stringify(t, null, 2);
  document.getElementById('logs').textContent = l.map(x => \`[\${x.time}] \${x.level}: \${x.msg}\`).join('\\n');
}

document.getElementById('joinForm').onsubmit = async e => {
  e.preventDefault();
  const f = e.target;
  await fetch('/join', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ node_id: 'manual-' + Date.now(), host: f.host.value, port: parseInt(f.port.value) })
  });
  refresh();
};

setInterval(refresh, 5000);
refresh();
"@
# === api\web\stats.html ===
Write-CodeFile "$root\api\web\stats.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>📈 Broker Stats</title>
  <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
  <script src='stats.js' defer></script>
</head>
<body>
  <h1>📊 Live Queue Stats</h1>
  <canvas id='qChart' width='800' height='300'></canvas>
  <canvas id='latChart' width='800' height='300'></canvas>
</body>
</html>
"@

# === api\web\stats.js ===
Write-CodeFile "$root\api\web\stats.js" @"
const ctxQ = document.getElementById('qChart').getContext('2d');
const ctxL = document.getElementById('latChart').getContext('2d');

const qChart = new Chart(ctxQ, {
  type: 'bar',
  data: { labels: [], datasets: [
    { label: 'Enqueued', data: [], backgroundColor: '#4e79a7' },
    { label: 'Delivered', data: [], backgroundColor: '#f28e2b' }
  ]},
  options: { scales: { y: { beginAtZero: true } } }
});

const latChart = new Chart(ctxL, {
  type: 'line',
  data: { labels: [], datasets: [
    { label: 'Avg Latency (s)', data: [], borderColor: '#59a14f', fill: false }
  ]},
  options: { scales: { y: { beginAtZero: true } } }
});

async function update() {
  const r = await fetch('/metrics').then(res => res.json());
  const q = r.queues || {};
  const keys = Object.keys(q);
  qChart.data.labels = keys;
  qChart.data.datasets[0].data = keys.map(k => q[k].enqueued);
  qChart.data.datasets[1].data = keys.map(k => q[k].delivered);
  qChart.update();

  latChart.data.labels = keys;
  latChart.data.datasets[0].data = keys.map(k => q[k].avg_latency);
  latChart.update();
}

setInterval(update, 3000);
update();
"@
Write-CodeFile "$root\broker.py" @"
import threading, socket, sys
from config import load_settings
from util.logging import info, warn
from util.security import build_tls_context
from util.plugins import load_plugins
from api.http_api import run_http_api
from cluster.peerlink import join_network, start_heartbeat

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except:
        return 'localhost'

def print_endpoints(ip, port):
    print()
    print(f'🌐 Web UI:           http://{ip}:{port}/')
    print(f'📊 Charts:           http://{ip}:{port}/web/stats.html')
    print(f'📈 Metrics API:      http://{ip}:{port}/metrics')
    print(f'🛰️ Topology:         http://{ip}:{port}/topology')
    print(f'📝 Logs:             http://{ip}:{port}/logs')
    print(f'📬 POST /replicate & /join to cluster\n')

def main():
    try:
        cfg = load_settings()
    except Exception as e:
        print(f'[CONFIG_FAILED] Failed to load config: {e}')
        sys.exit(1)

    port = cfg.get('admin_port', 15672)
    ip = get_local_ip()

    if cfg.get('tls'):
        cert, key = cfg.get('cert_file'), cfg.get('key_file')
        if cert and key:
            build_tls_context(cert, key)
            info('TLS context initialized.')
        else:
            warn('TLS enabled but cert/key missing.')

    if cfg.get('enable_plugins'):
        load_plugins()
        info('Plugins loaded.')

    start_heartbeat()
    host, jport = cfg.get('join_host'), cfg.get('join_port')
    if host and jport:
        info('Joining cluster', target=f'{host}:{jport}')
        join_network(host, jport)
    else:
        info('Standalone mode.')

    threading.Thread(target=run_http_api, daemon=True).start()
    print_endpoints(ip, port)
    info('Broker ready.')
    threading.Event().wait()

if __name__ == '__main__':
    main()
"@

Write-CodeFile "$root\plugins\echo_logger.py" @"
def on_start():
    print('[Plugin] echo_logger started')

def on_enqueue(queue, message):
    print(f'[echo_logger] {queue} received: {message}')

def on_cluster_event(event, peer):
    print(f'[echo_logger] Cluster event: {event} peer={peer}')
"@
Write-CodeFile "$root\plugins\websocket_echo.py" @"
import asyncio, threading
import websockets

async def echo(ws, path):
    async for msg in ws:
        await ws.send(f'ECHO: {msg}')

def on_start():
    def run():
        asyncio.run(websockets.serve(echo, '0.0.0.0', 8765))
    threading.Thread(target=run, daemon=True).start()
    print('[Plugin] WebSocket echo bridge on ws://localhost:8765')
"@
Write-CodeFile "$root\plugins\mqtt_bridge.py" @"
import paho.mqtt.client as mqtt
from core.queue import get_or_create_queue

def on_message(client, userdata, msg):
    q = get_or_create_queue(msg.topic)
    q.enqueue(msg.payload.decode())

def on_start():
    cli = mqtt.Client()
    cli.on_message = on_message
    cli.connect('broker.hivemq.com', 1883)
    cli.subscribe('#')
    cli.loop_start()
    print('[Plugin] MQTT bridge connected')
"@
Write-CodeFile "tests\broker_runner.py" @"
import subprocess, os, shutil, json

def launch_broker(name, port, join=None):
    path = f'tests/brokers/{name}'
    shutil.copytree('amqp_broker', f'{path}/code', dirs_exist_ok=True)
    conf = {
        'tls': False,
        'admin_port': port,
        'join_host': join[0] if join else None,
        'join_port': join[1] if join else None,
        'enable_plugins': False
    }
    with open(f'{path}/code/settings.json', 'w') as f:
        json.dump(conf, f)
    return subprocess.Popen(['python', 'broker.py'], cwd=f'{path}/code')

def shutdown_brokers(procs):
    for p in procs: p.terminate()
"@
Write-CodeFile "tests\test_broker.py" @"
import pytest, requests, time
from broker_runner import launch_broker, shutdown_brokers

@pytest.fixture(scope='session')
def brokers():
    ports = [15701, 15702]
    procs = []
    for i, port in enumerate(ports):
        join = ('localhost', ports[0]) if i > 0 else None
        procs.append(launch_broker(f'node{i}', port, join))
    time.sleep(3)
    yield ports
    shutdown_brokers(procs)

def test_metrics(brokers):
    r = requests.get(f"http://localhost:{brokers[0]}/metrics")
    assert r.status_code == 200

def test_topology(brokers):
    r = requests.get(f"http://localhost:{brokers[1]}/topology")
    assert 'peers' in r.json()

def test_logs(brokers):
    r = requests.get(f"http://localhost:{brokers[0]}/logs")
    assert isinstance(r.json(), list)
"@
Write-Host "PROJECT BUILT AT"