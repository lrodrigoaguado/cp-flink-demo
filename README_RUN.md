# Quick Run Guide

This guide explains how to start and stop the full demo using the provided scripts. It automates the steps from the main README with readiness checks and idempotent operations.

## Prerequisites

Install the following tools before running:
- kind
- kubectl
- helm
- docker
- openssl
- curl
- jq
- maven (`mvn`)

Ensure Docker is running and you have network access to pull images and Helm charts.

## Start Everything

Runs the end-to-end environment (Kubernetes, Confluent Platform, CP Flink, data generators, Elasticsearch, and Kibana) with readiness checks.

```bash
chmod +x run_all.sh
./run_all.sh
```

What the script does (high level):
- Creates a local kind cluster and `confluent` namespace.
- Installs CFK and ECK operators.
- Generates certificates and creates Kubernetes secrets (mTLS).
- Deploys Confluent Platform components from `cp/infra.yaml`.
- Starts background port-forwards for Control Center (`9021`), Kibana (`5601`), and Elasticsearch (`9200`).
- Starts Postgres via docker compose and waits for health.
- Applies Kafka topics and data sources (`data/topics.yaml`, `data/data_source.yaml`).
- Installs cert-manager, Flink operator, and Confluent Manager for Apache Flink.
- Applies CMF REST Class (`cp/cmf-rest-class.yaml`).
- Builds and loads the Flink SQL runner image into kind, then applies Flink environment and application (`flink/flink-*.yaml`).
- Creates Elasticsearch index templates and deploys the sink connector (`data/data_sink.yaml`).
- Imports a Kibana dashboard.

Access UIs:
- Control Center: https://controlcenter-ng.confluent.svc.cluster.local:9021/
- Kibana: https://localhost:5601 (user: `elastic` / `elastic`)
- Elasticsearch: http://localhost:9200

Note: `run_all.sh` will add an `/etc/hosts` entry mapping `controlcenter-ng.confluent.svc.cluster.local` to `127.0.0.1` if it is not already present (sudo required) to ensure Control Center access.

## Verify

Basic checks after `run_all.sh` completes:

```bash
kubectl -n confluent get pods
kubectl -n confluent get connector
kubectl -n confluent logs deployment/vehicle-data-generator --tail=50
curl -u elastic:elastic http://localhost:9200/_cat/indices?v
```

You should see:
- All pods Ready in `confluent`.
- Connectors `vehicle-info` and `elastic-sink` in RUNNING state.
- `vehicle-location` and `vehicle-info` topics receiving data.
- Kibana dashboard imported and indices created.

## Rebuild & Redeploy Flink (optional)

If you modify the Flink SQL (e.g., `flink-sql/flink-sql-runner-example/sql-scripts/kafka.sql`), rebuild and reload the image, then re-apply the application:

```bash
cd flink-sql/flink-sql-runner-example
mvn clean verify
DOCKER_BUILDKIT=1 docker build . -t flink-sql-runner-example:latest
kind load docker-image flink-sql-runner-example:latest
cd ../..

kubectl apply -f flink/flink-application.yaml
```

## Cleanup

Tears down all resources and stops background processes.

```bash
chmod +x cleanup.sh
./cleanup.sh
```

What `cleanup.sh` does:
- Shuts down Postgres (docker compose) and removes volumes.
- Deletes the kind cluster (and all resources related to it).
- Removes local `./certs/cmf.key` file.

## Troubleshooting

- If `kubectl_wait_all_ready` times out, inspect pod events:
  ```bash
  kubectl -n confluent get pods
  kubectl -n confluent describe pod <pod-name>
  ```
- If connectors hang in `CREATED`, check Connect logs:
  ```bash
  kubectl -n confluent logs sts/connect -c connect --tail=200
  ```
- If Control Center does not resolve at `https://controlcenter-ng.confluent.svc.cluster.local:9021/`, configure DNS resolution for that hostname to `127.0.0.1`.
