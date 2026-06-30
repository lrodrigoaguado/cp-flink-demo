#!/usr/bin/env bash
set -euo pipefail

# Real-Time Fleet Monitoring end-to-end runner
# Automates README steps with readiness checks.
#
# Usage: ./run_all.sh [--from PHASE] [--only PHASE] [--no-background-build] [-h|--help]
# Phases run in this order:
#   preconditions -> cluster -> operators -> certs -> cp -> data -> flink -> es
# Each phase mirrors a numbered section of the README, so the two deploy paths
# stay easy to keep in sync.

# Load pinned versions (single source of truth shared with the manual README).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

# Track background port-forward PIDs so cleanup.sh can stop them later.
PORT_FORWARD_PID_FILE="${TMPDIR:-/tmp}/cp-flink-demo-portforward.pids"
: > "$PORT_FORWARD_PID_FILE"

# Background Flink image build bookkeeping (see start_image_build_bg / finish_image_build).
IMAGE_BUILD_LOG="${TMPDIR:-/tmp}/cp-flink-demo-image-build.log"
IMAGE_BUILD_PID=""

# -------- Utilities --------
log() { echo "[run_all] $*"; }
err() { echo "[run_all][ERROR] $*" >&2; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command not found: $cmd"; exit 1; }
}

# Wait until all pods in a namespace are Ready
kubectl_wait_all_ready() {
  local ns="$1"; local timeout="${2:-600s}"
  local timeout_secs
  timeout_secs=$(echo "$timeout" | sed -E 's/s$//')
  [[ -z "$timeout_secs" ]] && timeout_secs=600

  # First, wait until there is at least one pod in the namespace
  local start=$(date +%s)
  while true; do
    local count
    count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [[ "${count:-0}" -gt 0 ]]; then break; fi
    local now=$(date +%s)
    if (( now - start > timeout_secs )); then
      err "Timeout waiting for any pods to appear in namespace $ns"; kubectl -n "$ns" get pods || true; exit 1
    fi
    sleep 3
  done

  # Then, wait for all pods to become Ready
  kubectl wait --for=condition=Ready pod --all -n "$ns" --timeout="$timeout" || {
    err "Timeout waiting for pods Ready in namespace $ns"; kubectl -n "$ns" get pods; exit 1;
  }
}

# Wait for endpoints to have at least one address
wait_endpoints_ready() {
  local ns="$1"; local name="$2"; local timeout_secs="${3:-120}"
  local start=$(date +%s)
  while true; do
    local count
    count=$(kubectl get endpoints "$name" -n "$ns" -o jsonpath="{range .subsets[*]}{.addresses[*].ip}{'\n'}{end}" 2>/dev/null | awk 'NF' | wc -l | tr -d ' ' || true)
    if [[ "${count:-0}" -gt 0 ]]; then
      log "Endpoints $ns/$name ready with $count address(es)"; break
    fi
    local now=$(date +%s)
    if (( now - start > timeout_secs )); then
      err "Timeout waiting for endpoints $ns/$name to be ready"; kubectl -n "$ns" get endpoints "$name" || true; exit 1
    fi
    sleep 3
  done
}

# Wait for a docker container to report healthy
wait_container_healthy() {
  local name="$1"; local timeout_secs="${2:-120}"
  local start=$(date +%s)
  while true; do
    local status
    status=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")
    if [[ "$status" == "healthy" ]]; then log "Container $name is healthy"; break; fi
    local now=$(date +%s)
    if (( now - start > timeout_secs )); then err "Timeout: container $name health=$status"; exit 1; fi
    sleep 3
  done
}

# Wait for CFK Connector to be RUNNING
wait_connector_running() {
  local name="$1"; local ns="$2"; local timeout_secs="${3:-240}"
  local start=$(date +%s)
  while true; do
    local j state tasksReady taskMax
    j=$(kubectl get connector "$name" -n "$ns" -o json 2>/dev/null || echo "")
    if [[ -n "$j" ]]; then
      # Try multiple status fields used by CFK
      state=$(jq -r '.status.connector.state // .status.connectorStatus // .status.connectorState // .status.taskStatus?.connectorState // empty' <<<"$j")
      tasksReady=$(jq -r '.status.tasksReady // empty' <<<"$j")
      taskMax=$(jq -r '.spec.taskMax // empty' <<<"$j")
      if [[ "$state" == "RUNNING" ]]; then
        if [[ -n "$taskMax" && -n "$tasksReady" && "$tasksReady" == "$taskMax" ]]; then
          log "Connector $name RUNNING ($tasksReady/$taskMax tasks)"; break;
        else
          log "Connector $name RUNNING"; break;
        fi
      fi
    fi
    local now=$(date +%s)
    if (( now - start > timeout_secs )); then
      err "Timeout waiting for connector $name to be RUNNING"
      kubectl -n "$ns" get connector "$name" -o yaml || true
      exit 1
    fi
    sleep 4
  done
}

# Ensure Control Center DNS resolves locally to 127.0.0.1
ensure_hosts_mapping() {
  local host="$1"; local ip="${2:-127.0.0.1}"
  # Check if an exact mapping to 127.0.0.1 already exists
  if grep -qE "^[[:space:]]*${ip}[[:space:]]+${host}[[:space:]]*$" /etc/hosts; then
    log "Hosts entry for $host -> $ip already present"
    return 0
  fi
  log "Adding hosts entry for $host -> $ip (sudo required)"
  if echo "${ip}    ${host}" | sudo tee -a /etc/hosts >/dev/null; then
    log "Hosts entry added"
  else
    err "Failed to add hosts entry. Please add: '${ip}    ${host}' to /etc/hosts manually."
  fi
}

port_forward_bg() {
  local ns="$1"; shift
  local resource_args=("$@")
  # Example: port_forward_bg confluent svc/kibana-kb-http 5601:5601
  nohup kubectl -n "$ns" port-forward "${resource_args[@]}" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >> "$PORT_FORWARD_PID_FILE"
  log "Port-forward started: kubectl -n $ns port-forward ${resource_args[*]} (pid=$pid)"
}

# Build the Flink SQL Runner image in the background so it overlaps with the
# (slow) Confluent Platform / Flink bring-up. Requires the mTLS certs produced
# by the certs phase to already exist.
start_image_build_bg() {
  log "Starting Flink SQL Runner image build in background (log: $IMAGE_BUILD_LOG)"
  (
    cd flink-sql/flink-sql-runner-example
    mvn clean verify && DOCKER_BUILDKIT=1 docker build . -t flink-sql-runner-example:latest
  ) >"$IMAGE_BUILD_LOG" 2>&1 &
  IMAGE_BUILD_PID=$!
}

# Ensure the image exists (wait for the background build if one was started,
# otherwise build inline) and load it into the kind cluster.
finish_image_build() {
  if [[ -n "${IMAGE_BUILD_PID:-}" ]]; then
    log "Waiting for background image build (pid=$IMAGE_BUILD_PID) to finish"
    if wait "$IMAGE_BUILD_PID"; then
      log "Background image build completed"
    else
      err "Background image build failed; last lines of $IMAGE_BUILD_LOG:"
      tail -n 50 "$IMAGE_BUILD_LOG" || true
      exit 1
    fi
  else
    log "Building Flink SQL Runner image (inline)"
    pushd flink-sql/flink-sql-runner-example >/dev/null
    mvn clean verify
    DOCKER_BUILDKIT=1 docker build . -t flink-sql-runner-example:latest
    popd >/dev/null
  fi
  log "Loading image into kind"
  kind load docker-image flink-sql-runner-example:latest
}

# -------- Phases (mirror the README sections) --------

phase_preconditions() {
  log "[phase: preconditions] Checking required tools"
  for c in kind kubectl helm docker openssl curl jq mvn; do require_cmd "$c"; done
}

# 1. Create Kubernetes cluster
phase_cluster() {
  log "[phase: cluster] Creating Kubernetes cluster"
  if ! kind get clusters | grep -q '^kind$'; then
    log "Creating kind cluster ($KIND_NODE_IMAGE)"
    kind create cluster --image "$KIND_NODE_IMAGE"
  else
    log "kind cluster already exists"
  fi
  kubectl config use-context kind-kind >/dev/null 2>&1 || true
  kubectl get namespace confluent >/dev/null 2>&1 || kubectl create namespace confluent
  kubectl config set-context --current --namespace=confluent
}

# 2. Start Confluent Platform operators
phase_operators() {
  log "[phase: operators] Adding Helm repos and installing CFK & ECK operators"
  helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
  helm repo add elastic https://helm.elastic.co >/dev/null 2>&1 || true
  helm repo update
  helm upgrade --install operator confluentinc/confluent-for-kubernetes --version "$CFK_OPERATOR_VERSION"
  helm upgrade --install elastic-operator elastic/eck-operator --version "$ECK_OPERATOR_VERSION" -n confluent
  log "Waiting for operator pods to be ready"
  kubectl_wait_all_ready "confluent" 600s
}

# Configure security (mTLS): certificates + Kubernetes secrets
phase_certs() {
  log "[phase: certs] Generating certificates and creating Kubernetes secrets"
  bash ./scripts/generate_certificates.sh
  bash ./scripts/create_secrets.sh
}

# 2. Deploy Confluent Platform components and expose the UIs
phase_cp() {
  log "[phase: cp] Applying Confluent Platform infrastructure"
  kubectl apply -f cp/infra.yaml
  log "Waiting for Confluent Platform components to be Ready (this can take minutes)"
  kubectl_wait_all_ready "confluent" 1200s
  # Make sure Control Center is actually up before forwarding its port.
  log "Waiting for Control Center pod to be ready"
  kubectl wait --for=condition=Ready pod/controlcenter-ng-0 -n confluent --timeout=1200s || true
  ensure_hosts_mapping "controlcenter-ng.confluent.svc.cluster.local" "127.0.0.1"
  port_forward_bg confluent controlcenter-ng-0 9021:9021
  port_forward_bg confluent svc/kibana-kb-http 5601:5601
  port_forward_bg confluent svc/elasticsearch-es-http 9200:9200
}

# 3. Feed test data
phase_data() {
  log "[phase: data] Starting Postgres for vehicle_description"
  docker compose -f data/db/docker-compose.yml up -d --force-recreate
  wait_container_healthy "vehicles-postgres" 180

  log "Creating Kafka topics"
  kubectl apply -f data/topics.yaml

  log "Creating road points configmap"
  kubectl create configmap road-points-config \
    --from-file=road_points.json=etc/road_points.json \
    -n confluent \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying data generators (Connector + Python generator)"
  kubectl apply -f data/data-source.yaml

  log "Waiting for vehicle-data-generator deployment to be ready"
  kubectl rollout status deployment/vehicle-data-generator -n confluent --timeout=300s

  log "Waiting for Datagen connector to be RUNNING"
  wait_connector_running "vehicle-info" "confluent" 300
}

# 4 + 5. Install CP Flink (cert-manager, operator, CMF) and run the Flink app
phase_flink() {
  log "[phase: flink] Installing cert-manager (required by Flink operator)"
  kubectl create -f "https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

  log "Waiting for cert-manager webhook endpoints"
  wait_endpoints_ready "cert-manager" "cert-manager-webhook" 180

  log "Installing Flink operator and Confluent Manager for Apache Flink"
  helm upgrade --install cp-flink-kubernetes-operator --version "$FLINK_OPERATOR_VERSION" confluentinc/flink-kubernetes-operator --set watchNamespaces="{confluent}"

  log "Creating CMF encryption key secret"
  openssl rand -out ./certs/cmf.key 32
  kubectl create secret generic cmf-encryption-key --from-file=encryption-key=./certs/cmf.key -n confluent --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install -f cp/mtls-cmf.yaml cmf confluentinc/confluent-manager-for-apache-flink \
      --version "$CMF_VERSION" \
      --set cmf.logging.level.root=debug \
      --set cmf.sql.production=true \
      --set encryption.key.kubernetesSecretName=cmf-encryption-key \
      --set encryption.key.kubernetesSecretProperty=encryption-key \
      --namespace confluent

  log "Waiting for CMF and Flink operator pods"
  kubectl_wait_all_ready "confluent" 600s

  log "Port-forward CMF service"
  port_forward_bg confluent service/cmf-service 8080:80

  log "Deploying CMF REST Class"
  kubectl apply -f cp/cmf-rest-class.yaml

  # Control Center came up in the 'cp' phase, before CMF existed, so it initialised
  # its CMF/Flink integration as unavailable and never recovers on its own. Restart
  # it now that CMF is reachable so the Flink view populates, then re-establish its
  # port-forward (the old one died with the recreated pod).
  log "Restarting Control Center to detect the now-available CMF/Flink endpoint"
  kubectl delete pod controlcenter-ng-0 -n confluent --ignore-not-found
  kubectl wait --for=condition=Ready pod/controlcenter-ng-0 -n confluent --timeout=600s
  port_forward_bg confluent controlcenter-ng-0 9021:9021

  # Ensure the image is built (waits for the background build if one was started)
  # and load it into kind.
  finish_image_build

  log "Applying Flink Environment and Application"
  kubectl apply -f flink/flink-environment.yaml
  kubectl apply -f flink/flink-application.yaml

  log "Waiting for Flink JobManager and TaskManagers"
  kubectl_wait_all_ready "confluent" 600s
}

# 6. Write results to Elasticsearch and import the Kibana dashboard
phase_es() {
  log "[phase: es] Creating Elasticsearch index templates"
  curl -sS -X PUT "http://localhost:9200/_index_template/vehicle-alerts-template" \
    -u elastic:elastic \
    -H 'Content-Type: application/json' \
    -d '{
      "index_patterns": ["vehicle-alerts-enriched*"],
      "template": {"mappings": {"properties": {"vehicle_id": {"type": "keyword"}, "ts": {"type": "date", "format": "epoch_millis"}, "location": {"type": "geo_point"}}}}
    }' | jq -r '.acknowledged // .status // .error?.reason' || true

  curl -sS -X PUT "http://localhost:9200/_index_template/vehicle-locations-template" \
    -u elastic:elastic \
    -H 'Content-Type: application/json' \
    -d '{
      "template": {"mappings": {"properties": {"vehicle_id": {"type": "keyword"}, "ts": {"type": "date", "format": "epoch_millis"}, "location": {"type": "geo_point"}}}},
      "index_patterns": ["vehicle-location*"]
    }' | jq -r '.acknowledged // .status // .error?.reason' || true

  log "Deploying Elasticsearch Sink Connectors"
  kubectl apply -f data/data-sink.yaml
  wait_connector_running "elastic-sink-location" "confluent" 300
  wait_connector_running "elastic-sink-alerts" "confluent" 300

  log "Importing Kibana dashboard"
  curl -sS -X POST "https://localhost:5601/api/saved_objects/_import?overwrite=true" \
    -u elastic:elastic \
    -H "kbn-xsrf: true" \
    --form file=@./kibana/fleet_alerts.ndjson \
    -k | jq -r '.success // .statusCode // .message' || true

  log "All steps completed. Access UIs:"
  log "- Control Center: https://controlcenter-ng.confluent.svc.cluster.local:9021/ (user: admin, if configured)"
  log "- Kibana: https://localhost:5601 (user: elastic / elastic)"
  log "- Elasticsearch: http://localhost:9200"
}

# -------- Orchestration --------
PHASE_ORDER=(preconditions cluster operators certs cp data flink es)

usage() {
  cat <<EOF
Usage: ./run_all.sh [--from PHASE] [--only PHASE] [--no-background-build] [-h|--help]

Phases (in order): ${PHASE_ORDER[*]}

  --from PHASE             Resume the run starting at PHASE (skips earlier phases).
  --only PHASE             Run a single PHASE and stop.
  --no-background-build    Build the Flink image inline instead of in the background.
  -h, --help               Show this help.

Note: --from/--only assume the side effects of earlier phases (e.g. the
port-forwards created by the 'cp' and 'flink' phases) are already in place.
EOF
}

validate_phase() {
  local p="$1"
  for known in "${PHASE_ORDER[@]}"; do
    [[ "$p" == "$known" ]] && return 0
  done
  err "Unknown phase: $p (valid: ${PHASE_ORDER[*]})"; exit 1
}

START_PHASE="${PHASE_ORDER[0]}"
ONLY_PHASE=""
BACKGROUND_BUILD="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) START_PHASE="${2:?--from requires a phase}"; shift 2 ;;
    --only) ONLY_PHASE="${2:?--only requires a phase}"; shift 2 ;;
    --no-background-build) BACKGROUND_BUILD="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

run_phase() {
  local p="$1"
  case "$p" in
    preconditions) phase_preconditions ;;
    cluster)       phase_cluster ;;
    operators)     phase_operators ;;
    certs)
      phase_certs
      # Overlap the (slow) image build with the rest of the bring-up.
      [[ "$BACKGROUND_BUILD" == "true" ]] && start_image_build_bg
      ;;
    cp)    phase_cp ;;
    data)  phase_data ;;
    flink) phase_flink ;;
    es)    phase_es ;;
  esac
}

if [[ -n "$ONLY_PHASE" ]]; then
  validate_phase "$ONLY_PHASE"
  run_phase "$ONLY_PHASE"
else
  validate_phase "$START_PHASE"
  started=0
  for p in "${PHASE_ORDER[@]}"; do
    if [[ "$started" -eq 0 && "$p" != "$START_PHASE" ]]; then continue; fi
    started=1
    run_phase "$p"
  done
fi
