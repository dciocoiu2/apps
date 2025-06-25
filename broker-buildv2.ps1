# === PART 1: Setup & RBAC Auth ===

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
  if (!(Test-Path $dir)) {
    New-Item -ItemType Directory $dir -Force | Out-Null
  }
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}

# === settings.json with Roles ===
@{
  jwt_secret = "supersecret"
  admin_port = 15672
  tls = $false
  web_gui = $true
  enable_plugins = $true
  users = @{
    admin = @{ password = "admin123"; roles = @("admin", "reader") }
    bob = @{ password = "bobpass"; roles = @("reader") }
    alice = @{ password = "alicepass"; roles = @("writer") }
  }
} | ConvertTo-Json -Depth 5 | Set-Content "$root\settings.json"

# === config.py ===
Write-CodeFile "$root\config.py" @"
import json, os
def load_settings():
    with open(os.path.join(os.path.dirname(__file__), 'settings.json')) as f:
        return json.load(f)
"@

# === util\auth.py (with RBAC) ===
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

# === rbac_token_issuer.py ===
Write-CodeFile "$root\\rbac_token_issuer.py" @"
import sys, json, jwt, time

if len(sys.argv) < 4:
    print('Usage: python rbac_token_issuer.py <username> <roles comma-separated> <secret>')
    sys.exit(1)

username = sys.argv[1]
roles = sys.argv[2].split(',')
secret = sys.argv[3]

payload = {
    'user': username,
    'roles': roles,
    'exp': time.time() + 3600
}

token = jwt.encode(payload, secret, algorithm='HS256')
print(token)
"@
#== Part 2
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

# === broker.py ===
Write-CodeFile "$root\broker.py" @"
import threading, socket, sys
from config import load_settings
from util.logging import info
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
        return '127.0.0.1'

def print_endpoints(ip, port):
    print()
    print(f'🌐 Web UI:        http://{ip}:{port}/')
    print(f'🔐 POST /auth     Login for JWT token')
    print(f'🛰️ Secured APIs:  /metrics, /logs, /topology, /replicate\n')

def main():
    try: cfg = load_settings()
    except Exception as e: print(f'❌ Failed to load config: {e}'); sys.exit(1)

    port = cfg.get('admin_port', 15672)
    ip = get_local_ip()

    if cfg.get('tls'): build_tls_context(cfg.get('cert_file'), cfg.get('key_file'))
    if cfg.get('enable_plugins'): load_plugins(); info("Plugins loaded")
    start_heartbeat()
    h, p = cfg.get('join_host'), cfg.get('join_port')
    if h and p: join_network(h, p)
    threading.Thread(target=lambda: run_http_api(ip, port), daemon=True).start()
    print_endpoints(ip, port)
    info("Broker online."); threading.Event().wait()

if __name__ == '__main__':
    main()
"@

# === plugins\echo_logger.py ===
Write-CodeFile "$root\plugins\echo_logger.py" @"
def on_start():
    print('[Plugin] echo_logger loaded')

def on_enqueue(queue, message):
    print(f'[echo_logger] {queue}: {message}')

def on_cluster_event(event, peer):
    print(f'[echo_logger] Cluster event: {event.upper()} peer={peer}')
"@

# === tests\test_auth.py ===
Write-CodeFile "tests\test_auth.py" @"
import requests

def test_auth_token():
    r = requests.post('http://localhost:15672/auth', json={'username': 'admin', 'password': 'admin123'})
    assert r.status_code == 200
    assert 'token' in r.json()
"@

Write-Host "`n✅ Broker with role-based access control created at: $root"
Write-Host "   ➤ To run:     cd amqp_broker; python broker.py"
Write-Host "   ➤ To login:   POST /auth with credentials"
Write-Host "   ➤ To test:    pytest tests/test_auth.py -v"
Write-Host "   ➤ To issue token via CLI: python rbac_token_issuer.py <user> <roles> <secret>"
