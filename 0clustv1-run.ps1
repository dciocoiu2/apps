#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path (Get-Location) 'infra-stack'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$composePath = Join-Path $root 'docker-compose.yml'

# Write the full docker-compose.yml we built earlier
@"
# (paste the complete docker-compose.yml content here)
"@ | Set-Content -Path $composePath -Encoding UTF8

function Invoke-Compose {
  param([string]$Args)
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    try {
      docker compose version | Out-Null
      docker compose $Args
    } catch {
      if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        docker-compose $Args
      } else {
        throw "Docker Compose not found."
      }
    }
  } else {
    throw "Docker not found."
  }
}

Push-Location $root
Invoke-Compose 'up -d'

Write-Host "Waiting for Vault..."
Start-Sleep -Seconds 12

$env:VAULT_ADDR = 'http://127.0.0.1:8200'
$env:VAULT_TOKEN = 'root-token'

docker exec vault vault secrets enable -path=app kv-v2 | Out-Null
docker exec vault vault kv put app/api1 db_user=root db_pass=changeme ldap_bind_pass=changeme | Out-Null
docker exec vault vault kv put app/api2 db_user=root db_pass=changeme ldap_bind_pass=changeme | Out-Null

$urls = @(
  'Vault UI:          http://127.0.0.1:8201  (root-token)',
  'RabbitMQ1:         http://127.0.0.1:15672 (admin/changeme)',
  'RabbitMQ2:         http://127.0.0.1:15673 (admin/changeme)',
  'Redis Commander:   http://127.0.0.1:8085',
  'Adminer (MariaDB): http://127.0.0.1:8083',
  'Mongo Express:     http://127.0.0.1:8084',
  'phpLDAPadmin:      http://127.0.0.1:8082',
  'Prometheus:        http://127.0.0.1:9090',
  'Grafana:           http://127.0.0.1:3000 (admin/changeme)',
  'API1 via WAF:      http://127.0.0.1:8080',
  'API2 via WAF:      http://127.0.0.1:8081'
)
$urls | ForEach-Object { Write-Host $_ }

Pop-Location