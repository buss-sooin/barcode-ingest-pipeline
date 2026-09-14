#!/usr/bin/env bash

set -euo pipefail

phase="${1:-}"
if ! printf '%s\n' "$phase" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  echo "usage: $0 <phase-label>" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml"
compose=(docker compose --env-file "$repo_root/.env" -f "$base_compose" -f "$release_compose")
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
run_id="BIP-FR-005-MR-20260911T112314Z"

printf 'captured_at_utc=%s\nphase=%s\nrun_id=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$run_id"
docker inspect bip-fr-002-processing --format \
  'processing_container={{.Id}} processing_image={{.Image}} state={{.State.Status}} restart_count={{.RestartCount}}'

for topic in barcode-events barcode-events-dlt barcode-events-quarantine; do
  printf 'kafka_topic=%s\n' "$topic"
  "${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic "$topic"
done

for group in barcode-processing-group barcode-events-dlt-disposition; do
  printf 'kafka_group=%s\n' "$group"
  "${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" \
    --describe --group "$group" || true
done

printf 'redis_stream_info=' 
"${compose[@]}" exec -T redis redis-cli --json XINFO STREAM barcode:stream
printf 'redis_group_info=' 
"${compose[@]}" exec -T redis redis-cli --json XINFO GROUPS barcode:stream
printf 'redis_pending=' 
"${compose[@]}" exec -T redis redis-cli --json XPENDING barcode:stream barcode-persistence-group
printf 'redis_run_records=' 
"${compose[@]}" exec -T redis redis-cli --json XRANGE barcode:stream - + COUNT 10000 \
  | jq --arg run_id "$run_id" '[.[] | select(tostring | contains($run_id))]'

"${compose[@]}" exec -T -e BIP_RUN_ID="$run_id" mysql sh -lc '
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" --batch --raw \
    --execute="SELECT internal_barcode_id, original_barcode, device_id, scan_time, processed_time, saved_time FROM barcodes WHERE original_barcode LIKE CONCAT(\"${BIP_RUN_ID}\", \"-%\") ORDER BY original_barcode"'
