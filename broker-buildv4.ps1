# === Broker Setup — Directories & Utilities ===

$root = "amqp_broker"
$dirs = @(
  "$root", "$root\\core", "$root\\util", "$root\\cluster",
  "$root\\api", "$root\\api\\web", "$root\\plugins", "tests", "tests\\brokers"
)
foreach ($d in $dirs) {
  if (!(Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
}

function Write-CodeFile {
  param ([string]$Path, [string]$Content)
  $dir = Split-Path $Path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}
# === Configuration Files ===

@{
  jwt_secret = "supersecret"
  admin_port = 15672
  tls = $false
  web_gui = $true
  enable_plugins = $true
  users = @{
    admin = @{ password = "admin123"; roles = @("admin", "reader", "writer") }
    viewer = @{ password = "viewerpass"; roles = @("reader") }
    writer = @{ password = "writerpass"; roles = @("writer") }
  }
} | ConvertTo-Json -Depth 5 | Set-Content "$root\\settings.json"

Write-CodeFile "$root\\config.py" @"
import json, os
def load_settings():
    with open(os.path.join(os.path.dirname(__file__), 'settings.json')) as f:
        return json.load(f)
"@
# === Token Auth (JWT) ===

Write-CodeFile "$root\\util\\auth.py" @"
import time, jwt
from config import load_settings

cfg = load_settings()
SECRET = cfg['jwt_secret']
USERS = cfg['users']

def generate_token(username):
    roles = USERS.get(username, {}).get('roles', [])
    payload = { 'user': username, 'roles': roles, 'exp': time.time() + 3600 }
    return jwt.encode(payload, SECRET, algorithm='HS256')

def validate_token(token, required_roles=None):
    try:
        decoded = jwt.decode(token, SECRET, algorithms=['HS256'])
        if required_roles:
            return any(r in decoded['roles'] for r in required_roles)
        return True
    except: return False

def login(u, p):
    user = USERS.get(u)
    if user and user.get('password') == p:
        return generate_token(u)
    return None
"@
# === util\plugins.py ===
Write-CodeFile "$root\\util\\plugins.py" @"
import importlib.util, os

hooks = { 'on_start': [], 'on_enqueue': [], 'on_cluster_event': [] }

def load_plugins():
    for f in os.listdir('plugins'):
        if not f.endswith('.py'): continue
        path = os.path.join('plugins', f)
        spec = importlib.util.spec_from_file_location(f[:-3], path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        roles = getattr(mod, 'allowed_roles', [])
        if 'admin' in roles or not roles:
            for h in hooks:
                if hasattr(mod, h): hooks[h].append(getattr(mod, h))

def trigger(h, *a, **kw):
    for fn in hooks.get(h, []):
        try: fn(*a, **kw)
        except Exception as e:
            print(f"[Plugin error] {fn.__name__}: {e}")
"@

# === util\metrics.py ===
Write-CodeFile "$root\\util\\metrics.py" @"
from collections import defaultdict
import time
stats = defaultdict(lambda: {'enq': 0, 'del': 0, 'lat': []})

def enqueue(q, ts): stats[q]['enq'] += 1; stats[q]['lat'].append(time.time() - ts)
def deliver(q): stats[q]['del'] += 1

def snapshot():
    return {
        'queues': {
            q: {
                'enqueued': s['enq'],
                'delivered': s['del'],
                'avg_latency': round(sum(s['lat']) / len(s['lat']), 3) if s['lat'] else 0
            } for q, s in stats.items()
        }
    }
"@

# === util\logs.py ===
Write-CodeFile "$root\\util\\logs.py" @"
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

# === util\logging.py ===
Write-CodeFile "$root\\util\\logging.py" @"
import time
from util.logs import add_log

def log(level, msg, **ctx):
    ts = time.strftime('%H:%M:%S')
    print(f"[{ts}] [{level.upper()}] {msg} {ctx}")
    add_log(level, msg, **ctx)

def info(msg, **ctx): log('info', msg, **ctx)
def warn(msg, **ctx): log('warn', msg, **ctx)
def error(msg, **ctx): log('error', msg, **ctx)
"@

# === core\queue.py ===
Write-CodeFile "$root\\core\\queue.py" @"
import time
from collections import deque
from util.metrics import enqueue, deliver
from util.plugins import trigger

queues = {}

class Queue:
    def __init__(self, name): self.name, self.q, self.c = name, deque(), []

    def enqueue(self, msg):
        ts = time.time()
        self.q.append((msg, ts))
        enqueue(self.name, ts)
        trigger('on_enqueue', queue=self.name, message=msg)
        self._deliver()

    def register(self, fn): self.c.append(fn); self._deliver()

    def _deliver(self):
        while self.q and self.c:
            msg, _ = self.q.popleft()
            for fn in self.c: fn(msg)
            deliver(self.name)

def get_or_create_queue(name):
    if name not in queues: queues[name] = Queue(name)
    return queues[name]
"@
# === api\http_api.py ===
Write-CodeFile "$root\\api\\http_api.py" @"
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from core.queue import get_or_create_queue
from cluster.peerlink import register_peer, PEERS, NODE_ID
from cluster.replicator import handle as handle_rep
from util.metrics import snapshot
from util.logs import get_logs
from util.auth import login, validate_token

class APIHandler(BaseHTTPRequestHandler):
    def _send(self, code, data, typ='json'):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json' if typ == 'json' else 'text/html')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode() if typ == 'json' else data)

    def _authed(self, role=None):
        auth = self.headers.get('Authorization', '')
        if auth.startswith('Bearer '):
            token = auth.split(' ')[1]
            return validate_token(token, [role] if role else None)
        return False

    def do_POST(self):
        l = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(l).decode()
        try: payload = json.loads(raw)
        except: return self._send(400, {'error': 'invalid json'})

        if self.path == '/auth':
            t = login(payload.get('username'), payload.get('password'))
            return self._send(200, {'token': t} if t else {'error': 'unauthorized'})

        if self.path == '/join':
            id, h, p = payload.get('node_id'), payload.get('host'), payload.get('port')
            if id and h and p:
                register_peer(id, h, p)
                return self._send(200, {'joined': True})
            return self._send(400, {'error': 'missing fields'})

        if self.path == '/replicate':
            if not self._authed('writer'): return self._send(403, {'error': 'unauthorized'})
            ok = handle_rep(payload, lambda q,b: get_or_create_queue(q).enqueue(b))
            return self._send(200, {'status': 'ok' if ok else 'skipped'})

        return self._send(404, {'error': 'not found'})

    def do_GET(self):
        if self.path == '/metrics' and self._authed('reader'):
            return self._send(200, snapshot())
        elif self.path == '/topology' and self._authed('reader'):
            return self._send(200, {'self': NODE_ID, 'peers': list(PEERS.keys())})
        elif self.path == '/logs' and self._authed('reader'):
            return self._send(200, get_logs())
        elif self.path == '/ping':
            return self._send(200, {'pong': True})
        elif self.path.startswith('/web'):
            fn = self.path[5:] or 'index.html'
            fp = os.path.join(os.path.dirname(__file__), 'web', fn)
            if os.path.exists(fp):
                with open(fp, 'rb') as f:
                    typ = 'text/html' if fn.endswith('.html') else 'application/javascript'
                    return self._send(200, f.read(), typ)
            return self._send(404, {'error': 'not found'})
        elif self.path == '/':
            with open(os.path.join(os.path.dirname(__file__), 'web', 'index.html'), 'rb') as f:
                return self._send(200, f.read(), 'text/html')
        else:
            return self._send(403, {'error': 'unauthorized'})

def run_http_api(host='0.0.0.0', port=15672):
    HTTPServer((host, port), APIHandler).serve_forever()
"@
# === cluster\peerlink.py ===
Write-CodeFile "$root\\cluster\\peerlink.py" @"
import time, threading, requests
from util.plugins import trigger

PEERS = {}
NODE_ID = 'node-' + str(int(time.time()))

def register_peer(id, h, p):
    if id != NODE_ID:
        PEERS[id] = {'host': h, 'port': p, 'last_seen': time.time()}
        trigger('on_cluster_event', event='join', peer=id)

def join_network(h, p):
    try:
        r = requests.post(f"http://{h}:{p}/join", json={'node_id': NODE_ID,'host':'localhost','port':5672})
        for peer in r.json().get('peers', []): register_peer(**peer)
    except Exception as e: print("[Join fail]", e)

def heartbeat_loop():
    while True:
        time.sleep(10)
        for nid, peer in list(PEERS.items()):
            try:
                r = requests.get(f"http://{peer['host']}:{peer['port']}/ping", timeout=2)
                if r.status_code == 200: peer['last_seen'] = time.time()
                else: PEERS.pop(nid, None); trigger('on_cluster_event', event='drop', peer=nid)
            except: PEERS.pop(nid, None); trigger('on_cluster_event', event='drop', peer=nid)

def start_heartbeat(): threading.Thread(target=heartbeat_loop, daemon=True).start()
"@
# === broker.py ===
Write-CodeFile "$root\\broker.py" @"
import threading, socket, sys
from config import load_settings
from util.logging import info
from util.plugins import load_plugins
from api.http_api import run_http_api
from cluster.peerlink import join_network, start_heartbeat

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except: return '127.0.0.1'

def print_endpoints(ip, port):
    print()
    print(f'Dashboard: http://{ip}:{port}/web/')
    print(f' Metrics:   /metrics (RBAC)')
    print(f'Replicate: /replicate (RBAC)')
    print(f' Login:     POST /auth {"{username, password}"}\n')

def main():
    try:
        cfg = load_settings()
    except Exception as e:
        print(f' Config error: {e}')
        sys.exit(1)

    port = cfg.get('admin_port', 15672)
    ip = get_local_ip()

    if cfg.get('enable_plugins'):
        load_plugins(); info("Plugins loaded")

    start_heartbeat()
    h, p = cfg.get('join_host'), cfg.get('join_port')
    if h and p: join_network(h, p)

    threading.Thread(target=lambda: run_http_api(ip, port), daemon=True).start()
    print_endpoints(ip, port)
    info("Broker ready."); threading.Event().wait()

if __name__ == '__main__':
    main()
"@
# === plugins\echo_logger.py ===
Write-CodeFile "$root\\plugins\\echo_logger.py" @"
allowed_roles = ['admin']

def on_start():
    print('[Plugin] Echo logger loaded.')

def on_enqueue(queue, message):
    print(f'[Echo] Queue=\{queue\} → \{message\}')

def on_cluster_event(event, peer):
    print(f'[Cluster] \{event.upper()\} event from peer: \{peer\}')
"@

# === tests\test_auth.py ===
Write-CodeFile "$root\\tests\\test_auth.py" @"
import requests
def test_token_auth():
    r = requests.post('http://localhost:15672/auth', json={'username': 'admin', 'password': 'admin123'})
    assert r.status_code == 200
    assert 'token' in r.json()
"@

# === api\web\index.html ===
Write-CodeFile "$root\\api\\web\\index.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>AMQP Broker Dashboard</title>
  <script src='/web/dashboard.js' defer></script>
</head>
<body>
  <h1>📡 Broker Dashboard</h1>
  <section>
    <h2>Metrics</h2>
    <pre id='metrics'></pre>
    <h2>Topology</h2>
    <pre id='topology'></pre>
    <h2>Logs</h2>
    <pre id='logs'></pre>
    <h2>Charts</h2>
    <a href='/web/stats.html'>📈 View Charts</a>
  </section>
</body>
</html>
"@

# === api\web\dashboard.js ===
Write-CodeFile "$root\\api\\web\\dashboard.js" @"
const token = prompt('Bearer token:')
async function get(path) {
  const res = await fetch(path, { headers: { Authorization: 'Bearer ' + token } })
  return await res.json()
}
async function update() {
  const m = await get('/metrics')
  const t = await get('/topology')
  const l = await get('/logs')
  document.getElementById('metrics').textContent = JSON.stringify(m, null, 2)
  document.getElementById('topology').textContent = JSON.stringify(t, null, 2)
  document.getElementById('logs').textContent = l.map(e => \`[\${e.time}] \${e.level}: \${e.msg}\`).join('\\n')
}
setInterval(update, 4000); update()
"@

# === api\web\stats.html ===
Write-CodeFile "$root\\api\\web\\stats.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>Broker Charts</title>
  <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
  <script src='/web/stats.js' defer></script>
</head>
<body>
  <h1>📊 Real-Time Charts</h1>
  <canvas id='qChart' width='800' height='300'></canvas>
  <canvas id='latChart' width='800' height='300'></canvas>
</body>
</html>
"@

# === api\web\stats.js ===
Write-CodeFile "$root\\api\\web\\stats.js" @"
const token = prompt('Bearer token:')
const ctxQ = document.getElementById('qChart').getContext('2d')
const ctxL = document.getElementById('latChart').getContext('2d')

const qChart = new Chart(ctxQ, {
  type: 'bar',
  data: { labels: [], datasets: [
    { label: 'Enqueued', data: [], backgroundColor: '#4e79a7' },
    { label: 'Delivered', data: [], backgroundColor: '#f28e2b' }
  ]},
  options: { responsive: true, scales: { y: { beginAtZero: true } } }
})

const latChart = new Chart(ctxL, {
  type: 'line',
  data: { labels: [], datasets: [
    { label: 'Avg Latency (s)', data: [], borderColor: '#59a14f', fill: false }
  ]},
  options: { responsive: true, scales: { y: { beginAtZero: true } } }
})

async function update() {
  const res = await fetch('/metrics', { headers: { Authorization: 'Bearer ' + token } })
  const queues = (await res.json()).queues
  const keys = Object.keys(queues)

  qChart.data.labels = keys
  qChart.data.datasets[0].data = keys.map(k => queues[k].enqueued)
  qChart.data.datasets[1].data = keys.map(k => queues[k].delivered)
  latChart.data.labels = keys
  latChart.data.datasets[0].data = keys.map(k => queues[k].avg_latency)

  qChart.update(); latChart.update()
}
setInterval(update, 3000); update()
"@

# === Final Message ===
Write-Host "`n✅ Broker Build Complete at '$root'"
Write-Host "   ➤ Start broker:      cd amqp_broker; python broker.py"
Write-Host "   ➤ Dashboard:         http://localhost:15672/web/"
Write-Host "   ➤ Live charts:       http://localhost:15672/web/stats.html"
Write-Host "   ➤ Login:             POST /auth  (JSON {username, password})"
Write-Host "   ➤ Issue token:       python rbac_token_issuer.py admin admin,reader,writer supersecret"
Write-Host "   ➤ Run tests:         pytest tests/test_auth.py"
