#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" != "--apply" ]; then
  echo 'This preparation-only command creates/verifies barcode-events-quarantine.' >&2
  echo "usage: $0 --apply" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml"
compose=(docker compose --env-file "$repo_root/.env" -f "$base_compose" -f "$release_compose")
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"

"${compose[@]}" exec -T broker-1 kafka-topics \
  --bootstrap-server "$bootstrap" \
  --create --if-not-exists \
  --topic barcode-events-quarantine \
  --partitions 3 \
  --replication-factor 3 \
  --config min.insync.replicas=2

"${compose[@]}" exec -T broker-1 kafka-topics \
  --bootstrap-server "$bootstrap" --describe --topic barcode-events-quarantine
"${compose[@]}" exec -T broker-1 kafka-configs \
  --bootstrap-server "$bootstrap" --entity-type topics \
  --entity-name barcode-events-quarantine --describe
