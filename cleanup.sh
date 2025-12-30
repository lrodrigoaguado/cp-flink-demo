#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for Real-Time Fleet Monitoring demo
# Reverses run_all.sh steps and removes local artifacts.

log() { echo "[cleanup] $*"; }
try() {
  "$@" || {
    log "Command failed: $*"
    true
  }
}

# ---- Begin cleanup ----
log "Starting cleanup"

# Stop and remove Postgres containers
log "Stopping Postgres docker-compose"
try docker compose -f data/db/docker-compose.yml down -v

# K8s resources (only if cluster exists)
log "Deleting Kubernetes resources (if cluster exists)"
kind delete cluster

# Remove local encryption key
log "Removing local CMF encryption key file"
try rm -f ./certs/cmf.key

log "Cleanup completed"
