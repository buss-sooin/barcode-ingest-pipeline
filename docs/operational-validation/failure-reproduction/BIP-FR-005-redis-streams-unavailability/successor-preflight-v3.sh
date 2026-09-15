#!/usr/bin/env bash

set -euo pipefail

mode="${1:-}"
run_dir="${2:-}"
runtime_evidence_dir="${3:-}"

case "$mode" in
  static) test "$#" -eq 2 || exit 2 ;;
  runtime) test "$#" -eq 3 || exit 2 ;;
  *) echo 'usage: successor-preflight-v3.sh static <run-dir> | runtime <run-dir> <new-runtime-evidence-dir>' >&2; exit 2 ;;
esac

fail() {
  printf 'failed_predicate=%s\nSUCCESSOR_PREFLIGHT_V3=FAIL\n' "$1" >&2
  exit 1
}

field() {
  local file="$1"
  local key="$2"
  local matches
  matches="$(awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$file")"
  test "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 \
    || fail "field_missing_or_duplicate:$key:$file"
  printf '%s\n' "$matches"
}

require_equal() {
  local predicate="$1"
  local expected="$2"
  local actual="$3"
  test "$actual" = "$expected" || {
    printf 'predicate=%s expected=%s actual=%s\n' "$predicate" "$expected" "$actual" >&2
    fail "$predicate"
  }
}

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
expected_evidence_root="$scenario_dir/evidence"
registration_file="$run_dir/00-environment/run-registration.txt"
release_identity_file="$run_dir/00-environment/release-identity.txt"
cohort_file="$run_dir/00-environment/cohort.tsv"
entry_dir="$run_dir/01-entry-baseline"
known_inventory="$scenario_dir/known-historical-residue-v1.tsv"
reconciliation="$scenario_dir/successor-baseline-reconciliation-v1.sh"
capture="$scenario_dir/successor-baseline-capture-v1.sh"
contract_file="$scenario_dir/REPRODUCTION-CONTRACT.md"
expected_contract_sha256="1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865"
expected_implementation_revision="83eaa799e2359a353e748e567a5fbfc0df0cf9c3"
expected_branch="validation/bip-fr-005-redis-streams-unavailability"
run_id="$(basename "$run_dir")"

for command_name in git awk grep sed wc shasum docker curl jq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required_command_missing:$command_name"
done
test -d "$run_dir" || fail run_directory_missing
case "$(cd "$run_dir/.." 2>/dev/null && pwd)/$run_id" in
  "$expected_evidence_root"/*) ;;
  *) fail run_directory_outside_scenario_evidence ;;
esac

for required_file in "$registration_file" "$release_identity_file" "$cohort_file" \
  "$entry_dir/baseline-watermarks.tsv" "$entry_dir/observed-residue.tsv" \
  "$entry_dir/successor-identity-state.tsv" "$entry_dir/runtime-metrics.tsv" \
  "$known_inventory" "$reconciliation" "$capture" "$contract_file"; do
  test -f "$required_file" || fail "required_file_missing:$required_file"
done

require_equal current_branch "$expected_branch" "$(git branch --show-current)"
test -z "$(git status --porcelain --untracked-files=all)" || fail current_checkout_not_clean
require_equal contract_sha256 "$expected_contract_sha256" \
  "$(shasum -a 256 "$contract_file" | awk '{print $1}')"

require_equal run_id "$run_id" "$(field "$registration_file" run_id)"
require_equal contract_revision BIP-FR-005-RC-R1 "$(field "$registration_file" contract_revision)"
require_equal contract_status FROZEN "$(field "$registration_file" contract_status)"
require_equal registration_state REGISTERED "$(field "$registration_file" state)"
require_equal execution_state NOT_EXECUTED "$(field "$registration_file" execution_state)"
require_equal outcome NOT_ASSIGNED "$(field "$registration_file" outcome)"
require_equal verified_reproduction_claim NONE "$(field "$registration_file" verified_reproduction_claim)"
require_equal implementation_revision "$expected_implementation_revision" \
  "$(field "$registration_file" implementation_revision)"
require_equal baseline_isolation_version 1 "$(field "$registration_file" baseline_isolation_version)"
require_equal historical_residue_inventory_sha256 \
  "$(shasum -a 256 "$known_inventory" | awk '{print $1}')" \
  "$(field "$registration_file" historical_residue_inventory_sha256)"

preparation_revision="$(field "$registration_file" preparation_revision)"
git cat-file -e "$preparation_revision^{commit}" || fail preparation_revision_missing
git merge-base --is-ancestor "$preparation_revision" HEAD || fail preparation_revision_not_ancestor
git diff --quiet "$expected_implementation_revision" HEAD -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  || fail corrected_application_implementation_drift

require_equal release_run_id "$run_id" "$(field "$release_identity_file" run_id)"
require_equal release_contract BIP-FR-005-RC-R1 "$(field "$release_identity_file" contract_revision)"
require_equal release_revision "$expected_implementation_revision" \
  "$(field "$release_identity_file" image_label_org.opencontainers.image.revision)"
require_equal release_contract_label BIP-FR-005-RC-R1 \
  "$(field "$release_identity_file" image_label_io.bip.contract)"
require_equal release_run_label "$run_id" \
  "$(field "$release_identity_file" image_label_io.bip.material-run)"

"$reconciliation" \
  --run-id "$run_id" \
  --cohort "$cohort_file" \
  --registered-watermarks "$entry_dir/baseline-watermarks.tsv" \
  --observed-watermarks "$entry_dir/baseline-watermarks.tsv" \
  --observed-residue "$entry_dir/observed-residue.tsv" \
  --identity-state "$entry_dir/successor-identity-state.tsv" \
  --runtime-metrics "$entry_dir/runtime-metrics.tsv"

printf 'run_id=%s\npreparation_revision=%s\ncurrent_head=%s\n' \
  "$run_id" "$preparation_revision" "$(git rev-parse HEAD)"
printf 'CURRENT_CHECKOUT=PASS\nFROZEN_R1_IDENTITY=PASS\nSTATIC_SUCCESSOR_PREFLIGHT_V3=PASS\n'

test "$mode" = runtime || exit 0

for container in bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3 \
  bip-fr-002-mysql bip-fr-002-redis bip-fr-002-ingest bip-fr-002-processing \
  bip-fr-002-scanner bip-fr-002-worker-1 bip-fr-002-worker-2; do
  state="$(docker inspect "$container" --format '{{.State.Status}}')"
  oom="$(docker inspect "$container" --format '{{.State.OOMKilled}}')"
  restarts="$(docker inspect "$container" --format '{{.RestartCount}}')"
  printf 'container=%s state=%s oom=%s restarts=%s\n' "$container" "$state" "$oom" "$restarts"
  test "$state" = running || fail "required_container_not_running:$container"
  test "$oom" = false || fail "required_container_oom:$container"
  test "$restarts" -eq 0 || fail "required_container_restarted:$container"
done

for container in bip-fr-002-broker-1 bip-fr-002-broker-2 bip-fr-002-broker-3 bip-fr-002-mysql bip-fr-002-redis; do
  test "$(docker inspect "$container" --format '{{.State.Health.Status}}')" = healthy \
    || fail "required_container_unhealthy:$container"
done

for port in 18081 18082 18084 18085 18086; do
  curl -fsS --max-time 5 "http://127.0.0.1:$port/actuator/health" \
    | grep -q '"status":"UP"' || fail "application_health_not_up:$port"
done

for topic in barcode-events barcode-events-dlt barcode-events-quarantine; do
  description="$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
    --describe --topic "$topic")"
  test "$(printf '%s\n' "$description" | grep -c 'Partition:')" -eq 3 \
    || fail "topic_partition_count:$topic"
  test -z "$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
    --describe --under-replicated-partitions --topic "$topic")" \
    || fail "kafka_under_replicated_partitions:$topic"
  test -z "$(docker exec bip-fr-002-broker-1 kafka-topics \
    --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
    --describe --unavailable-partitions --topic "$topic")" \
    || fail "kafka_unavailable_partitions:$topic"
done

expected_image="$(field "$release_identity_file" processing_image)"
expected_image_id="$(field "$release_identity_file" processing_image_id)"
require_equal local_frozen_image_id "$expected_image_id" \
  "$(docker image inspect "$expected_image" --format '{{.Id}}')"
require_equal running_processing_image_id "$expected_image_id" \
  "$(docker inspect bip-fr-002-processing --format '{{.Image}}')"
require_equal image_revision_label "$expected_implementation_revision" \
  "$(docker image inspect "$expected_image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
require_equal image_contract_label BIP-FR-005-RC-R1 \
  "$(docker image inspect "$expected_image" --format '{{index .Config.Labels "io.bip.contract"}}')"
require_equal image_run_label "$run_id" \
  "$(docker image inspect "$expected_image" --format '{{index .Config.Labels "io.bip.material-run"}}')"

"$capture" "$run_id" "$cohort_file" "$runtime_evidence_dir"
"$reconciliation" \
  --run-id "$run_id" \
  --cohort "$cohort_file" \
  --registered-watermarks "$entry_dir/baseline-watermarks.tsv" \
  --observed-watermarks "$runtime_evidence_dir/baseline-watermarks.tsv" \
  --observed-residue "$runtime_evidence_dir/observed-residue.tsv" \
  --identity-state "$runtime_evidence_dir/successor-identity-state.tsv" \
  --runtime-metrics "$runtime_evidence_dir/runtime-metrics.tsv"

printf 'GLOBAL_ZERO_PREDICATE=NOT_USED\nRUNTIME_SUCCESSOR_PREFLIGHT_V3=PASS\n'
