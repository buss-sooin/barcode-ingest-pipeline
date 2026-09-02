#!/usr/bin/env bash

set -euo pipefail

repo_root="/Users/sooinlee/Documents/CodexProjects/barcode-ingest-pipeline"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure"
evidence_dir="$scenario_dir/evidence/BIP-FR-002-MR-20260902T053228Z"
compose_file="$scenario_dir/docker-compose.validation.yml"
env_file="$repo_root/.env"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
scanner_url="http://127.0.0.1:18084/scan/barcode"
scanner_identity="SEOUL-CENTER-PC-001"
request_count=60
kill_before_sequence=10
interval_seconds=1

compose=(docker compose --env-file "$env_file" -f "$compose_file")
mkdir -p "$evidence_dir/down"

topic_describe() {
  "${compose[@]}" exec -T broker-1 \
    kafka-topics --bootstrap-server "$bootstrap" --describe --topic barcode-events
}

topic_offsets() {
  "${compose[@]}" exec -T broker-1 \
    kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events
}

target_end_offset() {
  topic_offsets | awk -F: -v partition="$1" '$2 == partition { print $3 }'
}

container_state() {
  docker inspect --format \
    'id={{.Id}} pid={{.State.Pid}} status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restart_count={{.RestartCount}}' \
    "$1"
}

append_request() {
  local phase="$1"
  local sequence="$2"
  local scan_time_ms="$3"
  local requested_at completed_at result curl_status http_code time_total

  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  result="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code} %{time_total}' \
    --connect-timeout 2 --max-time 10 \
    --header 'Content-Type: application/json' \
    --data "{\"scanTime\":$scan_time_ms}" \
    "$scanner_url" 2>&1)"
  curl_status=$?
  set -e
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$curl_status" -eq 0 ]; then
    http_code="${result%% *}"
    time_total="${result#* }"
  else
    http_code="transport-error"
    time_total="n/a"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$requested_at" "$completed_at" "$phase" "$sequence" "$scan_time_ms" "$http_code" "$time_total" \
    | tee -a "$evidence_dir/03-generated-manifest.tsv" "$evidence_dir/07-active-traffic-session.tsv"
}

cd "$repo_root"

# The mapping probe is both the healthy end-to-end probe and the runtime-derived
# scanner -> partition observation. No broker target is supplied to this script.
mapping_scan_time_ms="$(($(date -u +%s) * 1000))"
mapping_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'requested_at_utc\tcompleted_at_utc\tphase\tsequence\tscan_time_ms\thttp_status\ttime_total_seconds\n' \
  >"$evidence_dir/03-generated-manifest.tsv"
printf 'requested_at_utc\tcompleted_at_utc\tphase\tsequence\tscan_time_ms\thttp_status\ttime_total_seconds\n' \
  >"$evidence_dir/07-active-traffic-session.tsv"
append_request mapping-pre-failure 0 "$mapping_scan_time_ms"
sleep 4

"${compose[@]}" logs --no-color --since "$mapping_started_at" ingest processing scanner worker-1 worker-2 \
  >"$evidence_dir/04-runtime-mapping-and-healthy-flow-logs.txt" 2>&1
producer_ack="$(grep "Sent barcode event - Key: $scanner_identity" "$evidence_dir/04-runtime-mapping-and-healthy-flow-logs.txt" | tail -n 1)"
if [ -z "$producer_ack" ]; then
  echo "No producer acknowledgment found for runtime mapping probe" >&2
  exit 3
fi

target_partition="$(printf '%s\n' "$producer_ack" | sed -E 's/.*Partition: ([0-9]+), Offset:.*/\1/')"
topic_before="$(topic_describe)"
target_line="$(printf '%s\n' "$topic_before" | awk -v partition="$target_partition" '$0 ~ "Partition: " partition "([[:space:]]|$)" { print; exit }')"
target_leader="$(printf '%s\n' "$target_line" | sed -E 's/.*Leader: ([0-9]+).*/\1/')"
target_service="broker-$target_leader"
target_container="bip-fr-002-$target_service"
target_isr="$(printf '%s\n' "$target_line" | sed -E 's/.*Isr: ([0-9,]+).*/\1/')"
target_isr_size="$(printf '%s' "$target_isr" | awk -F, '{print NF}')"

if [ "$target_isr_size" -ne 3 ]; then
  echo "Target partition ISR is not 3: $target_line" >&2
  exit 4
fi

baseline_target_offset="$(target_end_offset "$target_partition")"
{
  printf 'observed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'scanner_identity=%s\n' "$scanner_identity"
  printf 'mapping_scan_time_ms=%s\n' "$mapping_scan_time_ms"
  printf 'producer_ack_evidence=%s\n' "$producer_ack"
  printf 'target_partition=%s\n' "$target_partition"
  printf 'target_leader_broker_id=%s\n' "$target_leader"
  printf 'authorized_target_service=%s\n' "$target_service"
  printf 'target_partition_metadata=%s\n' "$target_line"
  printf 'target_isr_size=%s\n' "$target_isr_size"
  printf 'baseline_target_end_offset=%s\n' "$baseline_target_offset"
  printf 'target_container_state_before_traffic=%s\n' "$(container_state "$target_container")"
  printf '[topic_immediately_before_traffic]\n%s\n' "$topic_before"
} >"$evidence_dir/06-runtime-target-mapping.txt"

base_scan_time_ms="$((mapping_scan_time_ms + 100))"
traffic_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'traffic_started_at_utc=%s\nrequest_count=%s\nkill_before_sequence=%s\nbase_scan_time_ms=%s\n' \
  "$traffic_started_at" "$request_count" "$kill_before_sequence" "$base_scan_time_ms" \
  >"$evidence_dir/07-active-traffic-boundaries.txt"

sequence=0
while [ "$sequence" -lt "$request_count" ]; do
  if [ "$sequence" -eq "$kill_before_sequence" ]; then
    failure_decision_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    live_topic="$(topic_describe)"
    live_target_line="$(printf '%s\n' "$live_topic" | awk -v partition="$target_partition" '$0 ~ "Partition: " partition "([[:space:]]|$)" { print; exit }')"
    live_leader="$(printf '%s\n' "$live_target_line" | sed -E 's/.*Leader: ([0-9]+).*/\1/')"
    live_isr="$(printf '%s\n' "$live_target_line" | sed -E 's/.*Isr: ([0-9,]+).*/\1/')"
    live_isr_size="$(printf '%s' "$live_isr" | awk -F, '{print NF}')"
    pre_kill_target_offset="$(target_end_offset "$target_partition")"
    progressed_before_kill="$((pre_kill_target_offset - baseline_target_offset))"

    if [ "$live_leader" != "$target_leader" ] || [ "$live_isr_size" -ne 3 ] || [ "$progressed_before_kill" -lt 3 ]; then
      echo "Runtime target changed or insufficient pre-kill progression; refusing SIGKILL" >&2
      echo "$live_target_line" >&2
      echo "progressed_before_kill=$progressed_before_kill" >&2
      exit 5
    fi

    {
      printf 'failure_decision_at_utc=%s\n' "$failure_decision_at"
      printf 'scanner_identity=%s\n' "$scanner_identity"
      printf 'target_partition=%s\n' "$target_partition"
      printf 'runtime_revalidated_leader=%s\n' "$live_leader"
      printf 'authorized_target_service=%s\n' "$target_service"
      printf 'live_target_metadata=%s\n' "$live_target_line"
      printf 'baseline_target_end_offset=%s\n' "$baseline_target_offset"
      printf 'pre_kill_target_end_offset=%s\n' "$pre_kill_target_offset"
      printf 'multiple_run_scoped_offsets_progressed_before_kill=%s\n' "$progressed_before_kill"
      printf 'container_before_sigkill=%s\n' "$(container_state "$target_container")"
      printf 'exact_failure_command=docker compose --env-file .env -f %s kill -s SIGKILL %s\n' \
        "docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml" "$target_service"
      printf 'sigkill_issued_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$evidence_dir/08-failure-injection.txt"

    "${compose[@]}" kill -s SIGKILL "$target_service" \
      >>"$evidence_dir/08-failure-injection.txt" 2>&1
    {
      printf 'sigkill_completed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'container_after_sigkill=%s\n' "$(container_state "$target_container")"
    } >>"$evidence_dir/08-failure-injection.txt"
  fi

  scan_time_ms="$((base_scan_time_ms + sequence))"
  append_request active-material "$sequence" "$scan_time_ms"

  if [ "$sequence" -eq 25 ]; then
    {
      printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'traffic_sequence_completed=%s\n' "$sequence"
      printf 'failed_broker_state=%s\n' "$(container_state "$target_container")"
      printf '[topic_during_active_traffic]\n'
      topic_describe
      printf '[offsets_during_active_traffic]\n'
      topic_offsets
    } >"$evidence_dir/down/00-active-traffic-degraded-snapshot.txt"
  fi

  sequence=$((sequence + 1))
  sleep "$interval_seconds"
done

traffic_completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf 'traffic_completed_at_utc=%s\n' "$traffic_completed_at"
  printf 'failed_broker_state_at_traffic_end=%s\n' "$(container_state "$target_container")"
} >>"$evidence_dir/07-active-traffic-boundaries.txt"

"${compose[@]}" logs --no-color --since "$traffic_started_at" ingest processing scanner worker-1 worker-2 \
  >"$evidence_dir/down/01-material-window-application-logs.txt" 2>&1

{
  printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'failed_broker_state=%s\n' "$(container_state "$target_container")"
  printf '[topic_after_active_traffic]\n'
  topic_describe
  printf '[offsets_after_active_traffic]\n'
  topic_offsets
  printf '[consumer_group_after_active_traffic]\n'
  "${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" \
    --describe --group barcode-processing-group
  printf '[under_replicated_after_active_traffic]\n'
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" \
    --describe --under-replicated-partitions
  printf '[unavailable_after_active_traffic]\n'
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" \
    --describe --unavailable-partitions
  printf '[redis_after_active_traffic]\n'
  "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream
  "${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream
  "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq
} >"$evidence_dir/down/02-degraded-terminal-state.txt" 2>&1

printf 'target_partition=%s\ntarget_leader=%s\ntarget_service=%s\ntraffic_started_at_utc=%s\ntraffic_completed_at_utc=%s\n' \
  "$target_partition" "$target_leader" "$target_service" "$traffic_started_at" "$traffic_completed_at"
