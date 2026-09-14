#!/usr/bin/env bash

set -euo pipefail

topic="${1:-}"
partition="${2:-}"
offset="${3:-}"
count="${4:-}"

case "$topic" in
  barcode-events|barcode-events-dlt|barcode-events-quarantine) ;;
  *) echo "unsupported topic: $topic" >&2; exit 2 ;;
esac
for numeric_value in "$partition" "$offset" "$count"; do
  printf '%s\n' "$numeric_value" | grep -Eq '^[0-9]+$'
done
test "$count" -ge 1
test "$count" -le 10000

repo_root="$(git rev-parse --show-toplevel)"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml"
compose=(docker compose --env-file "$repo_root/.env" -f "$base_compose" -f "$release_compose")

"${compose[@]}" exec -T broker-1 kafka-console-consumer \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --topic "$topic" --partition "$partition" --offset "$offset" --max-messages "$count" \
  --timeout-ms 10000 \
  --property print.timestamp=true \
  --property print.partition=true \
  --property print.offset=true \
  --property print.key=true \
  --property print.headers=true
