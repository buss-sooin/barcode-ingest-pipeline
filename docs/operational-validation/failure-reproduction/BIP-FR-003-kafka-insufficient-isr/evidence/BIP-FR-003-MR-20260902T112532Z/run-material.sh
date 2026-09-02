#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-003-kafka-insufficient-isr"
topology_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure"
compose_file="$topology_dir/docker-compose.validation.yml"
env_file="$repo_root/.env"
run_id="${1:-}"
contract_id="BIP-FR-003-RC"
contract_revision="BIP-FR-003-RC-R1"
expected_branch="validation/bip-fr-003-kafka-insufficient-isr"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
scanner_url="http://127.0.0.1:18084/scan/barcode"
ingest_url="http://127.0.0.1:18081/ingest/barcode"
scanner_identity="SEOUL-CENTER-PC-001"
active_request_count=50
active_interval_seconds=1

if ! printf '%s\n' "$run_id" | grep -Eq '^BIP-FR-003-MR-[0-9]{8}T[0-9]{6}Z$'; then
  echo "Usage: $0 BIP-FR-003-MR-<UTC>" >&2
  exit 2
fi

if [ ! -f "$env_file" ]; then
  echo "Required Compose env file not found: $env_file" >&2
  exit 2
fi

initial_branch="$(git branch --show-current)"
initial_head="$(git rev-parse HEAD)"
initial_status="$(git status --short --branch)"
initial_origin="$(git remote get-url origin)"
test "$initial_branch" = "$expected_branch"
test -z "$(git status --porcelain)"
test "$initial_origin" = 'git@github.com:buss-sooin/barcode-ingest-pipeline.git'

evidence_dir="$scenario_dir/evidence/$run_id"
if [ -e "$evidence_dir" ]; then
  echo "Evidence directory already exists: $evidence_dir" >&2
  exit 2
fi

compose=(docker compose --env-file "$env_file" -f "$compose_file")
mkdir -p "$evidence_dir/before" "$evidence_dir/timeline" "$evidence_dir/final"
cp "$0" "$evidence_dir/run-material.sh"

first_killed=0
second_killed=0
traffic_pid=""
L0=""
L1=""
F1=""
P=""
run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

container_name() {
  printf 'bip-fr-002-broker-%s' "$1"
}

container_state() {
  docker inspect --format \
    'id={{.Id}} pid={{.State.Pid}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restart_count={{.RestartCount}}' \
    "$1"
}

container_mounts() {
  docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/kafka/data"}}type={{.Type}} source={{.Name}} destination={{.Destination}} rw={{.RW}}{{end}}{{end}}' "$1"
}

topic_describe() {
  local service="$1"
  "${compose[@]}" exec -T "$service" kafka-topics --bootstrap-server "$bootstrap" \
    --describe --topic barcode-events
}

topic_config() {
  local service="$1"
  "${compose[@]}" exec -T "$service" kafka-configs --bootstrap-server "$bootstrap" \
    --describe --entity-type topics --entity-name barcode-events
}

topic_offsets() {
  local service="$1"
  "${compose[@]}" exec -T "$service" kafka-get-offsets --bootstrap-server "$bootstrap" \
    --topic barcode-events
}

target_line_from() {
  local description="$1"
  printf '%s\n' "$description" | awk -v partition="$P" \
    '$0 ~ "Partition: " partition "([[:space:]]|$)" { print; exit }'
}

line_leader() {
  printf '%s\n' "$1" | sed -E 's/.*Leader: ([0-9]+).*/\1/'
}

line_isr() {
  printf '%s\n' "$1" | sed -E 's/.*Isr: ([0-9,]+).*/\1/'
}

isr_size() {
  printf '%s' "$1" | awk -F, '{print NF}'
}

isr_contains() {
  printf ',%s,' "$1" | grep -q ",$2,"
}

target_offset() {
  local service="$1"
  topic_offsets "$service" | awk -F: -v partition="$P" '$2 == partition { print $3 }'
}

make_barcode() {
  local seed="$1"
  local body check
  body="$(printf '991%09d' "$((seed % 1000000000))")"
  check="$(printf '%s\n' "$body" | awk '{sum=0; for(i=1;i<=12;i++){d=substr($0,i,1)+0; sum += (i%2==0 ? 3*d : d)} print (10-(sum%10))%10}')"
  printf '%s%s' "$body" "$check"
}

append_manifest() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    >>"$evidence_dir/03-generated-manifest.tsv"
}

direct_request() {
  local phase="$1"
  local sequence="$2"
  local scan_time="$3"
  local barcode="$4"
  local output_file="$5"
  local requested_at completed_at result curl_status http_code time_total

  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  result="$(curl --silent --show-error --retry 0 \
    --output "$output_file.body" --write-out '%{http_code} %{time_total}' \
    --connect-timeout 2 --max-time 10 --header 'Content-Type: application/json' \
    --data "{\"barcode\":\"$barcode\",\"scanTime\":$scan_time,\"deviceId\":\"$scanner_identity\"}" \
    "$ingest_url" 2>"$output_file.stderr")"
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

  {
    printf 'requested_at_utc=%s\n' "$requested_at"
    printf 'completed_at_utc=%s\n' "$completed_at"
    printf 'phase=%s\nsequence=%s\nscan_time_ms=%s\nbarcode=%s\ndevice_id=%s\n' \
      "$phase" "$sequence" "$scan_time" "$barcode" "$scanner_identity"
    printf 'curl_retry=0\ncurl_status=%s\nhttp_status=%s\ntime_total_seconds=%s\n' \
      "$curl_status" "$http_code" "$time_total"
    printf '[response_body]\n'
    cat "$output_file.body"
    printf '\n[response_stderr]\n'
    cat "$output_file.stderr"
  } >"$output_file"
  append_manifest "$requested_at" "$completed_at" "$phase" "$sequence" "$scan_time" \
    "$barcode" "$http_code" "$curl_status" "$time_total"
  printf '%s %s %s\n' "$http_code" "$curl_status" "$requested_at"
}

scanner_request() {
  local phase="$1"
  local sequence="$2"
  local scan_time="$3"
  local requested_at completed_at result curl_status http_code time_total

  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  result="$(curl --silent --show-error --retry 0 --output /dev/null \
    --write-out '%{http_code} %{time_total}' --connect-timeout 2 --max-time 10 \
    --header 'Content-Type: application/json' --data "{\"scanTime\":$scan_time}" \
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
  append_manifest "$requested_at" "$completed_at" "$phase" "$sequence" "$scan_time" \
    "scanner-generated" "$http_code" "$curl_status" "$time_total"
}

capture_state() {
  local name="$1"
  local service="$2"
  local destination="$evidence_dir/$name"
  {
    printf 'captured_at_utc=%s\nquery_service=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$service"
    printf '[compose_ps]\n'
    "${compose[@]}" ps --all
    printf '[topic]\n'
    topic_describe "$service"
    printf '[topic_config]\n'
    topic_config "$service"
    printf '[offsets]\n'
    topic_offsets "$service"
    printf '[under_replicated]\n'
    "${compose[@]}" exec -T "$service" kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions
    printf '[unavailable]\n'
    "${compose[@]}" exec -T "$service" kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions
    printf '[consumer_group]\n'
    "${compose[@]}" exec -T "$service" kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group || true
    printf '[redis]\n'
    "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream
    "${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream
    "${compose[@]}" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group
    "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq
  } >"$destination" 2>&1
}

wait_for_first_transition() {
  local service="$1"
  local output="$evidence_dir/timeline/10-first-transition-isr3-to2.txt"
  local sample description line leader isr size
  : >"$output"
  sample=1
  while [ "$sample" -le 60 ]; do
    description="$(topic_describe "$service" 2>&1 || true)"
    line="$(target_line_from "$description")"
    leader="$(line_leader "$line")"
    isr="$(line_isr "$line")"
    size="$(isr_size "$isr")"
    printf 'sample=%s observed_at_utc=%s leader=%s isr=%s isr_size=%s metadata=%s\n' \
      "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$leader" "$isr" "$size" "$line" >>"$output"
    if [ -n "$leader" ] && [ "$leader" != "$L0" ] && [ "$size" -eq 2 ] && isr_contains "$isr" "$leader"; then
      L1="$leader"
      for candidate in $(printf '%s' "$isr" | tr ',' ' '); do
        if [ "$candidate" != "$L1" ]; then F1="$candidate"; fi
      done
      return 0
    fi
    sample=$((sample + 1))
    sleep 2
  done
  return 1
}

wait_for_exact_target_state() {
  local service="$1"
  local expected_leader="$2"
  local expected_isr_size="$3"
  local output="$4"
  local sample description line leader isr size
  : >"$output"
  sample=1
  while [ "$sample" -le 60 ]; do
    description="$(topic_describe "$service" 2>&1 || true)"
    line="$(target_line_from "$description")"
    leader="$(line_leader "$line")"
    isr="$(line_isr "$line")"
    size="$(isr_size "$isr")"
    printf 'sample=%s observed_at_utc=%s leader=%s isr=%s isr_size=%s metadata=%s\n' \
      "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$leader" "$isr" "$size" "$line" >>"$output"
    if [ "$leader" = "$expected_leader" ] && [ "$size" -eq "$expected_isr_size" ]; then
      return 0
    fi
    sample=$((sample + 1))
    sleep 2
  done
  return 1
}

wait_for_full_recovery() {
  local service="$1"
  local output="$evidence_dir/timeline/17-full-recovery-isr2-to3.txt"
  local sample description partition_count full_isr urp unavailable health_count
  : >"$output"
  sample=1
  while [ "$sample" -le 90 ]; do
    description="$(topic_describe "$service" 2>&1 || true)"
    partition_count="$(printf '%s\n' "$description" | grep -c 'Partition: [0-9]' || true)"
    full_isr="$(printf '%s\n' "$description" | awk '/Partition: [0-9]/ {match($0,/Isr: [0-9,]+/); v=substr($0,RSTART+5,RLENGTH-5); n=split(v,a,","); if(n==3)c++} END{print c+0}')"
    urp="$("${compose[@]}" exec -T "$service" kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions 2>&1 || true)"
    unavailable="$("${compose[@]}" exec -T "$service" kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions 2>&1 || true)"
    health_count=0
    for broker in 1 2 3; do
      if container_state "$(container_name "$broker")" | grep -q 'status=running health=healthy'; then
        health_count=$((health_count + 1))
      fi
    done
    {
      printf 'sample=%s observed_at_utc=%s partitions=%s full_isr=%s healthy_brokers=%s\n' \
        "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$partition_count" "$full_isr" "$health_count"
      printf '%s\n[under_replicated]\n%s\n[unavailable]\n%s\n' "$description" "$urp" "$unavailable"
    } >>"$output"
    if [ "$partition_count" -eq 3 ] && [ "$full_isr" -eq 3 ] && [ "$health_count" -eq 3 ] \
      && ! printf '%s\n' "$urp" | grep -q 'Partition:' \
      && ! printf '%s\n' "$unavailable" | grep -q 'Partition:'; then
      printf 'full_recovery_confirmed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$output"
      return 0
    fi
    sample=$((sample + 1))
    sleep 2
  done
  return 1
}

safe_recovery_on_exit() {
  local status=$?
  trap - EXIT
  if [ "$second_killed" -eq 1 ] && [ -n "$F1" ]; then
    "${compose[@]}" start "broker-$F1" >>"$evidence_dir/recovery-on-exit.txt" 2>&1 || true
  fi
  if [ "$first_killed" -eq 1 ] && [ -n "$L0" ]; then
    "${compose[@]}" start "broker-$L0" >>"$evidence_dir/recovery-on-exit.txt" 2>&1 || true
  fi
  if [ -n "$traffic_pid" ] && kill -0 "$traffic_pid" 2>/dev/null; then
    wait "$traffic_pid" || true
  fi
  exit "$status"
}
trap safe_recovery_on_exit EXIT

cd "$repo_root"
printf 'requested_at_utc\tcompleted_at_utc\tphase\tsequence\tscan_time_ms\tbarcode\thttp_status\tcurl_status\ttime_total_seconds\n' \
  >"$evidence_dir/03-generated-manifest.tsv"

# 실행 전 정체성과 단일 Contract Revision 연결을 먼저 보존한다.
{
  printf 'run_id=%s\ncontract_id=%s\ncontract_revision=%s\n' "$run_id" "$contract_id" "$contract_revision"
  printf 'run_to_revision=%s -> %s\n' "$run_id" "$contract_revision"
  printf 'human_gate_reference=%s\n' 'Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation'
  printf 'run_started_at_utc=%s\nrepository=%s\nbranch=%s\nhead=%s\n' \
    "$run_started_at" "$repo_root" "$initial_branch" "$initial_head"
  printf '[git_status]\n'
  printf '%s\n' "$initial_status"
  printf '[origin]\n'
  printf '%s\n' "$initial_origin"
  printf '[topology_asset_sha256]\n'
  shasum -a 256 "$compose_file" "$topology_dir/init-kafka-topics.sh"
} >"$evidence_dir/00-run-identity-and-contract.txt"

# 컨테이너·설정·ProducerConfig를 직접 캡처하고 사전 조건을 검증한다.
{
  printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "${compose[@]}" ps --all
  printf '[controller_and_broker_identity]\n'
  for name in bip-fr-002-controller bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3; do
    printf '%s %s mounts=%s\n' "$name" "$(container_state "$name")" "$(container_mounts "$name")"
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" \
      | grep -E '^(KAFKA_NODE_ID|KAFKA_PROCESS_ROLES|KAFKA_CONTROLLER_QUORUM_VOTERS|KAFKA_MIN_INSYNC_REPLICAS|KAFKA_UNCLEAN_LEADER_ELECTION_ENABLE|KAFKA_AUTO_CREATE_TOPICS_ENABLE)='
  done
  printf '[controller_quorum]\n'
  "${compose[@]}" exec -T controller kafka-metadata-quorum --bootstrap-controller controller:29093 describe --status
  printf '[broker_runtime_kafka_config]\n'
  docker logs bip-fr-002-broker-1 2>&1 | grep -E '(^|[[:space:]])(node.id|process.roles|min.insync.replicas|unclean.leader.election.enable|auto.create.topics.enable) = ' | tail -20
  printf '[ingest_runtime_producer_config]\n'
  docker logs bip-fr-002-ingest 2>&1 | awk '/ProducerConfig values:/{capture=1; count=0} capture{print; count++} capture && count>=90{capture=0}' | tail -90
} >"$evidence_dir/before/01-effective-runtime-config.txt" 2>&1

for broker in 1 2 3; do
  container_state "$(container_name "$broker")" | grep -q 'status=running health=healthy'
done
container_state bip-fr-002-controller | grep -q 'status=running'
grep -q 'KAFKA_PROCESS_ROLES=controller' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'KAFKA_PROCESS_ROLES=broker' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'KAFKA_UNCLEAN_LEADER_ELECTION_ENABLE=false' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'unclean.leader.election.enable = false' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -Eq 'acks = (-1|all)' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'enable.idempotence = true' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'retries = 3' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'delivery.timeout.ms = 120000' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'request.timeout.ms = 30000' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'retry.backoff.ms = 100' "$evidence_dir/before/01-effective-runtime-config.txt"
grep -q 'bootstrap.servers = \[broker-1:29092, broker-2:29092, broker-3:29092\]' "$evidence_dir/before/01-effective-runtime-config.txt"

healthy_topic="$(topic_describe broker-1)"
healthy_config="$(topic_config broker-1)"
test "$(printf '%s\n' "$healthy_topic" | grep -c 'Partition: [0-9]')" -eq 3
test "$(printf '%s\n' "$healthy_topic" | awk '/Partition: [0-9]/{match($0,/Isr: [0-9,]+/);v=substr($0,RSTART+5,RLENGTH-5);n=split(v,a,",");if(n==3)c++}END{print c+0}')" -eq 3
printf '%s\n' "$healthy_config" | grep -Eq 'min\.insync\.replicas=2([[:space:],]|$)'
test -z "$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions | grep 'Partition:' || true)"
test -z "$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions | grep 'Partition:' || true)"
initial_dlt_count="$("${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events-dlt | awk -F: '{sum+=$3}END{print sum+0}')"
initial_consumer_group="$("${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group)"
initial_total_lag="$(printf '%s\n' "$initial_consumer_group" | awk '$2=="barcode-events"{sum+=$6}END{print sum+0}')"
initial_redis_group="$("${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream)"
initial_redis_lag="$(printf '%s\n' "$initial_redis_group" | awk 'previous=="lag"{print;exit}{previous=$0}')"
test "$initial_dlt_count" -eq 0
test "$initial_total_lag" -eq 0
test "$initial_redis_lag" -eq 0
test "$("${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq | tr -d '\r')" -eq 0
test "$("${compose[@]}" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group | sed -n '1p' | tr -d '\r')" -eq 0
for url in http://127.0.0.1:18081/actuator/health http://127.0.0.1:18082/actuator/health \
  http://127.0.0.1:18084/actuator/health http://127.0.0.1:18085/actuator/health \
  http://127.0.0.1:18086/actuator/health; do
  curl --silent --show-error --fail "$url" | grep -q '"status":"UP"'
done
capture_state before/02-healthy-preconditions.txt broker-1
topic_offsets broker-1 >"$evidence_dir/before/03-pre-run-offsets.txt"

# 정상 Scanner probe로 실제 key→partition과 L0를 발견한다.
mapping_scan_time="$(( $(date -u +%s) * 1000 ))"
mapping_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
scanner_request mapping-healthy 0 "$mapping_scan_time"
sleep 5
"${compose[@]}" logs --no-color --since "$mapping_started_at" ingest processing scanner worker-1 worker-2 \
  >"$evidence_dir/before/04-mapping-healthy-flow-logs.txt" 2>&1
mapping_ack="$(grep "Sent barcode event - Key: $scanner_identity" "$evidence_dir/before/04-mapping-healthy-flow-logs.txt" | tail -1)"
test -n "$mapping_ack"
P="$(printf '%s\n' "$mapping_ack" | sed -E 's/.*Partition: ([0-9]+), Offset:.*/\1/')"
topic_now="$(topic_describe broker-1)"
target_line="$(target_line_from "$topic_now")"
L0="$(line_leader "$target_line")"
initial_isr="$(line_isr "$target_line")"
test "$(isr_size "$initial_isr")" -eq 3
baseline_target_offset="$(awk -F: -v partition="$P" '$2 == partition {print $3}' "$evidence_dir/before/03-pre-run-offsets.txt")"
mapping_mysql_count="$("${compose[@]}" exec -T mysql sh -lc 'mysql -N -B -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh \
  "SELECT COUNT(*) FROM barcodes WHERE CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED)=$mapping_scan_time" 2>/dev/null | tr -d '\r')"
test "$mapping_mysql_count" -eq 1
{
  printf 'observed_at_utc=%s\nP=%s\nL0=%s\ninitial_isr=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" "$L0" "$initial_isr"
  printf 'mapping_scan_time_ms=%s\nbaseline_target_offset=%s\nproducer_ack=%s\nmetadata=%s\n' \
    "$mapping_scan_time" "$baseline_target_offset" "$mapping_ack" "$target_line"
} >"$evidence_dir/05-runtime-role-mapping.txt"

# 첫 번째 실패: 현재 leader L0만 중단한다.
L0_container="$(container_name "$L0")"
query_after_first=""
for candidate in 1 2 3; do
  if [ "$candidate" != "$L0" ]; then query_after_first="broker-$candidate"; break; fi
done
{
  printf 'decision_at_utc=%s\nP=%s\nL0=%s\nmetadata=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" "$L0" "$target_line"
  printf 'container_before=%s\nmount_before=%s\n' "$(container_state "$L0_container")" "$(container_mounts "$L0_container")"
  printf 'command=docker compose ... kill -s SIGKILL broker-%s\nissued_at_utc=%s\n' "$L0" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$evidence_dir/06-first-failure-L0.txt"
"${compose[@]}" kill -s SIGKILL "broker-$L0" >>"$evidence_dir/06-first-failure-L0.txt" 2>&1
first_killed=1
printf 'completed_at_utc=%s\ncontainer_after=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(container_state "$L0_container")" \
  >>"$evidence_dir/06-first-failure-L0.txt"
wait_for_first_transition "$query_after_first"
test -n "$L1"
test -n "$F1"
test "$L1" != "$L0"
test "$F1" != "$L1"
test "$F1" != "$L0"

# ISR=2가 실제로 쓰기 가능한지 단건 application witness로 확인한다.
isr2_scan_time="$(( $(date -u +%s) * 1000 + 101 ))"
isr2_barcode="$(make_barcode "$isr2_scan_time")"
isr2_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
isr2_result="$(direct_request isr2-degraded-witness 1 "$isr2_scan_time" "$isr2_barcode" "$evidence_dir/07-isr2-write-witness.txt")"
test "${isr2_result%% *}" = 200
sleep 3
"${compose[@]}" logs --no-color --since "$isr2_started_at" ingest processing worker-1 worker-2 \
  >"$evidence_dir/08-isr2-write-application-logs.txt" 2>&1
grep "Sent barcode event .*Barcode: $isr2_barcode, Partition: $P" "$evidence_dir/08-isr2-write-application-logs.txt"

# bounded active Scanner traffic은 두 번째 kill과 ISR=1 failure witness를 감싼다.
active_base_scan_time="$(( $(date -u +%s) * 1000 ))"
{
  printf 'traffic_started_at_utc=%s\nrequest_count=%s\ninterval_seconds=%s\nbase_scan_time_ms=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$active_request_count" "$active_interval_seconds" "$active_base_scan_time"
} >"$evidence_dir/09-active-traffic-boundaries.txt"
(
  sequence=0
  while [ "$sequence" -lt "$active_request_count" ]; do
    scanner_request active-material "$sequence" "$((active_base_scan_time + sequence))"
    sequence=$((sequence + 1))
    sleep "$active_interval_seconds"
  done
  printf 'traffic_completed_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$evidence_dir/09-active-traffic-boundaries.txt"
) &
traffic_pid=$!
sleep 4
kill -0 "$traffic_pid"

# 두 번째 kill 직전 runtime metadata로 F1이 follower인지 재검증한다.
second_description="$(topic_describe "broker-$L1")"
second_line="$(target_line_from "$second_description")"
second_leader="$(line_leader "$second_line")"
second_isr="$(line_isr "$second_line")"
test "$second_leader" = "$L1"
test "$(isr_size "$second_isr")" -eq 2
isr_contains "$second_isr" "$F1"
! isr_contains "$second_isr" "$L0"
test "$F1" != "$second_leader"
container_state "$(container_name "$L1")" | grep -q 'status=running health=healthy'
container_state "$(container_name "$F1")" | grep -q 'status=running health=healthy'
F1_container="$(container_name "$F1")"
{
  printf 'decision_at_utc=%s\nP=%s\nL1=%s\nF1=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" "$L1" "$F1"
  printf 'revalidated_metadata=%s\nleader_alive=%s\n' "$second_line" "$(container_state "$(container_name "$L1")")"
  printf 'follower_before=%s\nmount_before=%s\n' "$(container_state "$F1_container")" "$(container_mounts "$F1_container")"
  printf 'command=docker compose ... kill -s SIGKILL broker-%s\nissued_at_utc=%s\n' "$F1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$evidence_dir/11-second-failure-F1.txt"
"${compose[@]}" kill -s SIGKILL "broker-$F1" >>"$evidence_dir/11-second-failure-F1.txt" 2>&1
second_killed=1
printf 'completed_at_utc=%s\nfollower_after=%s\nleader_after=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(container_state "$F1_container")" "$(container_state "$(container_name "$L1")")" \
  >>"$evidence_dir/11-second-failure-F1.txt"

wait_for_exact_target_state "broker-$L1" "$L1" 1 "$evidence_dir/timeline/12-second-transition-isr2-to1.txt"
kill -0 "$traffic_pid"
capture_state 13-isr1-leader-alive-state.txt "broker-$L1"

# ISR=1 failure witness: normal Ingest path, client retry 0, leader remains alive.
failure_scan_time="$(( $(date -u +%s) * 1000 + 303 ))"
failure_barcode="$(make_barcode "$failure_scan_time")"
failure_offset_before="$(target_offset "broker-$L1")"
failure_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
failure_result="$(direct_request isr1-failure-witness 2 "$failure_scan_time" "$failure_barcode" "$evidence_dir/14-isr1-failure-witness.txt")"
failure_http="${failure_result%% *}"
test "$failure_http" = 503
sleep 3
failure_offset_after="$(target_offset "broker-$L1")"
"${compose[@]}" logs --no-color --since "$failure_started_at" ingest processing scanner \
  >"$evidence_dir/15-isr1-failure-application-logs.txt" 2>&1
grep "Received barcode request: $failure_barcode" "$evidence_dir/15-isr1-failure-application-logs.txt"
grep -E "(Failed to send barcode event .*Barcode: $failure_barcode|Kafka 전송 확인 실패 - Barcode: $failure_barcode)" \
  "$evidence_dir/15-isr1-failure-application-logs.txt"
! grep -q "Sent barcode event .*Barcode: $failure_barcode" "$evidence_dir/15-isr1-failure-application-logs.txt"
{
  printf 'witness_started_at_utc=%s\nP=%s\nL1=%s\nF1=%s\n' "$failure_started_at" "$P" "$L1" "$F1"
  printf 'active_traffic_process_alive=true\nleader_state=%s\n' "$(container_state "$(container_name "$L1")")"
  printf 'target_offset_before=%s\ntarget_offset_after=%s\nmetadata_after=%s\n' \
    "$failure_offset_before" "$failure_offset_after" "$(target_line_from "$(topic_describe "broker-$L1")")"
} >"$evidence_dir/16-isr1-failure-verification.txt"

# F1을 같은 container/volume으로 먼저 복구하고 ISR 1→2를 확인한다.
{
  printf 'restart_requested_at_utc=%s\nF1=%s\ncontainer_before=%s\nmount_before=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$F1" "$(container_state "$F1_container")" "$(container_mounts "$F1_container")"
  printf 'command=docker compose ... start broker-%s\n' "$F1"
} >"$evidence_dir/18-F1-functional-recovery.txt"
"${compose[@]}" start "broker-$F1" >>"$evidence_dir/18-F1-functional-recovery.txt" 2>&1
second_killed=0
printf 'restart_completed_at_utc=%s\ncontainer_after=%s\nmount_after=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(container_state "$F1_container")" "$(container_mounts "$F1_container")" \
  >>"$evidence_dir/18-F1-functional-recovery.txt"
wait_for_exact_target_state "broker-$L1" "$L1" 2 "$evidence_dir/timeline/19-functional-recovery-isr1-to2.txt"
functional_line="$(target_line_from "$(topic_describe "broker-$L1")")"
functional_isr="$(line_isr "$functional_line")"
isr_contains "$functional_isr" "$F1"

recovery_scan_time="$(( $(date -u +%s) * 1000 + 505 ))"
recovery_barcode="$(make_barcode "$recovery_scan_time")"
recovery_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
recovery_result="$(direct_request isr2-recovery-witness 3 "$recovery_scan_time" "$recovery_barcode" "$evidence_dir/20-isr2-recovery-write-witness.txt")"
test "${recovery_result%% *}" = 200
sleep 3
"${compose[@]}" logs --no-color --since "$recovery_started_at" ingest processing worker-1 worker-2 \
  >"$evidence_dir/21-isr2-recovery-application-logs.txt" 2>&1
grep "Sent barcode event .*Barcode: $recovery_barcode, Partition: $P" "$evidence_dir/21-isr2-recovery-application-logs.txt"

# L0를 마지막으로 같은 volume에서 복구하고 전체 복제 상태를 수렴시킨다.
{
  printf 'restart_requested_at_utc=%s\nL0=%s\ncontainer_before=%s\nmount_before=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$L0" "$(container_state "$L0_container")" "$(container_mounts "$L0_container")"
  printf 'command=docker compose ... start broker-%s\n' "$L0"
} >"$evidence_dir/22-L0-full-recovery.txt"
"${compose[@]}" start "broker-$L0" >>"$evidence_dir/22-L0-full-recovery.txt" 2>&1
first_killed=0
printf 'restart_completed_at_utc=%s\ncontainer_after=%s\nmount_after=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(container_state "$L0_container")" "$(container_mounts "$L0_container")" \
  >>"$evidence_dir/22-L0-full-recovery.txt"
wait_for_full_recovery "broker-$L1"

wait "$traffic_pid"
traffic_pid=""
sleep 30

"${compose[@]}" logs --no-color --since "$run_started_at" ingest processing scanner worker-1 worker-2 \
  >"$evidence_dir/final/23-material-window-application-logs.txt" 2>&1
"${compose[@]}" logs --no-color --since "$run_started_at" controller broker-1 broker-2 broker-3 \
  >"$evidence_dir/final/24-material-window-kafka-logs.txt" 2>&1
capture_state final/25-terminal-state.txt "broker-$L1"

# 실행 범위 identity와 Kafka transport record를 직접 대조한다.
awk -F '\t' 'NR>1 {print $5}' "$evidence_dir/03-generated-manifest.tsv" | sort -n \
  >"$evidence_dir/final/26-generated-scan-times.txt"
generated_count="$(wc -l <"$evidence_dir/final/26-generated-scan-times.txt" | tr -d ' ')"
generated_unique="$(sort -u "$evidence_dir/final/26-generated-scan-times.txt" | wc -l | tr -d ' ')"
scan_time_csv="$(paste -sd, "$evidence_dir/final/26-generated-scan-times.txt")"
sql="SELECT CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED), original_barcode, internal_barcode_id, device_id FROM barcodes WHERE CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED) IN ($scan_time_csv) ORDER BY scan_time, id"
"${compose[@]}" exec -T mysql sh -lc \
  'mysql -N -B -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh "$sql" \
  >"$evidence_dir/final/27-run-scoped-mysql-rows.tsv" 2>"$evidence_dir/final/27-run-scoped-mysql-stderr.txt"
cut -f1 "$evidence_dir/final/27-run-scoped-mysql-rows.tsv" | sort -n >"$evidence_dir/final/28-mysql-scan-times.txt"

final_target_offset="$(target_offset "broker-$L1")"
transport_delta="$((final_target_offset - baseline_target_offset))"
"${compose[@]}" exec -T "broker-$L1" kafka-console-consumer --bootstrap-server "$bootstrap" \
  --topic barcode-events --partition "$P" --offset "$baseline_target_offset" \
  --max-messages "$transport_delta" --timeout-ms 15000 \
  >"$evidence_dir/final/29-run-scoped-kafka-records.jsonl" \
  2>"$evidence_dir/final/29-run-scoped-kafka-consumer-stderr.txt"
jq -r '.scanTime' "$evidence_dir/final/29-run-scoped-kafka-records.jsonl" | sort -n \
  >"$evidence_dir/final/30-kafka-scan-times.txt"
jq -r '.barcode' "$evidence_dir/final/29-run-scoped-kafka-records.jsonl" | sort \
  >"$evidence_dir/final/31-kafka-barcodes.txt"
sort -u "$evidence_dir/final/30-kafka-scan-times.txt" >"$evidence_dir/final/32-kafka-unique-scan-times.txt"
sort -u "$evidence_dir/final/28-mysql-scan-times.txt" >"$evidence_dir/final/33-mysql-unique-scan-times.txt"
comm -23 "$evidence_dir/final/32-kafka-unique-scan-times.txt" "$evidence_dir/final/33-mysql-unique-scan-times.txt" \
  >"$evidence_dir/final/34-kafka-not-mysql.txt"
comm -13 "$evidence_dir/final/26-generated-scan-times.txt" "$evidence_dir/final/33-mysql-unique-scan-times.txt" \
  >"$evidence_dir/final/35-mysql-extra.txt"
printf '%s\n' "$failure_scan_time" >"$evidence_dir/final/36-expected-rejection-candidate.txt"
if grep -qx "$failure_scan_time" "$evidence_dir/final/32-kafka-unique-scan-times.txt"; then
  : >"$evidence_dir/final/37-directly-evidenced-rejected.txt"
else
  printf '%s\n' "$failure_scan_time" >"$evidence_dir/final/37-directly-evidenced-rejected.txt"
fi
sort -u "$evidence_dir/final/33-mysql-unique-scan-times.txt" "$evidence_dir/final/37-directly-evidenced-rejected.txt" \
  >"$evidence_dir/final/38-accounted-scan-times.txt"
comm -23 "$evidence_dir/final/26-generated-scan-times.txt" "$evidence_dir/final/38-accounted-scan-times.txt" \
  >"$evidence_dir/final/39-unaccounted-scan-times.txt"
cut -f1 "$evidence_dir/final/27-run-scoped-mysql-rows.tsv" | sort | uniq -d >"$evidence_dir/final/40-business-duplicate-scan-times.txt"
cut -f2 "$evidence_dir/final/27-run-scoped-mysql-rows.tsv" | sort | uniq -d >"$evidence_dir/final/41-business-duplicate-barcodes.txt"

kafka_records="$(wc -l <"$evidence_dir/final/29-run-scoped-kafka-records.jsonl" | tr -d ' ')"
kafka_unique="$(wc -l <"$evidence_dir/final/32-kafka-unique-scan-times.txt" | tr -d ' ')"
transport_duplicates="$((kafka_records - kafka_unique))"
mysql_rows="$(wc -l <"$evidence_dir/final/27-run-scoped-mysql-rows.tsv" | tr -d ' ')"
mysql_unique="$(wc -l <"$evidence_dir/final/33-mysql-unique-scan-times.txt" | tr -d ' ')"
expected_rejected="$(wc -l <"$evidence_dir/final/37-directly-evidenced-rejected.txt" | tr -d ' ')"
unaccounted="$(wc -l <"$evidence_dir/final/39-unaccounted-scan-times.txt" | tr -d ' ')"
mysql_extra="$(wc -l <"$evidence_dir/final/35-mysql-extra.txt" | tr -d ' ')"
kafka_not_mysql="$(wc -l <"$evidence_dir/final/34-kafka-not-mysql.txt" | tr -d ' ')"
business_duplicate_scan_times="$(wc -l <"$evidence_dir/final/40-business-duplicate-scan-times.txt" | tr -d ' ')"
business_duplicate_barcodes="$(wc -l <"$evidence_dir/final/41-business-duplicate-barcodes.txt" | tr -d ' ')"
dlt_count="$("${compose[@]}" exec -T "broker-$L1" kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events-dlt | awk -F: '{sum+=$3}END{print sum+0}')"
dlq_count="$("${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq | tr -d '\r')"
pending_count="$("${compose[@]}" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group | sed -n '1p' | tr -d '\r')"
consumer_group="$("${compose[@]}" exec -T "broker-$L1" kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group)"
target_lag="$(printf '%s\n' "$consumer_group" | awk -v partition="$P" '$2=="barcode-events" && $3==partition {print $6}')"
redis_group="$("${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream)"
redis_lag="$(printf '%s\n' "$redis_group" | awk 'previous=="lag"{print;exit}{previous=$0}')"
driver_non_200="$(awk -F '\t' 'NR>1 && $7 != 200 {c++} END{print c+0}' "$evidence_dir/03-generated-manifest.tsv")"
scanner_fallback_batches="$(grep -c '건별 재전송으로 폴백' "$evidence_dir/final/23-material-window-application-logs.txt" || true)"
scanner_retry_queue_events="$(grep -c 'Retry queue size:' "$evidence_dir/final/23-material-window-application-logs.txt" || true)"
scanner_retry_high_water="$(sed -nE 's/.*Retry queue size: ([0-9]+)\/.*/\1/p' "$evidence_dir/final/23-material-window-application-logs.txt" | sort -nr | sed -n '1p')"
scanner_retry_high_water="${scanner_retry_high_water:-0}"
scanner_queue_drops="$(grep -Ec 'Retry queue is full|Retry failed and queue is full|Dropping barcode' "$evidence_dir/final/23-material-window-application-logs.txt" || true)"
processing_duplicate_detections="$(grep -c 'Duplicate barcode detected:' "$evidence_dir/final/23-material-window-application-logs.txt" || true)"
traffic_start="$(awk -F= '$1=="traffic_started_at_utc"{print $2}' "$evidence_dir/09-active-traffic-boundaries.txt")"
traffic_end="$(awk -F= '$1=="traffic_completed_at_utc"{print $2}' "$evidence_dir/09-active-traffic-boundaries.txt")"

{
  printf 'reconciled_at_utc=%s\nP=%s\nL0=%s\nL1=%s\nF1=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" "$L0" "$L1" "$F1"
  printf 'active_traffic_start=%s\nactive_traffic_end=%s\nfailure_witness_attempt=%s\n' "$traffic_start" "$traffic_end" "$failure_started_at"
  printf 'generated_count=%s\ngenerated_unique=%s\ndriver_non_200=%s\n' "$generated_count" "$generated_unique" "$driver_non_200"
  printf 'baseline_target_offset=%s\nfinal_target_offset=%s\nkafka_records=%s\nkafka_unique_identities=%s\ntransport_duplicates=%s\n' \
    "$baseline_target_offset" "$final_target_offset" "$kafka_records" "$kafka_unique" "$transport_duplicates"
  printf 'mysql_rows=%s\nmysql_unique_identities=%s\nexpected_rejected=%s\nunaccounted=%s\nmysql_extra=%s\nkafka_not_mysql=%s\n' \
    "$mysql_rows" "$mysql_unique" "$expected_rejected" "$unaccounted" "$mysql_extra" "$kafka_not_mysql"
  printf 'business_duplicate_scan_times=%s\nbusiness_duplicate_barcodes=%s\n' "$business_duplicate_scan_times" "$business_duplicate_barcodes"
  printf 'dlt=%s\ndlq=%s\npending=%s\nkafka_target_lag=%s\nredis_group_lag=%s\n' "$dlt_count" "$dlq_count" "$pending_count" "$target_lag" "$redis_lag"
  printf 'scanner_fallback_log_events=%s\nscanner_retry_queue_log_events=%s\nscanner_retry_queue_high_water=%s\nscanner_queue_drops=%s\nprocessing_duplicate_detections=%s\n' \
    "$scanner_fallback_batches" "$scanner_retry_queue_events" "$scanner_retry_high_water" "$scanner_queue_drops" "$processing_duplicate_detections"
  printf 'failure_witness_http=%s\nfailure_witness_offset_before=%s\nfailure_witness_offset_after=%s\n' "$failure_http" "$failure_offset_before" "$failure_offset_after"
  printf 'isr2_degraded_witness_http=200\nisr2_recovery_witness_http=200\n'
} >"$evidence_dir/final/42-run-scoped-reconciliation-summary.txt"

test "$generated_count" -eq "$generated_unique"
test "$kafka_records" -eq "$transport_delta"
test "$kafka_unique" -eq "$mysql_unique"
test "$mysql_rows" -eq "$mysql_unique"
test "$((mysql_unique + expected_rejected))" -eq "$generated_unique"
test "$unaccounted" -eq 0
test "$mysql_extra" -eq 0
test "$kafka_not_mysql" -eq 0
test "$business_duplicate_scan_times" -eq 0
test "$business_duplicate_barcodes" -eq 0
test "$dlt_count" -eq 0
test "$dlq_count" -eq 0
test "$pending_count" -eq 0
test "$target_lag" -eq 0
test "$redis_lag" -eq 0
test "$scanner_queue_drops" -eq 0
test "$traffic_start" '<' "$failure_started_at"
test "$failure_started_at" '<' "$traffic_end"

{
  printf 'run_completed_at_utc=%s\nstatus=material_run_completed_checks_passed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'contract_mapping=%s -> %s\nP=%s\nL0=%s\nL1=%s\nF1=%s\n' "$run_id" "$contract_revision" "$P" "$L0" "$L1" "$F1"
  printf 'semantic_progression=ISR3 -> L0 SIGKILL -> ISR2/write200 -> active traffic -> F1 SIGKILL -> ISR1/write503 -> F1 recovery -> ISR2/write200 -> L0 recovery -> ISR3\n'
} >"$evidence_dir/43-run-checks.txt"

(
  cd "$evidence_dir"
  find . -type f ! -name MANIFEST.sha256 -print | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done >MANIFEST.sha256
)
(
  cd "$evidence_dir"
  shasum -a 256 -c MANIFEST.sha256
)

trap - EXIT
printf 'run_id=%s\nP=%s\nL0=%s\nL1=%s\nF1=%s\nevidence_dir=%s\n' \
  "$run_id" "$P" "$L0" "$L1" "$F1" "$evidence_dir"
