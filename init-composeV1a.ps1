# init-compose.ps1
# Generates docker-compose.yml with GUI toggle for registry export

$compose = @'
version: "3.9"

networks:
  edge:
  core:
  data:

services:

  envoy:
    image: envoyproxy/envoy:v1.30.2
    networks: [edge, core]
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:9901:9901"
    command: >
      /bin/sh -lc '
      echo "static_resources:
        listeners:
        - name: l4_listener
          address:
            socket_address: { address: 0.0.0.0, port_value: 8080 }
          filter_chains:
            - filters:
              - name: envoy.filters.network.tcp_proxy
                typed_config:
                  \"@type\": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
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
      admin:
        address:
          socket_address:
            address: 0.0.0.0
            port_value: 9901" > /tmp/envoy.yaml
      exec envoy -c /tmp/envoy.yaml --log-level info
      '

  waf:
    image: owasp/modsecurity-crs:nginx
    networks: [edge, core]
    ports:
      - "127.0.0.1:80:80"
    environment:
      - PARANOIA=1
      - PROXY=1

  nginx:
    image: nginx:1.27-alpine
    networks: [core]
    depends_on: [console, apisix, k3s, grafana, jenkins]
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:9113:9113"
    command: >
      /bin/sh -lc '
      echo "user nginx;
      worker_processes auto;
      events { worker_connections 2048; }
      http {
        server {
          listen 9113;
          location /stub_status { stub_status; access_log off; }
        }
        upstream ui_console { server console:7000; }
        upstream api_gw { server apisix:9080; }
        upstream grafana_ui { server grafana:3000; }
        upstream ui_k8s { server k3s:30080; }
        upstream ui_jenkins { server jenkins:8080; }
        server {
          listen 8080;
          location /console/ { proxy_pass http://ui_console; }
          location /grafana/ { proxy_pass http://grafana_ui; }
          location /k8s/ { proxy_pass http://ui_k8s; }
          location /jenkins/ { proxy_pass http://ui_jenkins; }
          location /api/ { proxy_pass http://api_gw; }
          location =/ { return 200 \"Stack online\"; }
        }
      }" > /etc/nginx/nginx.conf
      exec nginx -g "daemon off;"
      '

  console:
    image: nginx:1.27-alpine
    networks: [core]
    depends_on: [portainer, code]
    ports:
      - "127.0.0.1:7000:7000"
    command: >
      /bin/sh -lc '
      echo "user nginx;
      worker_processes auto;
      events { worker_connections 1024; }
      http {
        upstream portainer { server portainer:9443; }
        upstream codesrv { server code:8080; }
        server {
          listen 7000;
          location /admin/ { proxy_pass http://portainer; }
          location /ide/ { proxy_pass http://codesrv; }
        }
      }" > /etc/nginx/nginx.conf
      exec nginx -g "daemon off;"
      '

  portainer:
    image: portainer/portainer-ce:2.19.4
    networks: [core]
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - ENABLE_EXPORT=${ENABLE_EXPORT}

  code:
    image: codercom/code-server:latest
    networks: [core]
    environment:
      - PASSWORD=devpass

  etcd:
    image: quay.io/coreos/etcd:v3.5.15
    networks: [core]
    command:
      - /usr/local/bin/etcd
      - --advertise-client-urls=http://0.0.0.0:2379
      - --listen-client-urls=http://0.0.0.0:2379
      - --data-dir=/etcd-data

  apisix:
    image: apache/apisix:3.9.1-debian
    networks: [core]
    depends_on: [etcd]
    ports:
      - "127.0.0.1:9180:9180"
      - "127.0.0.1:9443:9443"
      - "127.0.0.1:9091:9091"
      - "127.0.0.1:9080:9080"

  apisix-dashboard:
    image: apache/apisix-dashboard:3.0.1
    networks: [core]
    depends_on: [apisix, etcd]
    ports:
      - "127.0.0.1:9000:9000"
    environment:
      - APIX_ETCD_ENDPOINTS=http://etcd:2379

  jenkins:
    image: jenkins/jenkins:lts
    networks: [core]
    ports:
      - "127.0.0.1:8081:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  registry:
    image: registry:2
    networks: [core]
    ports:
      - "127.0.0.1:5000:5000"
    volumes:
      - type: bind
        source: ./registry-export
        target: /var/lib/registry
        bind:
          propagation: rprivate
    environment:
      - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry
      - ENABLE_EXPORT=${ENABLE_EXPORT}

  mariadb:
    image: mariadb:11.4
    networks: [data]
    environment:
      - MARIADB_ROOT_PASSWORD=devpass
      - MARIADB_DATABASE=devdb
      - MARIADB_USER=dev
      - MARIADB_PASSWORD=devpass
    ports:
      - "127.0.0.1:3306:3306"

  k3s:
    image: rancher/k3s:v1.28.9-k3s1
    privileged: true
    networks: [core]
    ports:
      - "127.0.0.1:6443:6443"
      - "127.0.0.1:30080:30080"

  prometheus:
    image: prom/prometheus:v2.54.1
    networks: [core]
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:10.4.2
    networks: [core]
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin

  loki:
    image: grafana/loki:2.9.8
    networks: [core]
    ports:
      - "127.0.0.1:3100:3100"

  promtail:
    image: grafana/promtail:2.9.8
    networks: [core]
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
'@

Set-Content -Path "docker-compose.yml" -Value $compose
Write-Host "docker-compose.yml created successfully with registry export toggle."
Write-Host "To enable export, set ENABLE_EXPORT=true in Portainer or .env and redeploy."