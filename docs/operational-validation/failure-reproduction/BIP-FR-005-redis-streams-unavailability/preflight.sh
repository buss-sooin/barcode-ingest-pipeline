#!/usr/bin/env bash

set -euo pipefail

mode="${1:-runtime}"
case "$mode" in
  static|runtime) ;;
  *) echo "usage: $0 [static|runtime]" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
contract_file="$scenario_dir/REPRODUCTION-CONTRACT.md"
registration_file="$scenario_dir/evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/run-registration.txt"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$scenario_dir/docker-compose.release.yml"
env_file="$repo_root/.env"
run_id="BIP-FR-005-MR-20260911T112314Z"
contract_revision="BIP-FR-005-RC-R1"
expected_branch="validation/bip-fr-004-mysql-persistence-unavailable"
expected_head="57b59577ac856d664fd69f5a6c4867f1f583be8c"
expected_contract_sha256="1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865"
expected_tracked_diff_sha256="8b80e8d182b00b0e5a476a7185bfb3fc9b7d5c1712202e1b62a0244bcc936f37"
expected_untracked_set_sha256="c46004e897fbc560945f66ece023f7470d210aaa9386b0d956af2d63f75c49e2"
expected_implementation_sha256="47c238fc9078a37422f81ce353ccf0a626c3341d7d9ddd7b6d49e73aea3a756e"
expected_processing_image="barcode-processing-service:bip-fr-005-mr-20260911t112314z"
expected_processing_image_id="sha256:525e3ee5d7c0966878fe33f31585361560b2a3721ed49a790cc75c41c0a30ea9"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"

for command_name in git shasum awk grep docker curl jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required_command_missing=$command_name" >&2
    exit 1
  }
done

test -f "$contract_file"
test -f "$registration_file"
test -f "$base_compose"
test -f "$release_compose"
test "$(git -C "$repo_root" branch --show-current)" = "$expected_branch"
test "$(git -C "$repo_root" rev-parse HEAD)" = "$expected_head"
test "$(shasum -a 256 "$contract_file" | awk '{print $1}')" = "$expected_contract_sha256"
grep -Fx 'contract_status=FROZEN' "$registration_file" >/dev/null
grep -Fx 'state=REGISTERED' "$registration_file" >/dev/null
grep -Fx 'execution_state=NOT_EXECUTED' "$registration_file" >/dev/null
grep -Fx 'outcome=NOT_ASSIGNED' "$registration_file" >/dev/null

tracked_diff_sha256="$(git -C "$repo_root" diff --binary HEAD -- \
  barcode-processing-service/src/main barcode-processing-service/src/main/resources \
  | shasum -a 256 | awk '{print $1}')"
untracked_set_sha256="$(git -C "$repo_root" ls-files --others --exclude-standard -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  barcode-processing-service/src/main/resources \
  | sort | while IFS= read -r file; do
      shasum -a 256 "$repo_root/$file"
    done | sed "s#$repo_root/##" | shasum -a 256 | awk '{print $1}')"
implementation_sha256="$(printf 'branch=%s\nhead=%s\ntracked_diff_sha256=%s\nuntracked_set_sha256=%s\n' \
  "$expected_branch" "$expected_head" "$tracked_diff_sha256" "$untracked_set_sha256" \
  | shasum -a 256 | awk '{print $1}')"

test "$tracked_diff_sha256" = "$expected_tracked_diff_sha256"
test "$untracked_set_sha256" = "$expected_untracked_set_sha256"
test "$implementation_sha256" = "$expected_implementation_sha256"

actual_image_id="$(docker image inspect "$expected_processing_image" --format '{{.Id}}')"
actual_revision="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
actual_implementation="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.implementation.sha256"}}')"
actual_contract="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.contract"}}')"
actual_run="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.material-run"}}')"
test "$actual_image_id" = "$expected_processing_image_id"
test "$actual_revision" = "$expected_head"
test "$actual_implementation" = "$expected_implementation_sha256"
test "$actual_contract" = "$contract_revision"
test "$actual_run" = "$run_id"

printf 'checked_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'mode=%s\nrun_id=%s\ncontract_revision=%s\n' "$mode" "$run_id" "$contract_revision"
printf 'branch=%s\nhead=%s\n' "$expected_branch" "$expected_head"
printf 'tracked_diff_sha256=%s\nuntracked_set_sha256=%s\nimplementation_identity_sha256=%s\n' \
  "$tracked_diff_sha256" "$untracked_set_sha256" "$implementation_sha256"
printf 'processing_image=%s\nprocessing_image_id=%s\n' "$expected_processing_image" "$actual_image_id"

if [ "$mode" = "static" ]; then
  echo 'NORMAL_COHORT_DATA_CONTRACT=NOT_EVALUATED_STATIC'
  echo 'STATIC_PREFLIGHT=PASS'
  exit 0
fi

test -f "$env_file"
compose=(docker compose --env-file "$env_file" -f "$base_compose" -f "$release_compose")
rendered_processing_image="$("${compose[@]}" config --format json | jq -r '.services.processing.image')"
test "$rendered_processing_image" = "$expected_processing_image"

while IFS='|' read -r container_name expected_container_image; do
  state="$(docker inspect --format '{{.State.Status}}' "$container_name")"
  image_id="$(docker inspect --format '{{.Image}}' "$container_name")"
  restart_count="$(docker inspect --format '{{.RestartCount}}' "$container_name")"
  printf 'container=%s state=%s image_id=%s restart_count=%s\n' \
    "$container_name" "$state" "$image_id" "$restart_count"
  test "$state" = running
  test "$image_id" = "$expected_container_image"
  test "$restart_count" -eq 0
done <<EOF
bip-fr-002-controller|sha256:7cd4ffecaaf138cdb88030b3656a37a4e8651cdc8141c70062c869b13e8ff249
bip-fr-002-broker-1|sha256:7cd4ffecaaf138cdb88030b3656a37a4e8651cdc8141c70062c869b13e8ff249
bip-fr-002-broker-2|sha256:7cd4ffecaaf138cdb88030b3656a37a4e8651cdc8141c70062c869b13e8ff249
bip-fr-002-broker-3|sha256:7cd4ffecaaf138cdb88030b3656a37a4e8651cdc8141c70062c869b13e8ff249
bip-fr-002-mysql|sha256:5e7e005a680e75d935984d3d9390990d2a709b3ed67e92708e9e6747f1f754c9
bip-fr-002-redis|sha256:59c08762bdbcf53fa132aa0bae464a57a1309dc3fff8a034bb3e16d7a0b30ec5
bip-fr-002-ingest|sha256:0bc5151c97bc7cf4ed3c0bf9e801ff4e1231f192447f735f5c6bc37725596c6d
bip-fr-002-processing|$expected_processing_image_id
bip-fr-002-scanner|sha256:ddafb8a95bbddb398f4cdf4cb34469aa1315eef24c9abdfc9b6ae66f76a16561
bip-fr-002-worker-1|sha256:b1183529237795e3b92945e21c097224d4246a2ef0e6ac93cb33d748ee8719ec
bip-fr-002-worker-2|sha256:b1183529237795e3b92945e21c097224d4246a2ef0e6ac93cb33d748ee8719ec
EOF

for healthy_container in bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3 bip-fr-002-mysql bip-fr-002-redis; do
  health="$(docker inspect --format '{{.State.Health.Status}}' "$healthy_container")"
  printf 'container=%s health=%s\n' "$healthy_container" "$health"
  test "$health" = healthy
done

for port in 18081 18082 18084 18085 18086; do
  health_body="$(curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/actuator/health")"
  printf 'application_port=%s health=%s\n' "$port" "$health_body"
  printf '%s\n' "$health_body" | grep -q '"status":"UP"'
done

for topic in barcode-events barcode-events-dlt barcode-events-quarantine; do
  topic_description="$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --topic "$topic")"
  printf '%s\n' "$topic_description"
  test "$(printf '%s\n' "$topic_description" | grep -c 'Partition:')" -eq 3
  test -z "$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions --topic "$topic")"
  test -z "$("${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions --topic "$topic")"
done

source_group="$("${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group)"
printf '%s\n' "$source_group"
if printf '%s\n' "$source_group" | awk '$6 ~ /^[0-9]+$/ && $6 > 0 {found=1} END {exit found ? 0 : 1}'; then
  echo 'source_consumer_lag_positive=true' >&2
  exit 1
fi

disposition_groups="$("${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --list)"
if printf '%s\n' "$disposition_groups" | grep -Fx 'barcode-events-dlt-disposition' >/dev/null; then
  echo 'dlt_disposition_group=EXISTS'
  "${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" \
    --describe --group barcode-events-dlt-disposition
else
  echo 'dlt_disposition_group=ABSENT_BEFORE_FIRST_EXECUTION'
fi

test "$("${compose[@]}" exec -T redis redis-cli ping | tr -d '\r')" = PONG
group_json="$("${compose[@]}" exec -T redis redis-cli --json XINFO GROUPS barcode:stream)"
pending_json="$("${compose[@]}" exec -T redis redis-cli --json XPENDING barcode:stream barcode-persistence-group)"
printf 'redis_groups=%s\nredis_pending=%s\n' "$group_json" "$pending_json"
test "$(printf '%s' "$group_json" | jq -r '.[0].lag')" -eq 0
test "$(printf '%s' "$group_json" | jq -r '.[0].pending')" -eq 0

"${compose[@]}" exec -T mysql sh -lc \
  'mysqladmin ping -h localhost -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent'

normal_cohort_contract_output="$("$scenario_dir/normal-cohort-data-contract.sh")"
printf '%s\n' "$normal_cohort_contract_output"
printf '%s\n' "$normal_cohort_contract_output" \
  | grep -Fx 'NORMAL_COHORT_DATA_CONTRACT=PASS' >/dev/null

for topic in barcode-events-dlt barcode-events-quarantine; do
  total="$("${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic "$topic" \
    | awk -F: '{sum += $3} END {print sum+0}')"
  printf 'topic=%s total_end_offset=%s\n' "$topic" "$total"
  test "$total" -eq 0
done

echo 'RUNTIME_PREFLIGHT=PASS'
