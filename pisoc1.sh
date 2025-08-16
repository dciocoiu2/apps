#!/usr/bin/env bash
# Advanced SecOps Stack - Single-file deploy (Pi 5 / Debian/Ubuntu compatible)
# Features:
# - Advanced Web GUI (firewall, routing, NAT, load balancer, container orchestration)
# - IDS/IPS (Suricata via host pkg, Zeek via container)
# - SOC console (Elasticsearch + Kibana with Fleet)
# - Vulnerability scanning (Trivy, Semgrep, Nmap)
# - Kubernetes (k3s) + Helm
# - Docker + Portainer
# - API Gateway + Manager (APISIX + Dashboard + etcd)
# - Traefik with GUI-managed routes/listeners
# - Vault (dev mode)
# - Prometheus + Grafana + Node Exporter + cAdvisor
# - Remote endpoint logging and management via Fleet
# - SNAT/DNAT, static routing, front-end/backend rules via GUI
# - GUI styled in pfSense/F5 spirit
# - Final URLs printed (ordered): API Manager, API Gateway, Traefik, SOC, Portainer, Grafana, Prometheus, Vault, GUI, Elasticsearch, Fleet

set -euo pipefail

# -------- Config --------
STACK_ROOT="/opt/secops"
GUI_PORT="${GUI_PORT:-8088}"
TRAEFIK_HTTP="80"
TRAEFIK_DASHBOARD="8080"
APISIX_PORT="9080"
APISIX_ADMIN="9180"
APISIX_DASH="9002"
ELASTIC_PORT="9200"
KIBANA_PORT="5601"
PROM_PORT="9090"
GRAFANA_PORT="3000"
PORTAINER_HTTP="9000"
PORTAINER_HTTPS="9443"
VAULT_PORT="8200"
CADVISOR_PORT="8081"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-ChangeMeElastic!}"
VAULT_DEV_ROOT_TOKEN_ID="${VAULT_DEV_ROOT_TOKEN_ID:-root}"
HOST_IP="$(hostname -I | awk '{print $1}')"

# -------- Preflight --------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

mkdir -p "$STACK_ROOT"/{gui/{app,templates,static},stack/{traefik,dynamic,apisix,elastic,prometheus,grafana,pcap},logs,bin}

echo "[*] Updating system and installing dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl jq git nftables iproute2 bridge-utils vlan \
  python3 python3-pip python3-venv python3-dev \
  nmap suricata \
  docker.io docker-compose-plugin \
  gnupg lsb-release

# L2 VLAN kernel module (best-effort)
modprobe 8021q || true

# Increase vm.max_map_count for Elasticsearch
sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# Enable Docker
systemctl enable docker
systemctl start docker

# -------- Vulnerability tools --------
echo "[*] Installing Trivy..."
if ! command -v trivy >/dev/null 2>&1; then
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/scripts/install.sh | sh -s -- -b /usr/local/bin
fi

echo "[*] Installing Semgrep..."
pip3 install --upgrade pip >/dev/null
pip3 install --no-cache-dir semgrep >/dev/null

# -------- Kubernetes (k3s) + Helm --------
if ! command -v k3s >/dev/null 2>&1; then
  echo "[*] Installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
fi
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

if ! command -v helm >/dev/null 2>&1; then
  echo "[*] Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# -------- Traefik config (file provider) --------
cat > "$STACK_ROOT/stack/traefik/traefik.yml" <<'YAML'
entryPoints:
  web:
    address: ":80"
api:
  dashboard: true
providers:
  docker:
    exposedByDefault: false
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
metrics:
  prometheus:
    addServicesLabels: true
    addEntryPointsLabels: true
YAML

# dynamic routes initial (empty)
cat > "$STACK_ROOT/stack/dynamic/dynamic.yml" <<'YAML'
http:
  routers: {}
  services: {}
YAML

# -------- APISIX config --------
cat > "$STACK_ROOT/stack/apisix/config.yaml" <<'YAML'
apisix:
  node_listen: 9080
  enable_ipv6: false
  enable_admin: true
  admin_key:
    - name: admin
      key: edd1c9f034335f136f87ad84b625c8f1
      role: admin
deployment:
  role: data_plane
  role_data_plane:
    config_provider: etcd
etcd:
  host:
    - "http://etcd:2379"
  prefix: "/apisix"
YAML

# APISIX Dashboard config
cat > "$STACK_ROOT/stack/apisix/dashboard.yaml" <<YAML
conf:
  listen:
    host: 0.0.0.0
    port: 9002
  etcd:
    endpoints:
      - "http://etcd:2379"
  auth:
    secret: "dashboard-secret"
    expire_time: 3600
  sql:
    type: "sqlite"
  apisix:
    api_url: "http://apisix:${APISIX_ADMIN}/apisix/admin"
    api_key: "edd1c9f034335f136f87ad84b625c8f1"
YAML

# -------- Prometheus config --------
cat > "$STACK_ROOT/stack/prometheus/prometheus.yml" <<YAML
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'traefik'
    static_configs:
      - targets: ['traefik:${TRAEFIK_DASHBOARD}']
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:${PROM_PORT}']
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['node-exporter:9100']
YAML

# -------- Grafana provisioning --------
mkdir -p "$STACK_ROOT/stack/grafana/provisioning/datasources"
cat > "$STACK_ROOT/stack/grafana/provisioning/datasources/datasource.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
YAML

# -------- Docker Compose (core stack) --------
cat > "$STACK_ROOT/stack/docker-compose.yml" <<COMPOSE
version: "3.8"

networks:
  secops:
    name: secops

volumes:
  esdata:
  grafana-data:
  portainer-data:
  vault-data:

services:

  etcd:
    image: bitnami/etcd:3.5
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
      - ETCD_ADVERTISE_CLIENT_URLS=http://0.0.0.0:2379
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
    networks: [secops]

  apisix:
    image: apache/apisix:3.7-alpine
    depends_on: [etcd]
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
    ports:
      - "${APISIX_PORT}:9080"
      - "${APISIX_ADMIN}:9180"
    networks: [secops]

  apisix-dashboard:
    image: apache/apisix-dashboard:3.0
    depends_on: [apisix, etcd]
    volumes:
      - ./apisix/dashboard.yaml:/usr/local/apisix-dashboard/conf/conf.yaml:ro
    environment:
      - LOG_LEVEL=info
    ports:
      - "${APISIX_DASH}:9002"
    networks: [secops]

  traefik:
    image: traefik:v2.11
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:${TRAEFIK_HTTP}"
      - "--metrics.prometheus=true"
    ports:
      - "${TRAEFIK_HTTP}:${TRAEFIK_HTTP}"
      - "${TRAEFIK_DASHBOARD}:${TRAEFIK_DASHBOARD}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic
    networks: [secops]

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.1
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - esdata:/usr/share/elasticsearch/data
    ports:
      - "${ELASTIC_PORT}:9200"
    networks: [secops]

  kibana:
    image: docker.elastic.co/kibana/kibana:8.12.1
    depends_on: [elasticsearch]
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - ELASTICSEARCH_USERNAME=elastic
      - ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD}
      - SERVER_PUBLICBASEURL=http://${HOST_IP}:${KIBANA_PORT}
      - XPACK_FLEET_AGENTS_ENABLED=true
    ports:
      - "${KIBANA_PORT}:5601"
    networks: [secops]

  # Fleet Server (started after token obtained)
  fleet-server:
    image: docker.elastic.co/beats/elastic-agent:8.12.1
    depends_on: [elasticsearch, kibana]
    environment:
      - FLEET_SERVER_ENABLE=1
      - FLEET_ENROLL=1
      - FLEET_URL=http://fleet-server:8220
      - FLEET_SERVER_ELASTICSEARCH_HOST=http://elasticsearch:9200
      - FLEET_SERVER_SERVICE_TOKEN=\${FLEET_SERVICE_TOKEN}
      - ELASTICSEARCH_USERNAME=elastic
      - ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD}
      - KIBANA_FLEET_SETUP=1
      - KIBANA_HOST=http://kibana:5601
    ports:
      - "8220:8220"
    command: >
      bash -lc "elastic-agent container"
    networks: [secops]
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.53.0
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "${PROM_PORT}:9090"
    networks: [secops]

  grafana:
    image: grafana/grafana:10.4.6
    depends_on: [prometheus]
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    ports:
      - "${GRAFANA_PORT}:3000"
    networks: [secops]

  node-exporter:
    image: prom/node-exporter:v1.8.1
    pid: host
    network_mode: host
    command:
      - '--path.rootfs=/host'
    volumes:
      - '/:/host:ro,rslave'

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.2
    ports:
      - "${CADVISOR_PORT}:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [secops]

  portainer:
    image: portainer/portainer-ce:2.20.3
    ports:
      - "${PORTAINER_HTTP}:9000"
      - "${PORTAINER_HTTPS}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    networks: [secops]

  vault:
    image: hashicorp/vault:1.16
    environment:
      - VAULT_DEV_ROOT_TOKEN_ID=${VAULT_DEV_ROOT_TOKEN_ID}
      - VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:${VAULT_PORT}
    cap_add:
      - IPC_LOCK
    ports:
      - "${VAULT_PORT}:${VAULT_PORT}"
    command: "server -dev -dev-root-token-id=${VAULT_DEV_ROOT_TOKEN_ID} -dev-listen-address=0.0.0.0:${VAULT_PORT}"
    networks: [secops]

  zeek:
    image: zeek/zeek:6.0.1
    command: tail -f /dev/null
    volumes:
      - ./pcap:/pcap
    networks: [secops]
COMPOSE

# -------- Flask GUI (pfSense/F5-inspired) --------
python3 - <<'PYSETUP'
import os, textwrap
root = "/opt/secops/gui"
os.makedirs(root + "/app", exist_ok=True)
os.makedirs(root + "/templates", exist_ok=True)
os.makedirs(root + "/static", exist_ok=True)

open(root + "/static/style.css","w").write("""
:root{--bg:#0f172a;--panel:#111827;--border:#1f2937;--acc:#0ea5e9;--text:#e5e7eb;--muted:#93c5fd}
*{box-sizing:border-box}body{font-family:Inter,Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--text);margin:0}
.header{background:#0b1220;padding:14px 18px;border-bottom:2px solid var(--acc);display:flex;justify-content:space-between;align-items:center}
.header .title{font-weight:800;color:var(--text);letter-spacing:.3px}
.nav a{color:var(--muted);margin-right:14px;text-decoration:none;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;padding:16px}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px}
h2{color:var(--muted);margin:6px 0 12px}
label{display:block;margin:8px 0 4px}
input,select,textarea{width:100%;padding:8px;border-radius:6px;border:1px solid var(--border);background:#0b1220;color:var(--text)}
button{background:var(--acc);border:none;padding:8px 12px;color:#03111f;border-radius:6px;font-weight:800;margin-top:10px;cursor:pointer}
.small{font-size:12px;color:#94a3b8}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;background:#0ea5e933;color:#93c5fd;border:1px solid #0ea5e9}
""")

open(root + "/templates/base.html","w").write("""
<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>SecOps GUI</title><link rel="stylesheet" href="/static/style.css"></head>
<body>
<div class="header">
  <div class="title">SecOps Control Plane</div>
  <div class="nav">
    <a href="/">Dashboard</a>
    <a href="/firewall">Firewall/NAT</a>
    <a href="/routing">Routing</a>
    <a href="/loadbalancer">Load Balancer</a>
    <a href="/containers">Containers</a>
    <a href="/kubernetes">Kubernetes</a>
    <a href="/scanners">Scanners</a>
  </div>
</div>
<div class="content">{% block content %}{% endblock %}</div>
</body></html>
""")

open(root + "/templates/index.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="grid">
  <div class="card"><h2>Firewall & NAT</h2><p>Manage allow/deny rules, SNAT/DNAT.</p><a href="/firewall"><button>Open</button></a></div>
  <div class="card"><h2>Routing</h2><p>Static routes and policy rules.</p><a href="/routing"><button>Open</button></a></div>
  <div class="card"><h2>Load Balancer</h2><p>Traefik HTTP routers & services.</p><a href="/loadbalancer"><button>Open</button></a></div>
  <div class="card"><h2>Containers</h2><p>Manage stack services with Docker.</p><a href="/containers"><button>Open</button></a></div>
  <div class="card"><h2>Kubernetes</h2><p>Simple Helm app installs.</p><a href="/kubernetes"><button>Open</button></a></div>
  <div class="card"><h2>Scanners</h2><p>Trivy, Semgrep, and Nmap scans.</p><a href="/scanners"><button>Open</button></a></div>
</div>
{% endblock %}
""")

open(root + "/templates/firewall.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="grid">
<div class="card">
  <h2>Add firewall rule</h2>
  <form method="post" action="/firewall/add_rule">
    <label>Chain (input|forward|output)</label><input name="chain" placeholder="input">
    <label>Action (accept|drop|reject)</label><input name="action" placeholder="accept">
    <label>Match (nft syntax)</label><input name="match" placeholder="ip saddr 10.0.0.0/24 tcp dport 22">
    <button type="submit">Add rule</button>
  </form>
</div>

<div class="card">
  <h2>SNAT</h2>
  <form method="post" action="/firewall/snat">
    <label>Outbound interface</label><input name="oif" placeholder="eth0">
    <label>Source CIDR</label><input name="src" placeholder="192.168.1.0/24">
    <label>To address</label><input name="to" placeholder="203.0.113.10">
    <button type="submit">Add SNAT</button>
  </form>
</div>

<div class="card">
  <h2>DNAT (Port forward)</h2>
  <form method="post" action="/firewall/dnat">
    <label>Inbound interface</label><input name="iif" placeholder="eth0">
    <label>Dst port</label><input name="dport" placeholder="8080">
    <label>Protocol</label><input name="proto" placeholder="tcp">
    <label>To IP:port</label><input name="to" placeholder="192.168.1.100:80">
    <button type="submit">Add DNAT</button>
  </form>
</div>

<div class="card">
  <h2>Layer 2 (Bridge/VLAN)</h2>
  <form method="post" action="/l2/bridge_add">
    <label>Bridge name</label><input name="brname" placeholder="br0">
    <button type="submit">Create bridge</button>
  </form>
  <form method="post" action="/l2/bridge_del">
    <label>Bridge name</label><input name="brname" placeholder="br0">
    <button type="submit">Delete bridge</button>
  </form>
  <form method="post" action="/l2/add_if">
    <label>Bridge</label><input name="brname" placeholder="br0">
    <label>Interface</label><input name="iface" placeholder="eth1">
    <button type="submit">Add interface to bridge</button>
  </form>
  <form method="post" action="/l2/vlan_add">
    <label>Interface</label><input name="iface" placeholder="eth0">
    <label>VLAN ID</label><input name="vid" placeholder="100">
    <button type="submit">Add VLAN sub‑interface</button>
  </form>
  <form method="post" action="/l2/show_mac">
    <label>Bridge</label><input name="brname" placeholder="br0">
    <button type="submit">Show MAC table</button>
  </form>
</div>
</div>
{% endblock %}
""")

open(root + "/templates/routing.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="card">
  <h2>Add static route</h2>
  <form method="post" action="/routing/add">
    <label>Destination CIDR</label><input name="dst" placeholder="10.10.0.0/16">
    <label>Gateway</label><input name="gw" placeholder="192.168.1.1">
    <label>Interface</label><input name="dev" placeholder="eth0">
    <button type="submit">Add route</button>
  </form>
</div>
{% endblock %}
""")

open(root + "/templates/loadbalancer.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="card">
  <h2>Create HTTP route (Traefik)</h2>
  <form method="post" action="/loadbalancer/add_route">
    <label>Router name</label><input name="name" placeholder="web-app">
    <label>Host rule</label><input name="host" placeholder="app.local">
    <label>Service name</label><input name="service" placeholder="web-app-svc">
    <label>Backend URL(s) (comma-separated)</label><input name="urls" placeholder="http://192.168.1.10:8080,http://192.168.1.11:8080">
    <button type="submit">Create</button>
  </form>
</div>
{% endblock %}
""")

open(root + "/templates/containers.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="card">
  <h2>Stack control</h2>
  <form method="post" action="/containers/cmd">
    <label>Action (up|down|restart)</label><input name="action" placeholder="up">
    <button type="submit">Run</button>
  </form>
  <p class="small">Use Portainer for advanced container ops.</p>
</div>
{% endblock %}
""")

open(root + "/templates/kubernetes.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="card">
  <h2>Helm quick deploy</h2>
  <form method="post" action="/kubernetes/helm_install">
    <label>Repo name</label><input name="repo" placeholder="bitnami">
    <label>Repo URL</label><input name="url" placeholder="https://charts.bitnami.com/bitnami">
    <label>Chart name</label><input name="chart" placeholder="bitnami/nginx">
    <label>Release name</label><input name="release" placeholder="demo-nginx">
    <label>Namespace</label><input name="ns" placeholder="default">
    <button type="submit">Install</button>
  </form>
</div>
{% endblock %}
""")

open(root + "/templates/scanners.html","w").write("""
{% extends "base.html" %}{% block content %}
<div class="grid">
<div class="card">
  <h2>Trivy image scan</h2>
  <form method="post" action="/scanners/trivy">
    <label>Image name</label><input name="image" placeholder="nginx:alpine">
    <button type="submit">Scan</button>
  </form>
</div>
<div class="card">
  <h2>Semgrep code scan</h2>
  <form method="post" action="/scanners/semgrep">
    <label>Path (on host)</label><input name="path" placeholder="/opt/app">
    <button type="submit">Scan</button>
  </form>
</div>
<div class="card">
  <h2>Nmap scan</h2>
  <form method="post" action="/scanners/nmap">
    <label>Target</label><input name="target" placeholder="192.168.1.0/24">
    <label>Flags (optional)</label><input name="flags" placeholder="-sV -O">
    <button type="submit">Scan</button>
  </form>
</div>
</div>
{% endblock %}
""")

open(root + "/app/app.py","w").write(textwrap.dedent("""
from flask import Flask, render_template, request, jsonify
import subprocess, os, json

app = Flask(__name__)

def sh(cmd):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    out = res.stdout.strip() + (("\\n"+res.stderr.strip()) if res.stderr else "")
    return res.returncode, out

@app.route("/")
def index():
    return render_template("index.html")

# --- Firewall / NAT (nftables) ---
@app.route("/firewall")
def firewall():
    return render_template("firewall.html")

@app.route("/firewall/add_rule", methods=["POST"])
def firewall_add():
    chain = request.form.get("chain","input")
    action = request.form.get("action","accept")
    match = request.form.get("match","")
    cmd = f"nft add rule inet filter {chain} {match} {action}".strip()
    rc,out = sh(cmd)
    return jsonify({"ok": rc==0, "cmd": cmd, "out": out})

@app.route("/firewall/snat", methods=["POST"])
def firewall_snat():
    oif = request.form["oif"]; src = request.form["src"]; to = request.form["to"]
    cmds = [
        "nft add table inet nat || true",
        "nft 'add chain inet nat postrouting { type nat hook postrouting priority 100 ; }' || true",
        f"nft add rule inet nat postrouting oifname {oif} ip saddr {src} snat to {to}"
    ]
    outs=[]; ok=True
    for c in cmds:
        rc,out=sh(c); outs.append({"cmd":c,"out":out}); ok = ok and (rc==0 or 'exist' in out)
    return jsonify({"ok": ok, "steps": outs})

@app.route("/firewall/dnat", methods=["POST"])
def firewall_dnat():
    iif = request.form["iif"]; dport = request.form["dport"]; proto = request.form.get("proto","tcp"); to = request.form["to"]
    cmds = [
        "nft add table inet nat || true",
        "nft 'add chain inet nat prerouting { type nat hook prerouting priority -100 ; }' || true",
        f"nft add rule inet nat prerouting iifname {iif} {proto} dport {dport} dnat to {to}"
    ]
    outs=[]; ok=True
    for c in cmds:
        rc,out=sh(c); outs.append({"cmd":c,"out":out}); ok = ok and (rc==0 or 'exist' in out)
    return jsonify({"ok": ok, "steps": outs})

# --- Layer 2 (bridge/VLAN/MAC) ---
@app.route("/l2/bridge_add", methods=["POST"])
def l2_bridge_add():
    br = request.form["brname"]
    rc,out = sh(f"ip link add name {br} type bridge && ip link set {br} up")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/l2/bridge_del", methods=["POST"])
def l2_bridge_del():
    br = request.form["brname"]
    rc,out = sh(f"ip link set {br} down && ip link delete {br} type bridge")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/l2/add_if", methods=["POST"])
def l2_add_if():
    br = request.form["brname"]; iface = request.form["iface"]
    rc,out = sh(f"ip link set {iface} master {br}")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/l2/vlan_add", methods=["POST"])
def l2_vlan_add():
    iface = request.form["iface"]; vid = request.form["vid"]
    rc,out = sh(f"ip link add link {iface} name {iface}.{vid} type vlan id {vid} && ip link set {iface}.{vid} up")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/l2/show_mac", methods=["POST"])
def l2_show_mac():
    br = request.form["brname"]
    rc,out = sh(f"bridge fdb show br {br}")
    return jsonify({"ok": rc==0, "mac_table": out.splitlines()})

# --- Routing ---
@app.route("/routing")
def routing():
    return render_template("routing.html")

@app.route("/routing/add", methods=["POST"])
def routing_add():
    dst = request.form["dst"]; gw = request.form["gw"]; dev = request.form.get("dev","")
    dev_part = f"dev {dev}" if dev else ""
    cmd = f"ip route add {dst} via {gw} {dev_part}".strip()
    rc,out = sh(cmd)
    return jsonify({"ok": rc==0, "cmd": cmd, "out": out})

# --- Traefik LB (file provider) ---
@app.route("/loadbalancer")
def lb():
    return render_template("loadbalancer.html")

@app.route("/loadbalancer/add_route", methods=["POST"])
def lb_add():
    name = request.form["name"].strip()
    host = request.form["host"].strip()
    service = request.form["service"].strip()
    urls = [u.strip() for u in request.form["urls"].split(",") if u.strip()]
    dyn = "/opt/secops/stack/dynamic/dynamic.yml"
    import yaml
    with open(dyn) as f:
        cfg = yaml.safe_load(f) or {}
    cfg.setdefault("http",{}).setdefault("routers",{})[name] = {
        "rule": f"Host(`{host}`)", "service": service, "entryPoints": ["web"]
    }
    cfg["http"].setdefault("services",{})[service] = {
        "loadBalancer": {"servers": [{"url": u} for u in urls]}
    }
    with open(dyn,"w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False)
    return jsonify({"ok": True, "router": name, "service": service, "backends": urls})

# --- Containers ---
@app.route("/containers")
def containers():
    return render_template("containers.html")

@app.route("/containers/cmd", methods=["POST"])
def containers_cmd():
    action = request.form.get("action","up").strip()
    if action == "up":
        cmd = "docker compose -f /opt/secops/stack/docker-compose.yml up -d"
    elif action == "down":
        cmd = "docker compose -f /opt/secops/stack/docker-compose.yml down"
    elif action == "restart":
        cmd = "docker compose -f /opt/secops/stack/docker-compose.yml restart"
    else:
        return jsonify({"ok": False, "error": "invalid action"})
    rc,out = sh(cmd)
    return jsonify({"ok": rc==0, "cmd": cmd, "out": out})

# --- Kubernetes (Helm quick deploy) ---
@app.route("/kubernetes")
def k8s():
    return render_template("kubernetes.html")

@app.route("/kubernetes/helm_install", methods=["POST"])
def helm_install():
    repo = request.form["repo"]; url = request.form["url"]; chart = request.form["chart"]
    release = request.form["release"]; ns = request.form.get("ns","default")
    rc1,o1 = sh(f"helm repo add {repo} {url} || true && helm repo update")
    rc2,o2 = sh(f"helm upgrade --install {release} {chart} -n {ns} --create-namespace")
    ok = (rc2==0)
    return jsonify({"ok": ok, "repo_out": o1, "install_out": o2})

# --- Scanners ---
@app.route("/scanners")
def scanners():
    return render_template("scanners.html")

@app.route("/scanners/trivy", methods=["POST"])
def scan_trivy():
    img = request.form["image"]
    rc,out = sh(f"trivy image --quiet --scanners vuln --format table {img}")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/scanners/semgrep", methods=["POST"])
def scan_semgrep():
    path = request.form["path"]
    rc,out = sh(f"semgrep --quiet --error --severity=ERROR --config auto {path}")
    return jsonify({"ok": rc==0, "out": out})

@app.route("/scanners/nmap", methods=["POST"])
def scan_nmap():
    target = request.form["target"]; flags = request.form.get("flags","-sS -Pn")
    rc,out = sh(f"nmap {flags} {target}")
    return jsonify({"ok": rc==0, "out": out})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("GUI_PORT","8088")))
"""))
PYSETUP

# -------- Python env for GUI --------
echo "[*] Preparing Python venv for GUI..."
python3 -m venv "$STACK_ROOT/gui/venv"
source "$STACK_ROOT/gui/venv/bin/activate"
pip install --quiet flask pyyaml
deactivate

# -------- systemd service for GUI --------
cat > /etc/systemd/system/secops-gui.service <<UNIT
[Unit]
Description=SecOps Advanced GUI
After=network.target docker.service

[Service]
User=root
Environment=GUI_PORT=${GUI_PORT}
WorkingDirectory=${STACK_ROOT}/gui/app
ExecStart=${STACK_ROOT}/gui/venv/bin/python ${STACK_ROOT}/gui/app/app.py
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable secops-gui.service
systemctl start secops-gui.service

# -------- Bring up core stack --------
echo "[*] Starting Docker stack..."
cd "$STACK_ROOT/stack"
docker compose up -d etcd apisix apisix-dashboard traefik elasticsearch kibana prometheus grafana portainer vault cadvisor node-exporter

# -------- Optional Fleet server bootstrap (best-effort) --------
echo "[*] Attempting Fleet Server bootstrap (best-effort)..."
for i in {1..60}; do
  if curl -s -u elastic:"$ELASTIC_PASSWORD" "http://localhost:${ELASTIC_PORT}/_cluster/health" | jq -e '.status' >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

SERVICE_TOKEN_JSON="$(curl -s -u elastic:"$ELASTIC_PASSWORD" -X POST \
  "http://localhost:${ELASTIC_PORT}/_security/service/elastic/fleet-server/credential/token" \
  -H 'Content-Type: application/json' -d '{"name":"fleet-server-token"}' || true)"
FLEET_SERVICE_TOKEN="$(echo "$SERVICE_TOKEN_JSON" | jq -r '.token.value' 2>/dev/null || true)"

if [[ -n "${FLEET_SERVICE_TOKEN}" && "${FLEET_SERVICE_TOKEN}" != "null" ]]; then
  echo "FLEET_SERVICE_TOKEN acquired."
  export FLEET_SERVICE_TOKEN
  docker compose up -d fleet-server
else
  echo "Skipping fleet-server auto-start (token unavailable). Configure Fleet in Kibana if needed."
fi

# -------- Suricata enable (host service) --------
systemctl enable suricata || true
systemctl start suricata || true

# -------- Zeek helper script --------
cat > "$STACK_ROOT/bin/zeek-pcap" <<'ZEOK'
#!/usr/bin/env bash
# Run Zeek against a pcap in /opt/secops/stack/pcap
PCAP="$1"
if [[ -z "$PCAP" ]]; then
  echo "Usage: zeek-pcap /opt/secops/stack/pcap/file.pcap"
  exit 1
fi
docker run --rm -v /opt/secops/stack/pcap:/pcap -w /pcap zeek/zeek:6.0.1 zeek -Cr "$(basename "$PCAP")"
ZEOK
chmod +x "$STACK_ROOT/bin/zeek-pcap"

# -------- Firewall (nft) base tables --------
nft add table inet filter 2>/dev/null || true
nft 'add chain inet filter input { type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
nft 'add chain inet filter forward { type filter hook forward priority 0 ; policy accept ; }' 2>/dev/null || true
nft 'add chain inet filter output { type filter hook output priority 0 ; policy accept ; }' 2>/dev/null || true
nft add table inet nat 2>/dev/null || true
nft 'add chain inet nat prerouting { type nat hook prerouting priority -100 ; }' 2>/dev/null || true
nft 'add chain inet nat postrouting { type nat hook postrouting priority 100 ; }' 2>/dev/null || true

# -------- Final URLs (ordered) --------
echo
echo "==========================================================="
echo " DEPLOYMENT COMPLETE - ACCESS DETAILS"
echo "==========================================================="
echo "API Manager (APISIX Dashboard):    http://${HOST_IP}:${APISIX_DASH}/"
echo "API Gateway (APISIX):              http://${HOST_IP}:${APISIX_PORT}/   (Admin API: http://${HOST_IP}:${APISIX_ADMIN}/)"
echo "Traefik Dashboard:                 http://${HOST_IP}:${TRAEFIK_DASHBOARD}/"
echo "SOC Console (Kibana + Fleet):      http://${HOST_IP}:${KIBANA_PORT}/"
echo "Portainer (Containers):            https://${HOST_IP}:${PORTAINER_HTTPS}/   or   http://${HOST_IP}:${PORTAINER_HTTP}/"
echo "Grafana (Observability):           http://${HOST_IP}:${GRAFANA_PORT}/"
echo "Prometheus (Metrics):              http://${HOST_IP}:${PROM_PORT}/"
echo "Vault (Dev mode):                  http://${HOST_IP}:${VAULT_PORT}/"
echo "Advanced SecOps GUI:               http://${HOST_IP}:${GUI_PORT}/"
echo "Elasticsearch API:                 http://${HOST_IP}:${ELASTIC_PORT}/"
echo "Fleet Server (if started):         http://${HOST_IP}:8220/"
echo "==========================================================="
echo "Elastic superuser: elastic / ${ELASTIC_PASSWORD}"
echo "Vault root token: ${VAULT_DEV_ROOT_TOKEN_ID}"
echo "Note: Fleet Server bootstrap is best-effort. If not running, open Kibana > Fleet to finalize setup."
echo "SNAT/DNAT, routes, LB rules can be managed in the SecOps GUI."