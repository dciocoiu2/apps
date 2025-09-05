# init-devops-stack.ps1
# Fully-contained local DevOps + API + WAF + L4 (Envoy) + L7 (Nginx) + k3s + Observability stack
# After running this script:
#   cd devops-stack
#   docker compose up -d
# Then open:
#   - http://localhost            (WAF entry)
#   - http://localhost/admin/     (Portainer)
#   - http://localhost/jenkins/   (Jenkins)
#   - http://localhost/ide/       (Web IDE; password: devpass)
#   - http://localhost/k8s/       (Kubernetes Dashboard via NodePort)
#   - http://localhost/grafana/   (Grafana UI)
#   - http://localhost:9000       (APISIX Dashboard)
#   - http://localhost:5000/v2/_catalog (Registry)
#   - https://localhost:6443      (Kubernetes API; kubeconfig in devops-stack/k3s/kubeconfig)
#   - http://localhost:9901       (Envoy admin/metrics)

$root = "devops-stack"
$dirs = @(
  "$root/envoy",
  "$root/nginx",
  "$root/waf",
  "$root/apisix",
  "$root/code",
  "$root/frontend",
  "$root/workspace",
  "$root/k3s",
  "$root/k8s/manifests",
  "$root/prometheus",
  "$root/alertmanager",
  "$root/grafana/provisioning/datasources",
  "$root/grafana/provisioning/dashboards",
  "$root/grafana/dashboards",
  "$root/loki",
  "$root/promtail"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# -------------------------
# Envoy (L4) config
# -------------------------
@"
static_resources:
  listeners:
  - name: l4_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8080
    listener_filters:
      - name: envoy.filters.listener.tls_inspector
        typed_config: {}
    filter_chains:
      - filters:
          - name: envoy.filters.network.tcp_proxy
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
              stat_prefix: l4_multiplex
              cluster: l4_cluster
  clusters:
  - name: l4_cluster
    connect_timeout: 1s
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: l4_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: waf
                port_value: 80
        - endpoint:
            address:
              socket_address:
                address: apisix
                port_value: 9080
    health_checks:
      - timeout: 1s
        interval: 5s
        unhealthy_threshold: 2
        healthy_threshold: 2
        tcp_health_check: {}
admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901
"@ | Set-Content "$root/envoy/envoy.yaml"

# -------------------------
# Nginx (L7) with stub_status
# -------------------------
@"
user  nginx;
worker_processes auto;

events { worker_connections 2048; }

http {
  # stub_status for nginx exporter
  server {
    listen 9113;
    location /stub_status {
      stub_status;
      access_log off;
    }
  }

  upstream ui_portainer { server portainer:9443; }
  upstream ui_jenkins  { server jenkins:8080; }
  upstream ui_code     { server code:8080; }
  upstream api_gw      { server apisix:9080; }
  upstream ui_k8s      { server k3s:30080; }   # Kubernetes Dashboard via NodePort
  upstream grafana_ui  { server grafana:3000; }

  server {
    listen 8080;

    # Admin UIs
    location /admin/   { proxy_set_header Host \$host; proxy_pass http://ui_portainer; }
    location /jenkins/ { proxy_set_header Host \$host; proxy_pass http://ui_jenkins; }
    location /ide/     { proxy_set_header Host \$host; proxy_pass http://ui_code; }
    location /k8s/     { proxy_set_header Host \$host; proxy_pass http://ui_k8s; }
    location /grafana/ { proxy_set_header Host \$host; proxy_pass http://grafana_ui; }

    # APIs to API Gateway
    location /api/     { proxy_set_header Host \$host; proxy_pass http://api_gw; }

    # Default landing
    location / {
      return 200 "DevOps stack online. Use /admin/, /jenkins/, /ide/, /k8s/, /grafana/, /api/.";
    }
  }
}
"@ | Set-Content "$root/nginx/nginx.conf"

# -------------------------
# APISIX config (Prometheus enabled)
# -------------------------
@"
deployment:
  role: data_plane
  role_data_plane:
    config_provider: etcd

apisix:
  node_listen: 9080
  enable_admin: true
  admin_listen:
    ip: 0.0.0.0
    port: 9180
  allow_admin:
    - 0.0.0.0/0
  admin_key:
    - name: admin
      key: edd1c9f034335f136f87ad84b625c8f1
      role: admin
  enable_debug: false

plugins:
  - prometheus

plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091

etcd:
  host:
    - "http://etcd:2379"
  prefix: "/apisix"
  timeout: 30
"@ | Set-Content "$root/apisix/config.yaml"

# -------------------------
# Web IDE Dockerfile (polyglot + k8s tools)
# -------------------------
@"
FROM codercom/code-server:4.91.1
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git curl wget unzip zip ca-certificates gnupg jq \
    python3 python3-pip python3-venv \
    openjdk-17-jdk maven gradle \
    golang \
    nodejs npm \
    ruby-full \
    php-cli php-mbstring php-xml php-curl composer \
    perl \
    r-base \
    lua5.4 luarocks \
    clang llvm gdb \
    pkg-config libssl-dev zlib1g-dev \
 && curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
 && curl -sS https://webinstall.dev/k9s | bash \
 && npm i -g yarn pnpm typescript \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV PATH=/root/.local/bin:/root/bin:/root/.krew/bin:/root/.config/k9s:\$PATH
EXPOSE 8080
USER 1000
CMD ["code-server", "--bind-addr", "0.0.0.0:8080", "--auth", "password", "/home/coder/project"]
"@ | Set-Content "$root/code/Dockerfile"

# -------------------------
# Observability configs
# -------------------------
@"
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: apisix
    metrics_path: /apisix/prometheus/metrics
    static_configs:
      - targets: ['apisix:9091']

  - job_name: nginx
    metrics_path: /stub_status
    static_configs:
      - targets: ['nginx:9113']

  - job_name: envoy
    metrics_path: /stats
    params:
      format: [prometheus]
    static_configs:
      - targets: ['envoy:9901']
"@ | Set-Content "$root/prometheus/prometheus.yml"

@"
global:
  resolve_timeout: 5m
route:
  receiver: 'null'
receivers:
  - name: 'null'
"@ | Set-Content "$root/alertmanager/alertmanager.yml"

@"
auth_enabled: false
server:
  http_listen_port: 3100
common:
  instance_addr: 127.0.0.1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2023-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  filesystem:
    directory: /loki
limits_config:
  ingestion_rate_mb: 8
  max_query_series: 100000
chunk_store_config:
  max_look_back_period: 168h
query_range:
  parallelise_shardable_queries: true
table_manager:
  retention_deletes_enabled: true
  retention_period: 168h
"@ | Set-Content "$root/loki/loki-config.yml"

@"
server:
  http_listen_port: 9080
positions:
  filename: /promtail/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: docker-json
    static_configs:
      - targets: ['localhost']
        labels:
          job: containers
          __path__: /var/lib/docker/containers/*/*-json.log
"@ | Set-Content "$root/promtail/promtail-config.yml"

@"
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
"@ | Set-Content "$root/grafana/provisioning/datasources/datasources.yml"

@"
apiVersion: 1
providers:
  - name: devops-stack
    orgId: 1
    folder: DevOps
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
"@ | Set-Content "$root/grafana/provisioning/dashboards/dashboards.yml"

# Dashboard JSON (Nginx/Envoy/APISIX/Loki)
@"
{
  "annotations": { "list": [ { "builtIn": 1, "datasource": "-- Grafana --", "enable": true, "hide": true, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard" } ] },
  "editable": true,
  "panels": [
    { "type": "row", "title": "Edge and gateways", "collapsed": false, "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 } },
    {
      "type": "stat", "title": "Nginx active connections",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "nginx_connections_active", "refId": "A" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } },
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 1 }
    },
    {
      "type": "stat", "title": "Envoy downstream connections",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "sum(envoy_http_downstream_cx_active) OR sum(envoy_tcp_downstream_cx_active)", "refId": "A" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } },
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 1 }
    },
    {
      "type": "stat", "title": "APISIX 5m request rate",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "sum(rate(apisix_http_status_total[5m]))", "refId": "A" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } },
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 1 }
    },
    {
      "type": "stat", "title": "Prometheus targets up",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "sum(up)", "refId": "A" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } },
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 1 }
    },
    { "type": "row", "title": "Traffic and responses", "collapsed": false, "gridPos": { "h": 1, "w": 24, "x": 0, "y": 5 } },
    {
      "type": "timeseries", "title": "Nginx requests per second",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "rate(nginx_http_requests_total[5m])", "legendFormat": "nginx rps", "refId": "A" } ],
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 }
    },
    {
      "type": "timeseries", "title": "Envoy downstream connections (rate)",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "rate(envoy_tcp_downstream_cx_total[5m])", "legendFormat": "cx rate", "refId": "A" } ],
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 }
    },
    {
      "type": "timeseries", "title": "APISIX status codes (rate)",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "targets": [ { "expr": "sum by (code) (rate(apisix_http_status_total[5m]))", "legendFormat": "{{code}}", "refId": "A" } ],
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 14 }
    },
    { "type": "row", "title": "Logs", "collapsed": false, "gridPos": { "h": 1, "w": 24, "x": 0, "y": 22 } },
    {
      "type": "logs", "title": "Container logs (Loki)",
      "datasource": { "type": "loki", "uid": "${DS_LOKI}" },
      "targets": [ { "expr": "{job=\"containers\"}", "refId": "A" } ],
      "options": { "showTime": true, "wrapLogMessage": true, "dedupStrategy": "none" },
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 23 }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "style": "dark",
  "tags": ["devops", "apisix", "nginx", "envoy"],
  "templating": {
    "list": [
      { "name": "DS_PROMETHEUS", "type": "datasource", "label": "Prometheus", "query": "prometheus", "current": { "text": "Prometheus", "value": "Prometheus" } },
      { "name": "DS_LOKI", "type": "datasource", "label": "Loki", "query": "loki", "current": { "text": "Loki", "value": "Loki" } }
    ]
  },
  "time": { "from": "now-1h", "to": "now" },
  "title": "DevOps Edge: WAF, L7, Envoy L4, APISIX, k3s",
  "uid": "devops-edge",
  "version": 1
}
"@ | Set-Content "$root/grafana/dashboards/devops-stack.json"

# -------------------------
# Kubernetes manifests: Metrics Server + Dashboard (NodePort 30080)
# -------------------------
@"
apiVersion: v1
kind: Namespace
metadata:
  name: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
  labels: { k8s-app: metrics-server }
spec:
  selector: { matchLabels: { k8s-app: metrics-server } }
  template:
    metadata: { labels: { k8s-app: metrics-server } }
    spec:
      containers:
        - name: metrics-server
          image: registry.k8s.io/metrics-server/metrics-server:v0.6.4
          args:
            - --kubelet-insecure-tls
            - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
          ports: [{containerPort: 4443, name: main-port}]
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-server
  namespace: kube-system
  labels: { k8s-app: metrics-server }
spec:
  selector: { k8s-app: metrics-server }
  ports:
    - port: 443
      targetPort: main-port
"@ | Set-Content "$root/k8s/manifests/metrics-server.yaml"

@"
apiVersion: v1
kind: Namespace
metadata:
  name: kubernetes-dashboard
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels: { k8s-app: kubernetes-dashboard }
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  replicas: 1
  selector:
    matchLabels: { k8s-app: kubernetes-dashboard }
  template:
    metadata:
      labels: { k8s-app: kubernetes-dashboard }
    spec:
      containers:
      - name: kubernetes-dashboard
        image: kubernetesui/dashboard:v2.7.0
        ports: [{ containerPort: 8443, protocol: TCP }]
        args:
          - --auto-generate-certificates
---
apiVersion: v1
kind: Service
metadata:
  labels: { k8s-app: kubernetes-dashboard }
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  type: NodePort
  ports:
    - port: 443
      targetPort: 8443
      nodePort: 30080
  selector:
    k8s-app: kubernetes-dashboard
"@ | Set-Content "$root/k8s/manifests/kubernetes-dashboard.yaml"

# -------------------------
# docker-compose.yml (Envoy L4 + everything else)
# -------------------------
@"
version: "3.9"

networks:
  edge:
  core:
  data:

volumes:
  jenkins_home:
  portainer_data:
  mssql_data:
  apisix_data:
  apisix_logs:
  grafana_data:

services:
  registry:
    image: registry:2
    container_name: registry
    networks: [core]
    ports:
      - "127.0.0.1:5000:5000"
    restart: unless-stopped

  etcd:
    image: bitnami/etcd:3.5
    container_name: etcd
    networks: [core]
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
      - ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
    restart: unless-stopped

  apisix:
    image: apache/apisix:3.9.1-debian
    container_name: apisix
    networks: [core]
    depends_on: [etcd]
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - apisix_data:/usr/local/apisix
      - apisix_logs:/usr/local/apisix/logs
    ports:
      - "127.0.0.1:9080:9080"
      - "127.0.0.1:9443:9443"
      - "127.0.0.1:9180:9180"
    restart: unless-stopped

  apisix-dashboard:
    image: apache/apisix-dashboard:3.0.1
    container_name: apisix-dashboard
    networks: [core]
    depends_on: [apisix, etcd]
    environment:
      - APIX_ETCD_ENDPOINTS=http://etcd:2379
    ports:
      - "127.0.0.1:9000:9000"
    restart: unless-stopped

  portainer:
    image: portainer/portainer-ce:2.19.4
    container_name: portainer
    networks: [core]
    ports:
      - "127.0.0.1:9440:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    restart: unless-stopped

  jenkins:
    image: jenkins/jenkins:lts
    container_name: jenkins
    user: root
    networks: [core]
    ports:
      - "127.0.0.1:8081:8080"
    volumes:
      - jenkins_home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped

  code:
    build: ./code
    container_name: code
    networks: [core]
    environment:
      - PASSWORD=devpass
    volumes:
      - ./workspace:/home/coder/project
      - ./k3s:/k3s
    ports:
      - "127.0.0.1:3001:8080"
    restart: unless-stopped

  mssql:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: mssql
    networks: [data]
    environment:
      - ACCEPT_EULA=Y
      - SA_PASSWORD=YourStrong!Passw0rd
      - MSSQL_PID=Developer
    ports:
      - "127.0.0.1:1433:1433"
    volumes:
      - mssql_data:/var/opt/mssql
    restart: unless-stopped

  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    networks: [core]
    depends_on: [portainer, jenkins, code, apisix, k3s, grafana]
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    restart: unless-stopped

  waf:
    image: nginx:1.27-alpine
    container_name: waf
    networks: [edge, core]
    depends_on: [nginx, apisix]
    ports:
      - "127.0.0.1:80:80"
    command: >
      /bin/sh -lc '
      apk add --no-cache modsecurity-nginx curl git && \
      mkdir -p /etc/nginx/modsec && \
      curl -sSL https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended -o /etc/nginx/modsec/modsecurity.conf && \
      sed -i "s/SecRuleEngine DetectionOnly/SecRuleEngine On/" /etc/nginx/modsec/modsecurity.conf && \
      curl -sSL https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/unicode.mapping -o /etc/nginx/modsec/unicode.mapping && \
      mkdir -p /etc/nginx/owasp-crs && \
      curl -sSL https://codeload.github.com/coreruleset/coreruleset/tar.gz/refs/tags/v3.2.0 | tar -xz --strip=1 -C /etc/nginx/owasp-crs && \
      cp /etc/nginx/owasp-crs/crs-setup.conf.example /etc/nginx/owasp-crs/crs-setup.conf && \
      cat >/etc/nginx/modsec/main.conf <<EOF
      Include /etc/nginx/modsec/modsecurity.conf
      SecRuleEngine On
      Include /etc/nginx/owasp-crs/crs-setup.conf
      Include /etc/nginx/owasp-crs/rules/*.conf
      EOF
      && cat >/etc/nginx/nginx.conf <<EOF
      load_module modules/ngx_http_modsecurity_module.so;
      user  nginx;
      worker_processes auto;
      events { worker_connections 1024; }
      http {
        modsecurity on;
        modsecurity_rules_file /etc/nginx/modsec/main.conf;
        upstream app_l7 { server nginx:8080; }
        upstream apigw  { server apisix:9080; }
        server {
          listen 80;
          location /api/ { proxy_set_header Host \$host; proxy_pass http://apigw; }
          location /     { proxy_set_header Host \$host; proxy_pass http://app_l7; }
        }
      }
      EOF
      && nginx -g "daemon off;"
      '
    restart: unless-stopped

  envoy:
    image: envoyproxy/envoy:v1.30.2
    container_name: envoy
    networks: [edge, core]
    depends_on: [waf, apisix]
    volumes:
      - ./envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro
    ports:
      - "127.0.0.1:8080:8080"   # L4 listener
      - "127.0.0.1:9901:9901"   # Admin/metrics
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
    restart: unless-stopped

  k3s:
    image: rancher/k3s:v1.28.9-k3s1
    container_name: k3s
    privileged: true
    networks: [core]
    environment:
      - K3S_KUBECONFIG_OUTPUT=/output/kubeconfig
      - K3S_KUBECONFIG_MODE=666
    command: server --disable traefik
    volumes:
      - ./k8s/manifests:/var/lib/rancher/k3s/server/manifests
      - ./k3s:/output
    ports:
      - "127.0.0.1:6443:6443"
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    networks: [core]
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "127.0.0.1:9090:9090"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    networks: [core]
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    ports:
      - "127.0.0.1:9093:9093"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.4.2
    container_name: grafana
    networks: [core]
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "127.0.0.1:3000:3000"
    restart: unless-stopped

  loki:
    image: grafana/loki:2.9.8
    container_name: loki
    networks: [core]
    command: -config.file=/etc/loki/config/loki-config.yml
    volumes:
      - ./loki/loki-config.yml:/etc/loki/config/loki-config.yml:ro
    ports:
      - "127.0.0.1:3100:3100"
    restart: unless-stopped

  promtail:
    image: grafana/promtail:2.9.8
    container_name: promtail
    networks: [core]
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./promtail/promtail-config.yml:/etc/promtail/config.yml:ro
    command: -config.file=/etc/promtail/config.yml
    restart: unless-stopped
"@ | Set-Content "$root/docker-compose.yml"

Write-Host "DevOps stack created at $root"
Write-Host "Next:"
Write-Host "  1) cd $root"
Write-Host "  2) docker compose up -d"
Write-Host "Then open:"
Write-Host "  - http://localhost            (WAF entry -> routes to /admin/, /jenkins/, /ide/, /k8s/, /grafana/, /api/)"
Write-Host "  - http://localhost:9000       (APISIX Dashboard)"
Write-Host "  - http://localhost:9901       (Envoy admin/metrics)"
Write-Host "Kubeconfig: $root/k3s/kubeconfig (export KUBECONFIG in IDE for kubectl)"