#!/usr/bin/env bash

set -euo pipefail

mode="${1:-runtime}"
case "$mode" in
  static|runtime) ;;
  *) echo "usage: $0 [static|runtime]" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
preflight_v2_rel="docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/preflight-v2.sh"
contract_file="$scenario_dir/REPRODUCTION-CONTRACT.md"
registration_file="$scenario_dir/evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/run-registration.txt"
release_identity_file="$scenario_dir/evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/release-identity.txt"
current_manifest="$scenario_dir/evidence/BIP-FR-005-MR-20260911T112314Z/MANIFEST.sha256"
implementation_manifest="$scenario_dir/evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/implementation-files.sha256"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$scenario_dir/docker-compose.release.yml"
env_file="$repo_root/.env"

run_id="BIP-FR-005-MR-20260911T112314Z"
contract_revision="BIP-FR-005-RC-R1"
historical_registration_branch="validation/bip-fr-004-mysql-persistence-unavailable"
historical_registration_base="57b59577ac856d664fd69f5a6c4867f1f583be8c"
canonical_implementation_commit="e540d4238480cddd08ceb4578a93e935ed731b8b"
canonicalization_anchor="7eba27e22a36a5e50109351f7dbd518d3c78b71b"
expected_branch="validation/bip-fr-005-redis-streams-unavailability"

expected_contract_sha256="1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865"
expected_registration_sha256="65c137961477b1a25aa9aa9453139860f6b61d680d62dc42720df0935e0e3d1c"
expected_release_identity_sha256="3198f1b433d5f1cc552e35a641e4fd8f8d86e9d9832b2b00d3fcf7338fb766fe"
expected_current_manifest_sha256="f0c83b60bb91eb4ff657d11eff8848d757c1b3662cf12afb68a1413f2323a7df"
expected_tracked_diff_sha256="8b80e8d182b00b0e5a476a7185bfb3fc9b7d5c1712202e1b62a0244bcc936f37"
expected_untracked_set_sha256="c46004e897fbc560945f66ece023f7470d210aaa9386b0d956af2d63f75c49e2"
expected_implementation_sha256="47c238fc9078a37422f81ce353ccf0a626c3341d7d9ddd7b6d49e73aea3a756e"
expected_processing_image="barcode-processing-service:bip-fr-005-mr-20260911t112314z"
expected_processing_image_id="sha256:525e3ee5d7c0966878fe33f31585361560b2a3721ed49a790cc75c41c0a30ea9"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"

release_preparation_paths="
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/EXECUTION-PREPARATION.txt
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/capture-kafka-window.sh
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/capture-state.sh
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/normal-cohort-data-contract.sh
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/preflight.sh
docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/provision-quarantine-topic.sh
"

fail() {
  printf 'failed_predicate=%s\nIDENTITY_RECONCILIATION=FAIL\n' "$1" >&2
  exit 1
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

for command_name in git shasum awk grep docker curl jq sort comm sed wc; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required_command_missing:$command_name"
done

for required_file in \
  "$contract_file" \
  "$registration_file" \
  "$release_identity_file" \
  "$current_manifest" \
  "$implementation_manifest" \
  "$base_compose" \
  "$release_compose"; do
  test -f "$required_file" || fail "required_file_missing:$required_file"
done

for required_commit in \
  "$historical_registration_base" \
  "$canonical_implementation_commit" \
  "$canonicalization_anchor"; do
  git -C "$repo_root" cat-file -e "$required_commit^{commit}" \
    || fail "required_commit_missing:$required_commit"
done

preparation_head="$(git -C "$repo_root" rev-parse HEAD)"
require_equal current_branch "$expected_branch" "$(git -C "$repo_root" branch --show-current)"
test -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" \
  || fail current_checkout_not_clean
git -C "$repo_root" ls-files --error-unmatch "$preflight_v2_rel" >/dev/null 2>&1 \
  || fail versioned_preflight_not_tracked

require_equal implementation_parent "$historical_registration_base" \
  "$(git -C "$repo_root" rev-parse "$canonical_implementation_commit^")"
require_equal canonicalization_parent "$canonical_implementation_commit" \
  "$(git -C "$repo_root" rev-parse "$canonicalization_anchor^")"
git -C "$repo_root" merge-base --is-ancestor "$canonicalization_anchor" "$preparation_head" \
  || fail preparation_head_not_descendant_of_canonicalization_anchor

require_equal contract_sha256 "$expected_contract_sha256" \
  "$(shasum -a 256 "$contract_file" | awk '{print $1}')"
require_equal registration_sha256 "$expected_registration_sha256" \
  "$(shasum -a 256 "$registration_file" | awk '{print $1}')"
require_equal release_identity_sha256 "$expected_release_identity_sha256" \
  "$(shasum -a 256 "$release_identity_file" | awk '{print $1}')"
require_equal current_manifest_sha256 "$expected_current_manifest_sha256" \
  "$(shasum -a 256 "$current_manifest" | awk '{print $1}')"

grep -Fx 'contract_status=FROZEN' "$registration_file" >/dev/null \
  || fail registration_contract_not_frozen
grep -Fx 'state=REGISTERED' "$registration_file" >/dev/null \
  || fail registration_state_mismatch
grep -Fx 'execution_state=NOT_EXECUTED' "$registration_file" >/dev/null \
  || fail registration_execution_state_mismatch
grep -Fx 'outcome=NOT_ASSIGNED' "$registration_file" >/dev/null \
  || fail registration_outcome_mismatch

(cd "$repo_root" && shasum -a 256 -c "$current_manifest" >/dev/null) \
  || fail registered_current_manifest_mismatch

modified_file_list="$(git -C "$repo_root" diff --name-only --diff-filter=M \
  "$historical_registration_base" "$canonical_implementation_commit" -- \
  barcode-processing-service/src/main barcode-processing-service/src/main/resources)"
require_equal registered_modified_file_count 3 \
  "$(printf '%s\n' "$modified_file_list" | sed '/^$/d' | wc -l | tr -d ' ')"

# Word splitting is intentional: registered implementation paths cannot contain whitespace.
# shellcheck disable=SC2086
tracked_diff_sha256="$(git -C "$repo_root" diff --binary \
  "$historical_registration_base" "$canonical_implementation_commit" -- $modified_file_list \
  | shasum -a 256 | awk '{print $1}')"
require_equal registered_tracked_diff_sha256 \
  "$expected_tracked_diff_sha256" "$tracked_diff_sha256"

added_file_list="$(git -C "$repo_root" diff --name-only --diff-filter=A \
  "$historical_registration_base" "$canonical_implementation_commit" -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  barcode-processing-service/src/main/resources | sort)"
require_equal registered_untracked_file_count 19 \
  "$(printf '%s\n' "$added_file_list" | sed '/^$/d' | wc -l | tr -d ' ')"

untracked_set_sha256="$(printf '%s\n' "$added_file_list" \
  | while IFS= read -r implementation_file; do
      test -n "$implementation_file" || continue
      git -C "$repo_root" show "$canonical_implementation_commit:$implementation_file" \
        | shasum -a 256 \
        | awk -v implementation_file="$implementation_file" \
            '{print $1 "  " implementation_file}'
    done \
  | shasum -a 256 | awk '{print $1}')"
require_equal registered_untracked_set_sha256 \
  "$expected_untracked_set_sha256" "$untracked_set_sha256"

implementation_sha256="$(printf 'branch=%s\nhead=%s\ntracked_diff_sha256=%s\nuntracked_set_sha256=%s\n' \
  "$historical_registration_branch" "$historical_registration_base" \
  "$tracked_diff_sha256" "$untracked_set_sha256" \
  | shasum -a 256 | awk '{print $1}')"
require_equal registered_implementation_identity_sha256 \
  "$expected_implementation_sha256" "$implementation_sha256"

implementation_diff_set="$(git -C "$repo_root" diff --name-only \
  "$historical_registration_base" "$canonical_implementation_commit" -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  barcode-processing-service/src/main/resources | sort)"
manifest_file_set="$(awk '{print $2}' "$implementation_manifest" | sort)"
test -z "$(comm -3 \
  <(printf '%s\n' "$manifest_file_set") \
  <(printf '%s\n' "$implementation_diff_set"))" \
  || fail implementation_manifest_file_set_mismatch

while read -r expected_digest implementation_file; do
  test -n "$expected_digest" || continue
  actual_digest="$(git -C "$repo_root" show \
    "$canonical_implementation_commit:$implementation_file" \
    | shasum -a 256 | awk '{print $1}')"
  require_equal "implementation_digest:$implementation_file" \
    "$expected_digest" "$actual_digest"
done < "$implementation_manifest"

expected_implementation_commit_set="$({
  printf '%s\n' "$manifest_file_set"
  printf '%s\n' "$release_preparation_paths" | sed '/^$/d'
} | sort)"
actual_implementation_commit_set="$(git -C "$repo_root" diff --name-only \
  "$historical_registration_base" "$canonical_implementation_commit" | sort)"
test -z "$(comm -3 \
  <(printf '%s\n' "$expected_implementation_commit_set") \
  <(printf '%s\n' "$actual_implementation_commit_set"))" \
  || fail canonical_implementation_commit_file_set_mismatch

# Word splitting is intentional for the fixed, whitespace-free preparation paths.
# shellcheck disable=SC2086
git -C "$repo_root" diff --quiet \
  "$canonical_implementation_commit" "$canonicalization_anchor" -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  $release_preparation_paths \
  || fail canonicalization_anchor_changes_implementation_or_preparation

git -C "$repo_root" diff --quiet \
  "$canonical_implementation_commit" "$preparation_head" -- \
  barcode-processing-service/src/main barcode-processing-service/src/test \
  || fail current_checkout_changes_canonical_implementation

# Word splitting is intentional for the fixed, whitespace-free preparation paths.
# shellcheck disable=SC2086
git -C "$repo_root" diff --quiet \
  "$canonicalization_anchor" "$preparation_head" -- $release_preparation_paths \
  || fail current_checkout_changes_registered_release_preparation

actual_image_id="$(docker image inspect "$expected_processing_image" --format '{{.Id}}')"
actual_revision="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
actual_implementation="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.implementation.sha256"}}')"
actual_contract="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.contract"}}')"
actual_run="$(docker image inspect "$expected_processing_image" --format '{{index .Config.Labels "io.bip.material-run"}}')"
require_equal frozen_image_id "$expected_processing_image_id" "$actual_image_id"
require_equal frozen_image_registration_revision "$historical_registration_base" "$actual_revision"
require_equal frozen_image_implementation_identity "$expected_implementation_sha256" "$actual_implementation"
require_equal frozen_image_contract "$contract_revision" "$actual_contract"
require_equal frozen_image_material_run "$run_id" "$actual_run"

printf 'checked_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'mode=%s\nrun_id=%s\ncontract_revision=%s\n' "$mode" "$run_id" "$contract_revision"
printf 'historical_registration_branch=%s\nhistorical_registration_base=%s\n' \
  "$historical_registration_branch" "$historical_registration_base"
printf 'registered_tracked_diff_sha256=%s\nregistered_untracked_set_sha256=%s\n' \
  "$tracked_diff_sha256" "$untracked_set_sha256"
printf 'registered_implementation_identity_sha256=%s\n' "$implementation_sha256"
printf 'canonical_implementation_commit=%s\ncanonicalization_anchor=%s\npreparation_head=%s\n' \
  "$canonical_implementation_commit" "$canonicalization_anchor" "$preparation_head"
printf 'processing_image=%s\nprocessing_image_id=%s\nprocessing_image_revision_label=%s\n' \
  "$expected_processing_image" "$actual_image_id" "$actual_revision"
echo 'CURRENT_CHECKOUT=PASS'
echo 'IDENTITY_RECONCILIATION=PASS'

if [ "$mode" = "static" ]; then
  echo 'NORMAL_COHORT_DATA_CONTRACT=NOT_EVALUATED_STATIC'
  echo 'STATIC_PREFLIGHT_V2=PASS'
  exit 0
fi

test -f "$env_file" || fail env_file_missing
compose=(docker compose --env-file "$env_file" -f "$base_compose" -f "$release_compose")
rendered_processing_image="$("${compose[@]}" config --format json | jq -r '.services.processing.image')"
require_equal rendered_processing_image "$expected_processing_image" "$rendered_processing_image"

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
