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
# === core\queue.py ===
Write-CodeFile "$root\core\queue.py" @"
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

    def register(self, fn):
        self.c.append(fn)
        self._deliver()

    def _deliver(self):
        while self.q and self.c:
            msg, _ = self.q.popleft()
            for fn in self.c: fn(msg)
            deliver(self.name)

def get_or_create_queue(name):
    if name not in queues: queues[name] = Queue(name)
    return queues[name]
"@

# === cluster\peerlink.py ===
Write-CodeFile "$root\cluster\peerlink.py" @"
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
        try: requests.post(f"http://{p['host']}:{p['port']}/replicate", json=payload, timeout=2)
        except: pass

def handle(payload, fn):
    if payload['msg_id'] in REPL_CACHE or time.time() > payload['expires']: return False
    REPL_CACHE.add(payload['msg_id'])
    fn(payload['queue'], payload['body'])
    return True
"@

# === api\http_api.py ===
Write-CodeFile "$root\api\http_api.py" @"
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

Write-CodeFile "$root\plugins\echo_logger.py" @"
allowed_roles = ['admin']

def on_start():
    print('[Plugin] Echo logger loaded')

def on_enqueue(queue, message):
    print(f'[EchoLog] {queue} => {message}')

def on_cluster_event(event, peer):
    print(f'[Cluster] {event.upper()} from {peer}')
"@

Write-CodeFile "$root\tests\test_auth.py" @"
import requests
def test_token():
    r = requests.post('http://localhost:15672/auth', json={'username': 'admin', 'password': 'admin123'})
    assert r.status_code == 200 and 'token' in r.json()
"@

Write-Host "`n✅ Broker Build Complete: Project created in '$root'"
Write-Host "   ➤ Launch it: cd amqp_broker; python broker.py"
Write-Host "   ➤ Dashboard: http://localhost:15672/web/"
Write-Host "   ➤ API Test:  pytest tests/test_auth.py"
Write-Host "   ➤ Token CLI: python rbac_token_issuer.py admin admin,reader,writer supersecret"
