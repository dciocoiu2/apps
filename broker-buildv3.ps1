# === AMQP-Style Broker Builder with RBAC, Token Auth, Dashboard ===

$root = "amqp_broker"
$dirs = @(
  "$root", "$root\core", "$root\util", "$root\cluster",
  "$root\api", "$root\api\web", "$root\plugins", "tests", "tests\brokers"
)
foreach ($d in $dirs) {
  if (!(Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
}

function Write-CodeFile {
  param ([string]$Path, [string]$Content)
  $dir = Split-Path $Path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
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
    viewer = @{ password = "viewonly"; roles = @("reader") }
    pusher = @{ password = "pushpass"; roles = @("writer") }
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
    payload = {
        'user': username,
        'roles': roles,
        'exp': time.time() + 3600
    }
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

# === api\web\index.html ===
Write-CodeFile "$root\api\web\index.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>Broker Dashboard</title>
  <script src='dashboard.js' defer></script>
</head>
<body>
  <h1>AMQP Broker Dashboard</h1>
  <section>
    <h2>Metrics</h2><pre id='metrics'></pre>
    <h2>Topology</h2><pre id='topology'></pre>
    <h2>Logs</h2><pre id='logs'></pre>
  </section>
  <section>
    <h2>Charts</h2>
    <a href="/web/stats.html"> View Live Charts</a>
  </section>
</body>
</html>
"@

# === api\web\dashboard.js ===
Write-CodeFile "$root\api\web\dashboard.js" @"
const token = prompt('Paste bearer token:')
async function load(path) {
  const r = await fetch(path, { headers: { Authorization: 'Bearer ' + token } });
  return await r.json();
}

async function refresh() {
  try {
    const m = await load('/metrics');
    const t = await load('/topology');
    const l = await load('/logs');
    document.getElementById('metrics').textContent = JSON.stringify(m, null, 2);
    document.getElementById('topology').textContent = JSON.stringify(t, null, 2);
    document.getElementById('logs').textContent = l.map(e => \`[\${e.time}] \${e.level}: \${e.msg}\`).join('\\n');
  } catch (e) {
    console.error(e);
  }
}
setInterval(refresh, 3000); refresh();
"@

# === api\web\stats.html ===
Write-CodeFile "$root\api\web\stats.html" @"
<!DOCTYPE html>
<html>
<head>
  <title>Broker Stats</title>
  <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
  <script src='stats.js' defer></script>
</head>
<body>
  <h1>Live Broker Stats</h1>
  <canvas id='qChart' width='800' height='300'></canvas>
  <canvas id='latChart' width='800' height='300'></canvas>
</body>
</html>
"@

# === api\web\stats.js ===
Write-CodeFile "$root\api\web\stats.js" @"
const token = prompt('Paste bearer token:')
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
  try {
    const r = await fetch('/metrics', { headers: { Authorization: 'Bearer ' + token } });
    const data = await r.json();
    const queues = data.queues || {};
    const keys = Object.keys(queues);
    qChart.data.labels = keys;
    qChart.data.datasets[0].data = keys.map(k => queues[k].enqueued);
    qChart.data.datasets[1].data = keys.map(k => queues[k].delivered);
    latChart.data.labels = keys;
    latChart.data.datasets[0].data = keys.map(k => queues[k].avg_latency);
    qChart.update(); latChart.update();
  } catch (e) {
    console.error('Failed to load chart data:', e);
  }
}
setInterval(update, 3000); update();
"@

# === tests\test_auth.py ===
Write-CodeFile "$root\tests\test_auth.py" @"
import requests

def test_token_auth():
    r = requests.post('http://localhost:15672/auth', json={'username': 'admin', 'password': 'admin123'})
    assert r.status_code == 200
    assert 'token' in r.json()
"@

# === plugins\echo_logger.py ===
Write-CodeFile "$root\plugins\echo_logger.py" @"
allowed_roles = ['admin']

def on_start():
    print('[Plugin] Echo logger active')

def on_enqueue(queue, message):
    print(f'[echo_logger] {queue} received: {message}')

def on_cluster_event(event, peer):
    print(f'[echo_logger] Cluster {event.upper()} for peer: {peer}')
"@

# ===  Footer ===
Write-Host "`AMQP broker project generated at: amqp_broker"
Write-Host "   Start broker:        cd amqp_broker; python broker.py"
Write-Host "    Token login:         POST /auth with JSON {username, password}"
Write-Host "    Launch dashboard:    http://localhost:15672/web/"
Write-Host "    Run tests:           pytest tests/test_auth.py -v"