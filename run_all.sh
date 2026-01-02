#!/usr/bin/env bash
set -euo pipefail

# Real-Time Fleet Monitoring end-to-end runner
# Automates README steps with readiness checks.

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
  log "Port-forward started: kubectl -n $ns port-forward ${resource_args[*]} (pid=$pid)"
}

# -------- Preconditions --------
log "Checking required tools"
for c in kind kubectl helm docker openssl curl jq mvn; do require_cmd "$c"; done

# -------- 1. Create Kubernetes cluster --------
if ! kind get clusters | grep -q '^kind$'; then
  log "Creating kind cluster (v1.31.0)"
  kind create cluster --image kindest/node:v1.31.0
else
  log "kind cluster already exists"
fi

# Point kubectl to kind context and create namespace
kubectl config use-context kind-kind >/dev/null 2>&1 || true
kubectl get namespace confluent >/dev/null 2>&1 || kubectl create namespace confluent
kubectl config set-context --current --namespace=confluent

# Optional: Dashboard (skipped here)

# -------- 2. Start Confluent Platform Operators --------
log "Adding Helm repos and installing CFK & ECK operators"
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo add elastic https://helm.elastic.co >/dev/null 2>&1 || true
helm repo update

helm upgrade --install operator confluentinc/confluent-for-kubernetes
helm upgrade --install elastic-operator elastic/eck-operator -n confluent

log "Waiting for operator pods to be ready"
kubectl_wait_all_ready "confluent" 600s

# -------- Configure Security (mTLS) --------
log "Generating certificates and creating Kubernetes secrets"
 bash ./generate_certificates.sh
 bash ./create_secrets.sh

# -------- Deploy Confluent Components --------
log "Applying Confluent Platform infrastructure"
kubectl apply -f cp/infra.yaml

log "Waiting for Confluent Platform components to be Ready (this can take minutes)"
kubectl_wait_all_ready "confluent" 1200s

# -------- Access UIs via port-forward --------
ensure_hosts_mapping "controlcenter-ng.confluent.svc.cluster.local" "127.0.0.1"
port_forward_bg confluent controlcenter-ng-0 9021:9021
port_forward_bg confluent svc/kibana-kb-http 5601:5601
port_forward_bg confluent svc/elasticsearch-es-http 9200:9200

# -------- 3. Feed test data --------
log "Starting Postgres for vehicle_description"
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
kubectl apply -f data/data_source.yaml

log "Waiting for vehicle-data-generator deployment to be ready"
kubectl rollout status deployment/vehicle-data-generator -n confluent --timeout=300s

log "Waiting for Datagen connector to be RUNNING"
wait_connector_running "vehicle-info" "confluent" 300

# -------- 4. Install CP Flink --------
log "Installing cert-manager (required by Flink operator)"
kubectl create -f https://github.com/jetstack/cert-manager/releases/download/v1.18.2/cert-manager.yaml

log "Waiting for cert-manager webhook endpoints"
wait_endpoints_ready "cert-manager" "cert-manager-webhook" 180

log "Installing Flink operator and Confluent Manager for Apache Flink"
helm upgrade --install cp-flink-kubernetes-operator --version "~1.130.1" confluentinc/flink-kubernetes-operator --set watchNamespaces="{confluent}"

log "Creating CMF encryption key secret"
openssl rand -out ./certs/cmf.key 32
kubectl create secret generic cmf-encryption-key --from-file=encryption-key=./certs/cmf.key -n confluent --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install -f cp/mtls-cmf.yaml cmf confluentinc/confluent-manager-for-apache-flink \
    --version "~2.1.0" \
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

# -------- 5. Process the data with Flink --------
log "Building Flink SQL Runner image and loading into kind"
pushd flink-sql/flink-sql-runner-example >/dev/null
mvn clean verify
DOCKER_BUILDKIT=1 docker build . -t flink-sql-runner-example:latest
kind load docker-image flink-sql-runner-example:latest
popd >/dev/null

log "Applying Flink Environment and Application"
kubectl apply -f flink/flink-environment.yaml
kubectl apply -f flink/flink-application.yaml

log "Waiting for Flink JobManager and TaskManagers"
# naive wait: if pods contain flink-app1 and are Ready
# Fallback to general wait as the namespace is focused on demo
kubectl_wait_all_ready "confluent" 600s

# -------- 6. Elasticsearch sink --------
log "Creating Elasticsearch index templates"
curl -sS -X PUT "http://localhost:9200/_index_template/vehicle-alerts-template" \
  -u elastic:elastic \
  -H 'Content-Type: application/json' \
  -d '{
    "index_patterns": ["vehicle-alerts-enriched*"],
    "template": {"mappings": {"properties": {"ts": {"type": "date", "format": "epoch_millis"}}}}
  }' | jq -r '.acknowledged // .status // .error?.reason' || true

curl -sS -X PUT "http://localhost:9200/_index_template/vehicle-locations-template" \
  -u elastic:elastic \
  -H 'Content-Type: application/json' \
  -d '{
    "template": {"mappings": {"properties": {"vehicle_id": {"type": "keyword"}, "ts": {"type": "date", "format": "epoch_millis"}, "location": {"type": "geo_point"}}}},
    "index_patterns": ["vehicle-location*"]
  }' | jq -r '.acknowledged // .status // .error?.reason' || true

log "Deploying Elasticsearch Sink Connector"
kubectl apply -f data/data_sink.yaml
wait_connector_running "elastic-sink" "confluent" 300

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

