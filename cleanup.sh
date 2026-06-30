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

# Stop background port-forwards started by run_all.sh
PORT_FORWARD_PID_FILE="${TMPDIR:-/tmp}/cp-flink-demo-portforward.pids"
if [[ -f "$PORT_FORWARD_PID_FILE" ]]; then
  log "Stopping background port-forwards"
  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < "$PORT_FORWARD_PID_FILE"
  rm -f "$PORT_FORWARD_PID_FILE"
fi
# Fallback: stop any lingering port-forwards for the confluent namespace
pkill -f "kubectl -n confluent port-forward" 2>/dev/null || true

# Stop and remove Postgres containers
log "Stopping Postgres docker-compose"
try docker compose -f data/db/docker-compose.yml down -v

# Stop and remove MinIO object storage
log "Stopping MinIO docker-compose"
try docker compose -f minio/docker-compose.yml down -v

# K8s resources (only if cluster exists)
log "Deleting Kubernetes resources (if cluster exists)"
kind delete cluster

# Remove local encryption key
log "Removing local CMF encryption key file"
try rm -f ./certs/cmf.key

# Offer to remove the /etc/hosts entry added during setup
HOSTS_ENTRY="controlcenter-ng.confluent.svc.cluster.local"
if grep -qE "127\.0\.0\.1[[:space:]]+${HOSTS_ENTRY}" /etc/hosts 2>/dev/null; then
  if [[ -t 0 ]]; then
    read -r -p "[cleanup] Remove the /etc/hosts entry for ${HOSTS_ENTRY}? (requires sudo) [y/N] " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      sudo sed -i.bak "/${HOSTS_ENTRY}/d" /etc/hosts && log "Removed /etc/hosts entry"
    else
      log "Left /etc/hosts entry in place"
    fi
  else
    log "An /etc/hosts entry for ${HOSTS_ENTRY} remains. Remove it with:"
    log "  sudo sed -i.bak '/${HOSTS_ENTRY}/d' /etc/hosts"
  fi
fi

log "Cleanup completed"
