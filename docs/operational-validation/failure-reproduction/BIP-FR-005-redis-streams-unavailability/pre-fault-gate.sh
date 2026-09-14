#!/usr/bin/env bash

set -euo pipefail

run_id="${1:-}"
if ! printf '%s\n' "$run_id" | grep -Eq '^BIP-FR-005-MR-[0-9]{8}T[0-9]{6}Z$'; then
  echo "usage: $0 <BIP-FR-005-MR-YYYYMMDDThhmmssZ>" >&2
  exit 2
fi

bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
topics="barcode-events barcode-events-dlt barcode-events-quarantine"

fail() {
  printf 'run_id=%s\nfailed_predicate=%s\nPRE_FAULT_GATE=FAIL\n' "$run_id" "$1" >&2
  exit 1
}

for command_name in docker awk grep; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required_command_missing:$command_name"
done

for broker in bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3; do
  inspection="$(docker inspect --format \
    '{{.State.Status}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$broker" 2>/dev/null)" || fail "required_broker_inspection_failed:$broker"
  IFS='|' read -r state oom_killed exit_code restart_count health <<< "$inspection"

  printf 'broker=%s state=%s oom_killed=%s exit_code=%s restart_count=%s health=%s\n' \
    "$broker" "$state" "$oom_killed" "$exit_code" "$restart_count" "$health"

  test "$oom_killed" = false || fail "required_broker_oom:$broker"
  test "$state" = running || fail "required_broker_not_running:$broker:$state"
  test "$exit_code" -eq 0 || fail "required_broker_exit_code:$broker:$exit_code"
  test "$restart_count" -eq 0 || fail "required_broker_restarted:$broker:$restart_count"
  test "$health" = healthy || fail "required_broker_not_healthy:$broker:$health"
done

for topic in $topics; do
  description="$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server "$bootstrap" --describe --topic "$topic" 2>/dev/null)" \
    || fail "kafka_topic_describe_failed:$topic"

  printf '%s\n' "$description" | grep -Eq 'PartitionCount:[[:space:]]*3.*ReplicationFactor:[[:space:]]*3' \
    || fail "kafka_topic_shape_mismatch:$topic"
  test "$(printf '%s\n' "$description" | grep -c 'Partition:')" -eq 3 \
    || fail "kafka_partition_count_mismatch:$topic"

  if printf '%s\n' "$description" | awk '
    /Partition:/ {
      replicas=""; isr=""
      for (i = 1; i <= NF; i++) {
        if ($i == "Replicas:") replicas=$(i+1)
        if ($i == "Isr:") isr=$(i+1)
      }
      replica_count=split(replicas, replica, ",")
      isr_count=split(isr, member, ",")
      if (replica_count != 3 || isr_count != 3) bad=1
    }
    END { exit bad ? 0 : 1 }
  '; then
    fail "kafka_required_isr_mismatch:$topic"
  fi

  urp="$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server "$bootstrap" --describe --under-replicated-partitions \
    --topic "$topic" 2>/dev/null)" || fail "kafka_urp_query_failed:$topic"
  test -z "$urp" || fail "kafka_under_replicated_partitions:$topic"

  unavailable="$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server "$bootstrap" --describe --unavailable-partitions \
    --topic "$topic" 2>/dev/null)" || fail "kafka_unavailable_query_failed:$topic"
  test -z "$unavailable" || fail "kafka_unavailable_partitions:$topic"

  printf 'topic=%s partitions=3 replication_factor=3 full_isr=true urp=0 unavailable=0\n' "$topic"
done

printf 'checked_at_utc=%s\nrun_id=%s\nPRE_FAULT_GATE=PASS\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id"
