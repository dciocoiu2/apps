#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path (Get-Location) 'infra-stack'
$composePath = Join-Path $root 'docker-compose.yml'

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

if (Test-Path $composePath) {
  Push-Location $root
  Write-Host "Stopping and removing stack..."
  Invoke-Compose 'down --remove-orphans --volumes'
  Pop-Location
} else {
  Write-Host "No docker-compose.yml found in $root"
}

Write-Host "All containers, networks, and ephemeral volumes have been removed."