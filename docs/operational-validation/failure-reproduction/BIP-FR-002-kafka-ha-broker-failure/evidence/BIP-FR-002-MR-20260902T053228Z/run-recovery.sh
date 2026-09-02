#!/usr/bin/env bash

set -euo pipefail

repo_root="/Users/sooinlee/Documents/CodexProjects/barcode-ingest-pipeline"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure"
evidence_dir="$scenario_dir/evidence/BIP-FR-002-MR-20260902T053228Z"
compose_file="$scenario_dir/docker-compose.validation.yml"
env_file="$repo_root/.env"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
scanner_url="http://127.0.0.1:18084/scan/barcode"
target_service="$(awk -F= '$1 == "authorized_target_service" {print $2; exit}' "$evidence_dir/08-failure-injection.txt")"
target_container="bip-fr-002-$target_service"
compose=(docker compose --env-file "$env_file" -f "$compose_file")

container_state() {
  docker inspect --format \
    'id={{.Id}} pid={{.State.Pid}} status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restart_count={{.RestartCount}}' \
    "$target_container"
}

container_mounts() {
  docker inspect --format '{{range .Mounts}}{{.Type}} source={{.Name}} destination={{.Destination}} rw={{.RW}}{{println}}{{end}}' \
    "$target_container"
}

topic_describe() {
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" \
    --describe --topic barcode-events
}

cd "$repo_root"

{
  printf 'target_service=%s\n' "$target_service"
  printf 'before_restart_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'container_before_restart=%s\n' "$(container_state)"
  printf '[mounts_before_restart]\n'
  container_mounts
  printf 'restart_command=docker compose --env-file .env -f %s start %s\n' \
    "docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml" "$target_service"
  printf 'restart_requested_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$evidence_dir/09-broker-restart.txt"

"${compose[@]}" start "$target_service" >>"$evidence_dir/09-broker-restart.txt" 2>&1
{
  printf 'restart_command_completed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'container_after_start=%s\n' "$(container_state)"
  printf '[mounts_after_start]\n'
  container_mounts
} >>"$evidence_dir/09-broker-restart.txt"

: >"$evidence_dir/10-replica-catch-up-timeline.txt"
recovered_samples=0
sample=1
while [ "$sample" -le 40 ]; do
  observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  topic="$(topic_describe)"
  partition_count="$(printf '%s\n' "$topic" | grep -c 'Partition: [0-9]')"
  full_isr_count="$(printf '%s\n' "$topic" | awk '/Partition: [0-9]/ {match($0, /Isr: [0-9,]+/); isr=substr($0, RSTART+5, RLENGTH-5); n=split(isr,a,","); if (n == 3) count++} END {print count+0}')"
  urp="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions 2>&1)"
  unavailable="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions 2>&1)"
  state="$(container_state)"
  {
    printf 'sample=%s observed_at_utc=%s recovered_samples=%s container=%s\n' "$sample" "$observed_at" "$recovered_samples" "$state"
    printf '%s\n' "$topic"
    printf '[under_replicated]\n%s\n' "$urp"
    printf '[unavailable]\n%s\n' "$unavailable"
  } >>"$evidence_dir/10-replica-catch-up-timeline.txt"

  if [ "$partition_count" -eq 3 ] && [ "$full_isr_count" -eq 3 ] \
    && ! printf '%s\n' "$urp" | grep -q 'Partition:' \
    && ! printf '%s\n' "$unavailable" | grep -q 'Partition:'; then
    recovered_samples=$((recovered_samples + 1))
  else
    recovered_samples=0
  fi

  if [ "$recovered_samples" -ge 2 ]; then
    printf 'recovery_complete_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >>"$evidence_dir/10-replica-catch-up-timeline.txt"
    break
  fi

  sample=$((sample + 1))
  sleep 2
done

if [ "$recovered_samples" -lt 2 ]; then
  echo "ISR/URP/unavailable did not converge in the allowed recovery window" >&2
  exit 6
fi

post_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
post_base_scan_time_ms="$(($(date -u +%s) * 1000))"
printf 'post_recovery_started_at_utc=%s\n' "$post_started_at" >"$evidence_dir/11-post-recovery-traffic.txt"
sequence=0
while [ "$sequence" -lt 5 ]; do
  scan_time_ms="$((post_base_scan_time_ms + sequence))"
  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  result="$(curl --silent --show-error --output /dev/null --write-out '%{http_code} %{time_total}' \
    --connect-timeout 2 --max-time 10 --header 'Content-Type: application/json' \
    --data "{\"scanTime\":$scan_time_ms}" "$scanner_url" 2>&1)"
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
  printf '%s\t%s\tpost-recovery\t%s\t%s\t%s\t%s\n' \
    "$requested_at" "$completed_at" "$sequence" "$scan_time_ms" "$http_code" "$time_total" \
    | tee -a "$evidence_dir/03-generated-manifest.tsv" "$evidence_dir/11-post-recovery-traffic.txt"
  sequence=$((sequence + 1))
  sleep 1
done
printf 'post_recovery_completed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$evidence_dir/11-post-recovery-traffic.txt"
sleep 5

"${compose[@]}" logs --no-color --since "$post_started_at" ingest processing scanner worker-1 worker-2 \
  >"$evidence_dir/12-post-recovery-application-logs.txt" 2>&1

printf 'target_service=%s\nrecovered_samples=%s\npost_recovery_events=5\n' "$target_service" "$recovered_samples"
