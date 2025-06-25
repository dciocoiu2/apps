# === AMQP Broker Generator — Part 1 ===

$root = "amqp_broker"
$dirs = @(
  "$root", "$root\core", "$root\util", "$root\cluster",
  "$root\api", "$root\api\web", "$root\plugins", "tests", "tests\brokers"
)
foreach ($d in $dirs) {
  if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

function Write-CodeFile {
  param ([string]$Path, [string]$Content)
  $dir = Split-Path $Path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}

# === settings.json with RBAC ===
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
} | ConvertTo-Json -Depth 5 | Set-Content "$root\settings.json"

# === config.py ===
Write-CodeFile "$root\config.py" @"
import json, os
def load_settings():
    with open(os.path.join(os.path.dirname(__file__), 'settings.json')) as f:
        return json.load(f)
"@

# === util\auth.py ===
Write-CodeFile "$root\util\auth.py" @"
import time, jwt
from config import load_settings

cfg = load_settings()
SECRET = cfg.get('jwt_secret', 'secret')
USERS = cfg.get('users', {})

def generate_token(username):
    roles = USERS.get(username, {}).get('roles', [])
    payload = { 'user': username, 'roles': roles, 'exp': time.time() + 3600 }
    return jwt.encode(payload, SECRET, algorithm='HS256')

def validate_token(token, required_roles=None):
    try:
        decoded = jwt.decode(token, SECRET, algorithms=['HS256'])
        user_roles = decoded.get('roles', [])
        if required_roles:
            return any(role in user_roles for role in required_roles)
        return True
    except:
        return False

def login(u, p):
    user = USERS.get(u)
    if user and user.get('password') == p:
        return generate_token(u)
    return None
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
      roles = getattr(mod, 'allowed_roles', [])
      if 'admin' in roles or not roles:
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

# === util\metrics.py ===
Write-CodeFile "$root\util\metrics.py" @"
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
        'avg_latency': round(sum(s['lat'])/len(s['lat']), 3) if s['lat'] else 0
      } for q, s in stats.items()
    }
  }
"@

# === util\logs.py ===
Write-CodeFile "$root\util\logs.py" @"
from collections import deque
import time
log_history = deque(maxlen=500)

def add_log(level, msg, **ctx):
  log_history.append({ 'time': time.strftime('%Y-%m-%d %H:%M:%S'), 'level': level, 'msg': msg, 'context': ctx })

def get_logs():
  return list(log_history)
"@

# === util\logging.py ===
Write-CodeFile "$root\util\logging.py" @"
import time
from util.logs import add_log

def log(level, msg, **ctx):
  ts = time.strftime('%H:%M:%S')
  print(f"[{ts}] [{level.upper()}] {msg} {ctx}")
  add_log(level, msg, **ctx)

def info(msg, **ctx): log('info', msg, **ctx)
def error(msg, **ctx): log('error', msg, **ctx)
def warn(msg, **ctx): log('warn', msg, **ctx)
"@

# === rbac_token_issuer.py ===
Write-CodeFile "$root\\rbac_token_issuer.py" @"
import sys, jwt, time

if len(sys.argv) < 4:
  print('Usage: python rbac_token_issuer.py <username> <comma_roles> <secret>')
  sys.exit(1)

user = sys.argv[1]
roles = sys.argv[2].split(',')
secret = sys.argv[3]

payload = {
  'user': user,
  'roles': roles,
  'exp': time.time() + 3600
}

print(jwt.encode(payload, secret, algorithm='HS256'))
"@

#==PART2==#
# === broker.py ===
Write-CodeFile "$root\broker.py" @"
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
    except:
        return '127.0.0.1'

def print_endpoints(ip, port):
    print()
    print(f' Web UI:         http://{ip}:{port}/web/')
    print(f' Login:           POST /auth with username/password')
    print(f'Dashboard:       /web/stats.html')
    print(f' Metrics:         /metrics (JWT + RBAC secured)')
    print(f' Replication:     /replicate\n')

def main():
    try:
        cfg = load_settings()
    except Exception as e:
        print(f' Failed to load config: {e}')
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
Write-CodeFile "$root\plugins\echo_logger.py" @"
allowed_roles = ['admin']

def on_start():
    print('[Plugin] echo_logger loaded')

def on_enqueue(queue, message):
    print(f'[echo_logger] Queue {queue} received message: {message}')

def on_cluster_event(event, peer):
    print(f'[echo_logger] Cluster {event.upper()} from {peer}')
"@

# === tests\test_auth.py ===
Write-CodeFile "$root\tests\test_auth.py" @"
import requests

def test_token_auth():
    r = requests.post('http://localhost:15672/auth', json={'username': 'admin', 'password': 'admin123'})
    assert r.status_code == 200
    assert 'token' in r.json()
"@

# === api\web\index.html ===
Write-CodeFile "$root\api\web\index.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>Broker Dashboard</title>
  <script src='/web/dashboard.js' defer></script>
</head>
<body>
  <h1> Broker Dashboard</h1>
  <section><h2>Metrics</h2><pre id='metrics'></pre></section>
  <section><h2>Topology</h2><pre id='topology'></pre></section>
  <section><h2>Logs</h2><pre id='logs'></pre></section>
  <section><h2>Charts</h2><a href='/web/stats.html'> Live Charts</a></section>
</body>
</html>
"@

# === api\web\dashboard.js ===
Write-CodeFile "$root\api\web\dashboard.js" @"
const token = prompt('Bearer token?')

async function get(path) {
  const r = await fetch(path, { headers: { Authorization: 'Bearer ' + token } })
  return await r.json()
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
Write-CodeFile "$root\api\web\stats.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>Live Stats</title>
  <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
  <script src='/web/stats.js' defer></script>
</head>
<body>
  <h1>Real-Time Charts</h1>
  <canvas id='qChart'></canvas>
  <canvas id='latChart'></canvas>
</body>
</html>
"@

# === api\web\stats.js ===
Write-CodeFile "$root\api\web\stats.js" @"
const token = prompt('Bearer token?')
const ctxQ = document.getElementById('qChart').getContext('2d')
const ctxL = document.getElementById('latChart').getContext('2d')

const qChart = new Chart(ctxQ, {
  type: 'bar',
  data: { labels: [], datasets: [
    { label: 'Enqueued', data: [], backgroundColor: '#4e79a7' },
    { label: 'Delivered', data: [], backgroundColor: '#f28e2b' }
  ]},
  options: { responsive: true }
})

const latChart = new Chart(ctxL, {
  type: 'line',
  data: { labels: [], datasets: [
    { label: 'Avg Latency', data: [], borderColor: '#59a14f', fill: false }
  ]},
  options: { responsive: true }
})

async function update() {
  const r = await fetch('/metrics', { headers: { Authorization: 'Bearer ' + token } })
  const d = await r.json().queues
  const keys = Object.keys(d)
  qChart.data.labels = keys
  latChart.data.labels = keys
  qChart.data.datasets[0].data = keys.map(k => d[k].enqueued)
  qChart.data.datasets[1].data = keys.map(k => d[k].delivered)
  latChart.data.datasets[0].data = keys.map(k => d[k].avg_latency)
  qChart.update(); latChart.update()
}

setInterval(update, 3000); update()
"@

Write-Host " Broker build complete at '$root'"
Write-Host "    Start broker:        cd amqp_broker; python broker.py"
Write-Host "    Auth test:           pytest tests/test_auth.py"
Write-Host "    Web dashboard:       http://localhost:15672/web/"
Write-Host "    Live charts:         http://localhost:15672/web/stats.html"