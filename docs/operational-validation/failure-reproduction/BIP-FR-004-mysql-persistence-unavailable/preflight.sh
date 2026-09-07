#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
expected_branch="validation/bip-fr-004-mysql-persistence-unavailable"
expected_head="${1:-}"
compose_file="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
env_file="$repo_root/.env"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
minimum_disk_kib=$((20 * 1024 * 1024))
minimum_docker_memory_bytes=$((5 * 1024 * 1024 * 1024))

if [ -z "$expected_head" ]; then
  echo "usage: $0 <human-gate-approved-head>" >&2
  exit 2
fi

for command_name in git sysctl memory_pressure df docker curl awk sed grep jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command missing: $command_name" >&2
    exit 1
  }
done

test -f "$env_file"
test -f "$compose_file"
test "$(git -C "$repo_root" branch --show-current)" = "$expected_branch"
test "$(git -C "$repo_root" rev-parse HEAD)" = "$expected_head"
test -z "$(git -C "$repo_root" status --porcelain=v1)"

compose=(docker compose --env-file "$env_file" -f "$compose_file")

echo "checked_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "repository=$repo_root"
echo "branch=$expected_branch"
echo "head=$expected_head"
echo "contract_id=BIP-FR-004-RC"
echo "contract_revision=BIP-FR-004-RC-R2"
echo "compose_file_sha256=$(shasum -a 256 "$compose_file" | awk '{print $1}')"

logical_cpu="$(sysctl -n hw.logicalcpu)"
host_memory_bytes="$(sysctl -n hw.memsize)"
memory_pressure_output="$(memory_pressure -Q)"
memory_free_percentage="$(printf '%s\n' "$memory_pressure_output" | awk -F': ' '/System-wide memory free percentage/ {gsub(/%/, "", $2); print $2}')"
disk_available_kib="$(df -Pk "$repo_root" | awk 'NR==2 {print $4}')"
docker_info="$(docker info 2>/dev/null || true)"
docker_cpu="$(docker info --format '{{.NCPU}}')"
docker_memory_bytes="$(docker info --format '{{.MemTotal}}')"

echo "host_logical_cpu=$logical_cpu"
echo "host_memory_bytes=$host_memory_bytes"
printf '%s\n' "$memory_pressure_output"
echo "repository_disk_available_kib=$disk_available_kib"
echo "docker_cpu=$docker_cpu"
echo "docker_memory_bytes=$docker_memory_bytes"

test -n "$docker_info"
test -n "$memory_free_percentage"
test "$memory_free_percentage" -ge 10
test "$disk_available_kib" -ge "$minimum_disk_kib"
test "$docker_memory_bytes" -ge "$minimum_docker_memory_bytes"

docker system df
docker stats --no-stream --format 'name={{.Name}} cpu={{.CPUPerc}} memory={{.MemUsage}} memory_percent={{.MemPerc}} pids={{.PIDs}}'
"${compose[@]}" ps

required_containers=(
  bip-fr-002-controller
  bip-fr-002-broker-1
  bip-fr-002-broker-2
  bip-fr-002-broker-3
  bip-fr-002-mysql
  bip-fr-002-redis
  bip-fr-002-ingest
  bip-fr-002-processing
  bip-fr-002-scanner
  bip-fr-002-worker-1
  bip-fr-002-worker-2
)

for container_name in "${required_containers[@]}"; do
  state="$(docker inspect --format '{{.State.Status}}' "$container_name")"
  oom_killed="$(docker inspect --format '{{.State.OOMKilled}}' "$container_name")"
  restart_count="$(docker inspect --format '{{.RestartCount}}' "$container_name")"
  health="$(docker inspect --format '{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}' "$container_name")"
  echo "container=$container_name state=$state health=$health restart_count=$restart_count oom_killed=$oom_killed"
  test "$state" = "running"
  test "$oom_killed" = "false"
  test "$restart_count" -eq 0
done

for healthy_container in bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3 bip-fr-002-mysql bip-fr-002-redis; do
  test "$(docker inspect --format '{{.State.Health.Status}}' "$healthy_container")" = "healthy"
done

topic_description="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --topic barcode-events)"
printf '%s\n' "$topic_description"
partition_count="$(printf '%s\n' "$topic_description" | awk '/Partition: [0-9]+/ {count++} END {print count+0}')"
full_isr_count="$(printf '%s\n' "$topic_description" | awk '
  /Partition: [0-9]+/ {
    line=$0
    sub(/^.*Isr: /, "", line)
    sub(/[[:space:]].*$/, "", line)
    n=split(line, replicas, ",")
    if (n == 3) count++
  }
  END {print count+0}')"
test "$partition_count" -eq 3
test "$full_isr_count" -eq 3
test "$(printf '%s\n' "$topic_description" | awk '/Partition: [0-9]+/ && /Replicas: [0-9]+,[0-9]+,[0-9]+/ {count++} END {print count+0}')" -eq 3

topic_config="$("${compose[@]}" exec -T broker-1 kafka-configs --bootstrap-server "$bootstrap" --entity-type topics --entity-name barcode-events --describe)"
printf '%s\n' "$topic_config"
printf '%s\n' "$topic_config" | grep -q 'min.insync.replicas=2'

under_replicated="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions)"
unavailable="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions)"
test -z "$under_replicated"
test -z "$unavailable"
echo "under_replicated=NONE"
echo "unavailable=NONE"

for port in 18081 18082 18084 18085 18086; do
  health_body="$(curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/actuator/health")"
  echo "application_port=$port health=$health_body"
  printf '%s\n' "$health_body" | grep -q '"status":"UP"'
done

"${compose[@]}" exec -T mysql sh -lc \
  'mysqladmin ping -h localhost -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent'
test "$("${compose[@]}" exec -T redis redis-cli ping | tr -d '\r')" = "PONG"

group_json="$("${compose[@]}" exec -T redis redis-cli --json XINFO GROUPS barcode:stream)"
pending_json="$("${compose[@]}" exec -T redis redis-cli --json XPENDING barcode:stream barcode-persistence-group)"
consumer_json="$("${compose[@]}" exec -T redis redis-cli --json XINFO CONSUMERS barcode:stream barcode-persistence-group)"
printf 'redis_group=%s\nredis_pending=%s\nredis_consumers=%s\n' "$group_json" "$pending_json" "$consumer_json"
test "$(printf '%s' "$group_json" | jq -r '.[0].lag')" -eq 0
test "$(printf '%s' "$group_json" | jq -r '.[0].pending')" -eq 0
test "$(printf '%s' "$group_json" | jq -r '.[0].consumers')" -eq 2

redis_dlq="$("${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq | tr -d '\r')"
dlt_total="$("${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events-dlt | awk -F: '{sum += $3} END {print sum+0}')"
echo "redis_dlq=$redis_dlq"
echo "kafka_dlt=$dlt_total"
test "$redis_dlq" -eq 0
test "$dlt_total" -eq 0

consumer_group="$("${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group)"
printf '%s\n' "$consumer_group"
if printf '%s\n' "$consumer_group" | awk '$6 ~ /^[0-9]+$/ && $6 > 0 {found=1} END {exit found ? 0 : 1}'; then
  echo "positive Kafka consumer lag detected" >&2
  exit 1
fi

echo "RESOURCE_PREFLIGHT=PASS"
