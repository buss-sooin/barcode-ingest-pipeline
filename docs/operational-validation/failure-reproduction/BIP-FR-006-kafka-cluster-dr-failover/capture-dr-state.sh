#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 EVIDENCE_DIR LABEL" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
compose_file="$script_dir/docker-compose.validation.yml"
env_file="${BIP_FR_006_ENV_FILE:-$repo_root/.env}"
evidence_dir="$1"
label="$2"
snapshot_dir="$evidence_dir/$label"
a_bootstrap="broker-a-1:29092,broker-a-2:29092,broker-a-3:29092"
b_bootstrap="broker-b:39092"
compose=(docker compose --env-file "$env_file" -f "$compose_file")

mkdir -p "$snapshot_dir"

capture() {
  local name="$1"
  shift
  (
    printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'command='
    printf '%q ' "$@"
    printf '\n\n'
    "$@"
    status=$?
    printf '\nexit_code=%s\n' "$status"
    exit 0
  ) >"$snapshot_dir/$name" 2>&1
}

capture 00-compose-ps.txt "${compose[@]}" --profile failover ps --all
capture 01-container-stats.txt docker stats --no-stream
capture 02-a-quorum.txt "${compose[@]}" exec -T controller-a \
  kafka-metadata-quorum --bootstrap-controller controller-a:29093 describe --status
capture 03-a-topics.txt "${compose[@]}" exec -T broker-a-1 \
  kafka-topics --bootstrap-server "$a_bootstrap" --describe
capture 04-a-urp.txt "${compose[@]}" exec -T broker-a-1 \
  kafka-topics --bootstrap-server "$a_bootstrap" --describe --under-replicated-partitions
capture 05-a-unavailable.txt "${compose[@]}" exec -T broker-a-1 \
  kafka-topics --bootstrap-server "$a_bootstrap" --describe --unavailable-partitions
capture 06-a-offsets.txt "${compose[@]}" exec -T broker-a-1 \
  kafka-get-offsets --bootstrap-server "$a_bootstrap" --topic barcode-events
capture 07-a-group.txt "${compose[@]}" exec -T broker-a-1 \
  kafka-consumer-groups --bootstrap-server "$a_bootstrap" --describe --group barcode-processing-group

capture 10-b-quorum.txt "${compose[@]}" exec -T broker-b \
  kafka-metadata-quorum --bootstrap-controller broker-b:39093 describe --status
capture 11-b-topics.txt "${compose[@]}" exec -T broker-b \
  kafka-topics --bootstrap-server "$b_bootstrap" --describe
capture 12-b-offsets.txt "${compose[@]}" exec -T broker-b \
  kafka-get-offsets --bootstrap-server "$b_bootstrap" --topic barcode-events
capture 13-b-group.txt "${compose[@]}" exec -T broker-b \
  kafka-consumer-groups --bootstrap-server "$b_bootstrap" --describe --group barcode-processing-group
capture 14-b-group-members.txt "${compose[@]}" exec -T broker-b \
  kafka-consumer-groups --bootstrap-server "$b_bootstrap" --describe --group barcode-processing-group --members --verbose
capture 15-b-topic-list.txt "${compose[@]}" exec -T broker-b \
  kafka-topics --bootstrap-server "$b_bootstrap" --list
capture 16-b-events.txt "${compose[@]}" exec -T broker-b \
  kafka-console-consumer --bootstrap-server "$b_bootstrap" --topic barcode-events \
  --from-beginning --timeout-ms 3000 --property print.partition=true --property print.offset=true \
  --property print.key=true --property key.separator=:
capture 17-b-dlt.txt "${compose[@]}" exec -T broker-b \
  kafka-console-consumer --bootstrap-server "$b_bootstrap" --topic barcode-events-dlt \
  --from-beginning --timeout-ms 3000 --property print.partition=true --property print.offset=true
capture 18-mm2-topics.txt "${compose[@]}" exec -T broker-b \
  kafka-topics --bootstrap-server "$b_bootstrap" --list
capture 19-mm2-checkpoints.txt "${compose[@]}" exec -T broker-b \
  kafka-console-consumer --bootstrap-server "$b_bootstrap" --topic A.checkpoints.internal \
  --from-beginning --timeout-ms 3000 --formatter org.apache.kafka.connect.mirror.CheckpointFormatter
capture 20-mm2-offset-syncs.txt "${compose[@]}" exec -T broker-b \
  kafka-console-consumer --bootstrap-server "$b_bootstrap" --topic mm2-offset-syncs.A.internal \
  --from-beginning --timeout-ms 3000 --formatter org.apache.kafka.connect.mirror.OffsetSyncFormatter
capture 21-mm2-rest-root.txt curl --silent --show-error --max-time 5 http://127.0.0.1:18083/
capture 22-mm2-connectors.txt curl --silent --show-error --max-time 5 http://127.0.0.1:18083/connectors
capture 23-mm2-logs.txt "${compose[@]}" logs --no-color --since 30m --tail 3000 mm2
capture 24-mm2-process.txt docker exec bip-fr-006-mm2 sh -lc \
  'ps -ef; grep -E "^(clusters|A->B|B->A|replication.policy|.*replication.factor|listeners)" /etc/kafka/mm2.properties'

capture 30-http-health.txt sh -c \
  'for u in http://127.0.0.1:28081/actuator/health http://127.0.0.1:28082/actuator/health http://127.0.0.1:28091/actuator/health http://127.0.0.1:28092/actuator/health http://127.0.0.1:28085/actuator/health; do printf "%s " "$u"; curl -sS --max-time 3 -w " http=%{http_code} time=%{time_total}\n" "$u" || true; done'
capture 31-redis.txt "${compose[@]}" exec -T redis sh -lc \
  'redis-cli PING; redis-cli XLEN barcode:stream; redis-cli XINFO GROUPS barcode:stream 2>&1 || true; redis-cli XPENDING barcode:stream barcode-persistence-group 2>&1 || true; redis-cli XLEN barcode:stream:dlq; redis-cli --scan --pattern "barcode:processed:BIP-FR-006-*"'
capture 32-mysql.txt "${compose[@]}" exec -T mysql sh -lc \
  'mysql -N -B -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" -e "SELECT original_barcode, internal_barcode_id, scan_time, processed_time, saved_time FROM barcodes WHERE LEFT(original_barcode,10)=0x4249502D46522D303036 ORDER BY original_barcode;"'
capture 33-app-logs.txt "${compose[@]}" --profile failover logs --no-color --since 30m --tail 5000 \
  ingest-a ingest-b processing-a processing-b worker

printf 'snapshot_dir=%s\n' "$snapshot_dir"
