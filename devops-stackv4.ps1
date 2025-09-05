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
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:8443:8443"
      - "127.0.0.1:9113:9113"
    environment:
      - ENABLE_TLS=true
      - RBAC_ENABLED=true

  console:
    image: nginx:1.27-alpine
    networks: [core]
    ports:
      - "127.0.0.1:7000:7000"

  portainer:
    image: portainer/portainer-ce:2.19.4
    networks: [core]
    ports:
      - "127.0.0.1:9443:9443"
    environment:
      - ENABLE_EXPORT=true
      - RBAC_ENABLED=true

  code:
    image: codercom/code-server:latest
    networks: [core]
    environment:
      - PASSWORD=devpass
      - ENABLE_LANG_SUPPORT=true
      - RBAC_ENABLED=true

  etcd:
    image: quay.io/coreos/etcd:v3.5.15
    networks: [core]

  apisix:
    image: apache/apisix:3.9.1-debian
    networks: [core]
    depends_on: [etcd]
    ports:
      - "127.0.0.1:9180:9180"
      - "127.0.0.1:9443:9443"
      - "127.0.0.1:9091:9091"
      - "127.0.0.1:9080:9080"
    environment:
      - ENABLE_TLS=true
      - RBAC_ENABLED=true

  apisix-dashboard:
    image: apache/apisix-dashboard:3.0.1
    networks: [core]
    depends_on: [apisix, etcd]
    ports:
      - "127.0.0.1:9000:9000"
    environment:
      - APIX_ETCD_ENDPOINTS=http://etcd:2379
      - RBAC_ENABLED=true

  jenkins:
    image: jenkins/jenkins:lts
    networks: [core]
    ports:
      - "127.0.0.1:8081:8080"
    environment:
      - RBAC_ENABLED=true

  registry:
    image: registry:2
    networks: [core]
    ports:
      - "127.0.0.1:5000:5000"
    environment:
      - RBAC_ENABLED=true

  registry-ui:
    image: joxit/docker-registry-ui:latest
    networks: [core]
    depends_on: [registry]
    ports:
      - "127.0.0.1:8082:80"
    environment:
      - REGISTRY_URL=http://registry:5000
      - DELETE_IMAGES=true
      - RBAC_ENABLED=true

  registry-cleaner:
    image: alpine:3.19
    networks: [core]
    entrypoint: sh
    command: -c "while true; do find /var/lib/registry -type f -name '*.tar' -mtime +7 -delete; sleep 3600; done"

  image-importer:
    image: docker:cli
    networks: [core]
    entrypoint: sh
    command: -c "for f in /var/lib/registry/*.tar; do docker load -i $f; done"

  image-pusher:
    image: docker:cli
    networks: [core]
    environment:
      - REMOTE_REGISTRY=docker.io
      - USERNAME=yourusername
      - PASSWORD=yourpassword
    entrypoint: sh
    command: -c "echo $PASSWORD | docker login $REMOTE_REGISTRY -u $USERNAME --password-stdin && docker push $REMOTE_REGISTRY/yourimage:latest"

  mariadb:
    image: mariadb:11.4
    networks: [data]
    environment:
      - ENABLE_DB=true
      - MARIADB_ROOT_PASSWORD=devpass
      - MARIADB_DATABASE=devdb
      - MARIADB_USER=dev
      - MARIADB_PASSWORD=devpass
    ports:
      - "127.0.0.1:3306:3306"

  mysql:
    image: mysql:8.3
    networks: [data]
    environment:
      - ENABLE_DB=true
      - MYSQL_ROOT_PASSWORD=devpass
      - MYSQL_DATABASE=devdb
      - MYSQL_USER=dev
      - MYSQL_PASSWORD=devpass
    ports:
      - "127.0.0.1:3307:3306"

  mssql:
    image: mcr.microsoft.com/mssql/server:2022-lts
    networks: [data]
    environment:
      - ENABLE_DB=true
      - ACCEPT_EULA=Y
      - SA_PASSWORD=DevPass123!
    ports:
      - "127.0.0.1:1433:1433"

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
      - RBAC_ENABLED=true

  loki:
    image: grafana/loki:2.9.8
    networks: [core]
    ports:
      - "127.0.0.1:3100:3100"

  promtail:
    image: grafana/promtail:2.9.8
    networks: [core]

  admin-overview:
    image: nginx:1.27-alpine
    networks: [core]
    ports:
      - "127.0.0.1:7777:80"
    environment:
      - RBAC_ENABLED=true

  onboarding-ui:
    image: node:20-alpine
    networks: [core]
    ports:
      - "127.0.0.1:7788:80"
    entrypoint: sh
    command: -c "npx serve /onboarding-ui"
    environment:
      - RBAC_ENABLED=true