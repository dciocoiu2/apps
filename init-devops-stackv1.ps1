# init-devops-stack.ps1
# Creates a fully-contained local DevOps stack with nested Kubernetes (k3s),
# all configs, Kubernetes manifests, and a single docker-compose.yml.

$root = "devops-stack"
$dirs = @(
    "$root/haproxy",
    "$root/nginx",
    "$root/waf",
    "$root/apisix",
    "$root/code",
    "$root/backend-python/app",
    "$root/backend-go/app",
    "$root/frontend",
    "$root/workspace",
    "$root/k3s",
    "$root/k8s/manifests"
)

foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# -------------------------
# HAProxy (L4) config
# -------------------------
@"
global
    maxconn 2048
defaults
    mode tcp
    timeout connect 5s
    timeout client  50s
    timeout server  50s
frontend l4_front
    bind *:8080
    default_backend l4_pool
backend l4_pool
    balance roundrobin
    server waf1 waf:80 check
    server apisix1 apisix:9080 check
"@ | Set-Content "$root/haproxy/haproxy.cfg"

# -------------------------
# Nginx (L7) config
# -------------------------
@"
user  nginx;
worker_processes auto;
events { worker_connections 1024; }
http {
  upstream ui_portainer { server portainer:9443; }
  upstream ui_jenkins  { server jenkins:8080; }
  upstream ui_code     { server code:8080; }
  upstream api_gw      { server apisix:9080; }
  upstream ui_k8s      { server k3s:30080; }   # Kubernetes Dashboard via NodePort

  server {
    listen 8080;

    # Admin UIs
    location /admin/   { proxy_set_header Host \$host; proxy_pass http://ui_portainer; }
    location /jenkins/ { proxy_set_header Host \$host; proxy_pass http://ui_jenkins; }
    location /ide/     { proxy_set_header Host \$host; proxy_pass http://ui_code; }

    # Kubernetes Dashboard
    location /k8s/     { proxy_set_header Host \$host; proxy_pass http://ui_k8s; }

    # APIs to API Gateway
    location /api/     { proxy_set_header Host \$host; proxy_pass http://api_gw; }

    # Default landing
    location / {
      return 200 "DevOps stack online. Use /admin/, /jenkins/, /ide/, /k8s/, /api/.";
    }
  }
}
"@ | Set-Content "$root/nginx/nginx.conf"

# -------------------------
# APISIX config
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
    build-essential cmake git curl wget unzip zip ca-certificates gnupg \
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
# Optional polyglot service stubs (not required to run the stack)
# -------------------------
@"
FROM python:3.11-slim
WORKDIR /app
RUN pip install fastapi uvicorn[standard] pyodbc
COPY app /app
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
"@ | Set-Content "$root/backend-python/Dockerfile"

@"
from fastapi import FastAPI
app = FastAPI()
@app.get("/api/python/hello")
def hello():
    return {"msg": "Hello from Python"}
"@ | Set-Content "$root/backend-python/app/main.py"

@"
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY app /src
RUN go build -o /out/app /src/main.go
FROM alpine:3.20
WORKDIR /app
COPY --from=build /out/app /app/app
EXPOSE 9000
CMD ["/app/app"]
"@ | Set-Content "$root/backend-go/Dockerfile"

@"
package main
import (
  "fmt"
  "net/http"
)
func main() {
  http.HandleFunc("/api/go/hello", func(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintln(w, "Hello from Go")
  })
  http.ListenAndServe(":9000", nil)
}
"@ | Set-Content "$root/backend-go/app/main.go"

# -------------------------
# Kubernetes manifests (auto-applied by k3s from manifests dir)
# -------------------------

# Metrics Server (required for Dashboard metrics)
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
          image: k8s.gcr.io/metrics-server/metrics-server:v0.6.4
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

# Kubernetes Dashboard + admin user + NodePort service at 30080
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
# docker-compose.yml (FULL)
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

services:

  # Local registry (localhost only)
  registry:
    image: registry:2
    container_name: registry
    networks: [core]
    ports:
      - "127.0.0.1:5000:5000"
    restart: unless-stopped

  # etcd for APISIX
  etcd:
    image: bitnami/etcd:3.5
    container_name: etcd
    networks: [core]
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
      - ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
    restart: unless-stopped

  # API Gateway (Apache APISIX)
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

  # API Management UI
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

  # Admin dashboard with RBAC & stack/container deployment
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

  # CI/CD orchestrator
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

  # Polyglot Web IDE (includes kubectl, helm, k9s)
  code:
    build: ./code
    container_name: code
    networks: [core]
    environment:
      - PASSWORD=devpass
    volumes:
      - ./workspace:/home/coder/project
      - ./k3s:/k3s          # share kubeconfig with IDE
    ports:
      - "127.0.0.1:3001:8080"
    restart: unless-stopped

  # Microsoft SQL Server (Developer)
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

  # L7 reverse proxy for UIs and API gateway (behind WAF)
  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    networks: [core]
    depends_on: [portainer, jenkins, code, apisix, k3s]
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    restart: unless-stopped

  # WAF edge with ModSecurity + OWASP CRS 3.2 (local-only entry)
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

  # Layer 4 load balancer (TCP) local-only
  haproxy:
    image: haproxy:2.9
    container_name: haproxy
    networks: [edge, core]
    depends_on: [waf, apisix, nginx]
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: unless-stopped

  # Nested Kubernetes (k3s in Docker), API exposed at 127.0.0.1:6443
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
"@ | Set-Content "$root/docker-compose.yml"

Write-Host "DevOps + Nested Kubernetes stack created at $root"
Write-Host "Next:"
Write-Host "  1) cd $root"
Write-Host "  2) docker compose up -d"
Write-Host "Then open:"
Write-Host "  - http://localhost            (WAF entry)"
Write-Host "  - http://localhost/admin/     (Portainer)"
Write-Host "  - http://localhost/jenkins/   (Jenkins)"
Write-Host "  - http://localhost/ide/       (Web IDE; password: devpass)"
Write-Host "  - http://localhost/k8s/       (Kubernetes Dashboard)"
Write-Host "Kubernetes API: https://localhost:6443 (kubeconfig at devops-stack/k3s/kubeconfig)"