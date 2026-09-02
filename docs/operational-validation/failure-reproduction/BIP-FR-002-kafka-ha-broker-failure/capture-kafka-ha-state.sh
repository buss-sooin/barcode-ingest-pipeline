#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
compose_file="$script_dir/docker-compose.validation.yml"
env_file="${BIP_FR_002_ENV_FILE:-$repo_root/.env}"
captured_at="$(date -u +%Y%m%dT%H%M%SZ)"
evidence_dir="${1:-$script_dir/evidence/${captured_at}-kafka-ha-state}"
log_since="${LOG_SINCE:-15m}"
log_tail="${LOG_TAIL:-2000}"
bootstrap_servers="broker-1:29092,broker-2:29092,broker-3:29092"
failures=0

if [ ! -f "$env_file" ]; then
  echo "Required Compose env file not found: $env_file" >&2
  exit 2
fi

mkdir -p "$evidence_dir"
compose=(docker compose --env-file "$env_file" -f "$compose_file")

capture() {
  output_name="$1"
  shift

  (
    printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'command='
    printf '%q ' "$@"
    printf '\n\n'
    "$@"
    exit_code=$?
    printf '\nexit_code=%s\n' "$exit_code"
    exit "$exit_code"
  ) >"$evidence_dir/$output_name" 2>&1
  capture_status=$?

  if [ "$capture_status" -ne 0 ]; then
    failures=$((failures + 1))
    printf 'WARN: %s failed with exit code %s\n' "$output_name" "$capture_status" >&2
  fi
}

# 이 helper의 모든 Kafka 명령은 describe/list 계열이다. topic, offset, replica,
# application state를 생성·변경·삭제하거나 장애를 주입하지 않는다.
capture 00-compose-ps.txt "${compose[@]}" ps --all
capture 01-controller-quorum-status.txt \
  "${compose[@]}" exec -T controller \
  kafka-metadata-quorum --bootstrap-controller controller:29093 describe --status
capture 02-controller-quorum-replication.txt \
  "${compose[@]}" exec -T controller \
  kafka-metadata-quorum --bootstrap-controller controller:29093 describe --replication
capture 03-reachable-brokers.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-broker-api-versions --bootstrap-server "$bootstrap_servers"
capture 04-registered-broker-log-dirs.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-log-dirs --bootstrap-server "$bootstrap_servers" --describe --broker-list 1,2,3
capture 05-barcode-events-topic.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-topics --bootstrap-server "$bootstrap_servers" --describe --topic barcode-events
capture 06-barcode-events-config.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-configs --bootstrap-server "$bootstrap_servers" \
  --describe --entity-type topics --entity-name barcode-events
capture 07-under-replicated-partitions.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-topics --bootstrap-server "$bootstrap_servers" \
  --describe --under-replicated-partitions
capture 08-unavailable-partitions.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-topics --bootstrap-server "$bootstrap_servers" \
  --describe --unavailable-partitions
capture 09-processing-consumer-group.txt \
  "${compose[@]}" exec -T broker-1 \
  kafka-consumer-groups --bootstrap-server "$bootstrap_servers" \
  --describe --group barcode-processing-group
capture 10-controller-and-broker-logs.txt \
  "${compose[@]}" logs --no-color --since "$log_since" --tail "$log_tail" \
  controller broker-1 broker-2 broker-3 topic-init
capture 11-producer-and-processing-logs.txt \
  "${compose[@]}" logs --no-color --since "$log_since" --tail "$log_tail" \
  ingest processing
capture 12-downstream-application-logs.txt \
  "${compose[@]}" logs --no-color --since "$log_since" --tail "$log_tail" \
  scanner worker-1 worker-2

printf 'evidence_dir=%s\nfailures=%s\n' "$evidence_dir" "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
