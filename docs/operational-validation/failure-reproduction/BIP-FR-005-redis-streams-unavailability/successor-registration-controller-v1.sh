#!/usr/bin/env bash

set -euo pipefail

command_name="${1:-}"
command_run_id="${2:-}"

usage() {
  cat >&2 <<'EOF'
usage: successor-registration-controller-v1.sh allocate
       successor-registration-controller-v1.sh resume
       successor-registration-controller-v1.sh register <run-id>
       successor-registration-controller-v1.sh eligibility <run-id>
EOF
  exit 2
}

fail() {
  printf 'failed_predicate=%s\nCONTROLLER_RESULT=FAIL\n' "$1" >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
production_evidence_root="$scenario_dir/evidence"
contract_file="$scenario_dir/REPRODUCTION-CONTRACT.md"
inventory_file="$scenario_dir/known-historical-residue-v1.tsv"
reconciliation="$scenario_dir/successor-baseline-reconciliation-v1.sh"

contract_revision="BIP-FR-005-RC-R1"
contract_sha256="1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865"
implementation_revision="83eaa799e2359a353e748e567a5fbfc0df0cf9c3"
preparation_revision="b124748fb72581614caa208287a31a3c4a3da8a1"
baseline_isolation_version="1"
inventory_sha256="2afac243749c714367a744b525f2f41e518add6378b549a710d16bf68b8cd068"
controller_version="1"

test_mode="${BIP_FR005_CONTROLLER_TEST_MODE:-0}"
if [ "$test_mode" = 1 ]; then
  evidence_root="${BIP_FR005_TEST_EVIDENCE_ROOT:-}"
  clock_command="${BIP_FR005_TEST_CLOCK_COMMAND:-}"
  test -n "$evidence_root" || fail test_evidence_root_missing
  test -x "$clock_command" || fail test_clock_command_missing
  max_clock_polls="${BIP_FR005_TEST_MAX_CLOCK_POLLS:-3}"
  clock_poll_seconds="${BIP_FR005_TEST_CLOCK_POLL_SECONDS:-0.01}"
  lock_attempts="${BIP_FR005_TEST_LOCK_ATTEMPTS:-100}"
  lock_poll_seconds="${BIP_FR005_TEST_LOCK_POLL_SECONDS:-0.01}"
else
  evidence_root="$production_evidence_root"
  clock_command=""
  max_clock_polls=5
  clock_poll_seconds=1
  lock_attempts=50
  lock_poll_seconds=0.1
fi

controller_root="$evidence_root/.fr005-registration-controller-v1"
index_root="$controller_root/index"
lock_dir="$controller_root/.lock"

for required_command in git awk grep sed sort find wc shasum mktemp mkdir ln rm rmdir sleep seq tail chmod date cmp basename; do
  command -v "$required_command" >/dev/null 2>&1 || fail "required_command_missing:$required_command"
done
test -f "$contract_file" || fail contract_missing
test "$(shasum -a 256 "$contract_file" | awk '{print $1}')" = "$contract_sha256" \
  || fail contract_hash_mismatch
test -f "$inventory_file" || fail historical_inventory_missing
test "$(shasum -a 256 "$inventory_file" | awk '{print $1}')" = "$inventory_sha256" \
  || fail historical_inventory_hash_mismatch
test -x "$reconciliation" || fail reconciliation_controller_missing

require_run_id() {
  printf '%s\n' "$1" | grep -Eq '^BIP-FR-005-MR-[0-9]{8}T[0-9]{6}Z$' \
    || fail invalid_run_id
}

read_field() {
  local file="$1"
  local key="$2"
  local values count
  values="$(awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$file")"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "$count" -eq 1 || fail "field_missing_or_duplicate:$key:$file"
  printf '%s\n' "$values"
}

require_field() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(read_field "$file" "$key")"
  test "$actual" = "$expected" || fail "binding_mismatch:$key"
}

acquire_lock() {
  mkdir -p "$controller_root" "$index_root"
  local attempt
  for attempt in $(seq 1 "$lock_attempts"); do
    if mkdir "$lock_dir" 2>/dev/null; then
      trap release_lock EXIT INT TERM
      return
    fi
    sleep "$lock_poll_seconds"
  done
  fail controller_lock_timeout
}

release_lock() {
  if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}

clock_read() {
  local line extra
  if [ "$test_mode" = 1 ]; then
    line="$(BIP_FR005_TEST_CLOCK_FILE="${BIP_FR005_TEST_CLOCK_FILE:-}" "$clock_command")" \
      || fail clock_read_failed
  else
    line="$(date -u '+%s %Y%m%dT%H%M%SZ')" || fail clock_read_failed
  fi
  read -r clock_epoch clock_stamp extra <<< "$line"
  test -z "${extra:-}" || fail invalid_clock_reading
  printf '%s\n' "$clock_epoch" | grep -Eq '^[0-9]+$' || fail invalid_clock_epoch
  printf '%s\n' "$clock_stamp" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || fail invalid_clock_stamp
}

stamp_to_utc() {
  local stamp="$1"
  printf '%s-%s-%sT%s:%s:%sZ\n' \
    "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}" \
    "${stamp:9:2}" "${stamp:11:2}" "${stamp:13:2}"
}

atomic_publish_no_replace() {
  local source_file="$1"
  local target_file="$2"
  test ! -e "$target_file" || fail "atomic_target_exists:$target_file"
  if ! ln "$source_file" "$target_file" 2>/dev/null; then
    fail "atomic_publication_conflict:$target_file"
  fi
  rm "$source_file"
  chmod 0444 "$target_file"
}

candidate_file_for() {
  printf '%s/%s/00-environment/candidate-reservation.txt\n' "$evidence_root" "$1"
}

registration_file_for() {
  printf '%s/%s/00-environment/run-registration.txt\n' "$evidence_root" "$1"
}

active_candidate_files() {
  find "$evidence_root" -mindepth 3 -maxdepth 3 -type f \
    -path '*/00-environment/candidate-reservation.txt' -print 2>/dev/null \
    | sort \
    | while IFS= read -r candidate_file; do
        test "$(read_field "$candidate_file" state)" = CANDIDATE_RESERVED || continue
        candidate_run_id="$(read_field "$candidate_file" run_id)"
        registration_file="$(registration_file_for "$candidate_run_id")"
        test ! -e "$registration_file" && printf '%s\n' "$candidate_file"
      done
}

require_single_active_candidate() {
  local expected_run_id="${1:-}"
  local active_files active_count active_file active_run_id
  active_files="$(active_candidate_files)"
  active_count="$(printf '%s\n' "$active_files" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "$active_count" -eq 1 || fail "active_reservation_count:$active_count"
  active_file="$active_files"
  active_run_id="$(read_field "$active_file" run_id)"
  if [ -n "$expected_run_id" ]; then
    test "$active_run_id" = "$expected_run_id" || fail active_reservation_run_id_mismatch
  fi
  printf '%s\n' "$active_file"
}

validate_candidate() {
  local file="$1"
  local expected_run_id="$2"
  test -f "$file" || fail candidate_reservation_missing
  require_run_id "$expected_run_id"
  require_field "$file" run_id "$expected_run_id"
  require_field "$file" state CANDIDATE_RESERVED
  require_field "$file" clock_semantics UTC_WALL_CLOCK_SECOND_AT_SUCCESSFUL_ATOMIC_CANDIDATE_RESERVATION
  require_field "$file" contract_revision "$contract_revision"
  require_field "$file" contract_sha256 "$contract_sha256"
  require_field "$file" implementation_revision "$implementation_revision"
  require_field "$file" preparation_revision "$preparation_revision"
  require_field "$file" baseline_isolation_version "$baseline_isolation_version"
  require_field "$file" historical_residue_inventory_sha256 "$inventory_sha256"
  allocated_epoch="$(read_field "$file" allocated_epoch)"
  allocated_at_utc="$(read_field "$file" allocated_at_utc)"
  printf '%s\n' "$allocated_epoch" | grep -Eq '^[0-9]+$' || fail invalid_allocation_epoch
  id_stamp="${expected_run_id#BIP-FR-005-MR-}"
  test "$allocated_at_utc" = "$(stamp_to_utc "$id_stamp")" || fail allocation_timestamp_mismatch
}

validate_registration() {
  local file="$1"
  local expected_run_id="$2"
  test -f "$file" || fail registration_missing
  require_field "$file" run_id "$expected_run_id"
  require_field "$file" contract_revision "$contract_revision"
  require_field "$file" contract_status FROZEN
  require_field "$file" state REGISTERED
  require_field "$file" execution_state NOT_EXECUTED
  require_field "$file" outcome NOT_ASSIGNED
  require_field "$file" verified_reproduction_claim NONE
  require_field "$file" implementation_revision "$implementation_revision"
  require_field "$file" preparation_revision "$preparation_revision"
  require_field "$file" baseline_isolation_version "$baseline_isolation_version"
  require_field "$file" historical_residue_inventory_sha256 "$inventory_sha256"
  require_field "$file" controller_version "$controller_version"
  read_field "$file" allocated_at_utc >/dev/null
  read_field "$file" registered_at_utc >/dev/null
}

registration_claim_files() {
  local searched_run_id="$1"
  find "$evidence_root" -type f -name run-registration.txt -print 2>/dev/null \
    | while IFS= read -r registration_file; do
        if [ "$(awk -F= '$1 == "run_id" {print $2}' "$registration_file")" = "$searched_run_id" ]; then
          printf '%s\n' "$registration_file"
        fi
      done
}

validate_index() {
  local run_id="$1"
  local registration_file="$2"
  local index_file="$index_root/$run_id.txt"
  test -f "$index_file" || fail registration_index_missing
  require_field "$index_file" run_id "$run_id"
  require_field "$index_file" registration_file "${registration_file#$repo_root/}"
  require_field "$index_file" registration_sha256 \
    "$(shasum -a 256 "$registration_file" | awk '{print $1}')"
}

ensure_index() {
  local run_id="$1"
  local registration_file="$2"
  local index_file="$index_root/$run_id.txt"
  if [ -e "$index_file" ]; then
    validate_index "$run_id" "$registration_file"
    return
  fi
  local index_temp
  index_temp="$(mktemp "$index_root/.registration-index.XXXXXX")"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'registration_file=%s\n' "${registration_file#$repo_root/}"
    printf 'registration_sha256=%s\n' "$(shasum -a 256 "$registration_file" | awk '{print $1}')"
  } > "$index_temp"
  atomic_publish_no_replace "$index_temp" "$index_file"
  validate_index "$run_id" "$registration_file"
}

assert_no_ambiguous_namespace() {
  local run_dir base
  find "$evidence_root" -mindepth 1 -maxdepth 1 -type d -name 'BIP-FR-005-MR-*' -print \
    | while IFS= read -r run_dir; do
        base="$(basename "$run_dir")"
        require_run_id "$base"
        if [ ! -f "$run_dir/00-environment/candidate-reservation.txt" ] \
          && [ ! -f "$run_dir/00-environment/run-registration.txt" ]; then
          fail "ambiguous_run_namespace:$base"
        fi
      done
}

allocate_candidate() {
  test "$#" -eq 1 || usage
  acquire_lock
  assert_no_ambiguous_namespace
  active="$(active_candidate_files)"
  active_count="$(printf '%s\n' "$active" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "$active_count" -eq 0 || fail "active_reservation_exists:$active_count"

  latest_run_id="$(find "$evidence_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'BIP-FR-005-MR-[0-9]*Z' -exec basename {} \; | sort | tail -n 1)"
  previous_epoch=""
  previous_stamp=""
  for poll in $(seq 1 "$max_clock_polls"); do
    clock_read
    candidate_run_id="BIP-FR-005-MR-$clock_stamp"
    require_run_id "$candidate_run_id"
    if [ -n "$previous_epoch" ]; then
      test "$clock_epoch" -ge "$previous_epoch" || fail clock_moved_backward
      if [ "$clock_epoch" -eq "$previous_epoch" ]; then
        test "$clock_stamp" = "$previous_stamp" || fail inconsistent_clock_reading
        test "$poll" -lt "$max_clock_polls" || fail clock_did_not_advance
        sleep "$clock_poll_seconds"
        continue
      fi
      [[ "$clock_stamp" > "$previous_stamp" ]] || fail clock_moved_backward
    fi
    if [ -n "$latest_run_id" ] && [[ "$candidate_run_id" < "$latest_run_id" ]]; then
      fail clock_moved_backward_before_latest_run
    fi

    run_dir="$evidence_root/$candidate_run_id"
    if ! mkdir "$run_dir" 2>/dev/null; then
      previous_epoch="$clock_epoch"
      previous_stamp="$clock_stamp"
      test "$poll" -lt "$max_clock_polls" || fail clock_did_not_advance
      sleep "$clock_poll_seconds"
      continue
    fi

    mkdir "$run_dir/00-environment"
    candidate_file="$run_dir/00-environment/candidate-reservation.txt"
    temp_file="$(mktemp "$run_dir/00-environment/.candidate-reservation.XXXXXX")"
    allocated_at_utc="$(stamp_to_utc "$clock_stamp")"
    {
      printf 'run_id=%s\n' "$candidate_run_id"
      printf 'state=CANDIDATE_RESERVED\n'
      printf 'allocated_at_utc=%s\nallocated_epoch=%s\n' "$allocated_at_utc" "$clock_epoch"
      printf 'clock_semantics=UTC_WALL_CLOCK_SECOND_AT_SUCCESSFUL_ATOMIC_CANDIDATE_RESERVATION\n'
      printf 'contract_revision=%s\ncontract_sha256=%s\n' "$contract_revision" "$contract_sha256"
      printf 'implementation_revision=%s\npreparation_revision=%s\n' "$implementation_revision" "$preparation_revision"
      printf 'baseline_isolation_version=%s\n' "$baseline_isolation_version"
      printf 'historical_residue_inventory_sha256=%s\n' "$inventory_sha256"
      printf 'controller_version=%s\n' "$controller_version"
    } > "$temp_file"
    validate_candidate "$temp_file" "$candidate_run_id"
    atomic_publish_no_replace "$temp_file" "$candidate_file"
    printf 'run_id=%s\nstate=CANDIDATE_RESERVED\nallocated_at_utc=%s\nCONTROLLER_RESULT=PASS\n' \
      "$candidate_run_id" "$allocated_at_utc"
    return
  done
  fail allocation_blocked
}

resume_candidate() {
  test "$#" -eq 1 || usage
  acquire_lock
  assert_no_ambiguous_namespace
  candidate_file="$(require_single_active_candidate)"
  run_id="$(read_field "$candidate_file" run_id)"
  validate_candidate "$candidate_file" "$run_id"
  claims="$(registration_claim_files "$run_id")"
  test -z "$claims" || fail conflicting_registration_exists
  test ! -e "$index_root/$run_id.txt" || fail conflicting_registration_index
  printf 'run_id=%s\nstate=CANDIDATE_RESERVED\nresume=PASS\nCONTROLLER_RESULT=PASS\n' "$run_id"
}

register_candidate() {
  test "$#" -eq 2 || usage
  run_id="$2"
  require_run_id "$run_id"
  acquire_lock
  assert_no_ambiguous_namespace
  run_dir="$evidence_root/$run_id"
  candidate_file="$(candidate_file_for "$run_id")"
  registration_file="$(registration_file_for "$run_id")"

  claims="$(registration_claim_files "$run_id")"
  claim_count="$(printf '%s\n' "$claims" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$claim_count" -gt 0 ]; then
    test "$claim_count" -eq 1 || fail DUPLICATE_REGISTRATION_CONFLICT
    test "$claims" = "$registration_file" || fail DUPLICATE_REGISTRATION_CONFLICT
    if ! (
      validate_candidate "$candidate_file" "$run_id"
      validate_registration "$registration_file" "$run_id"
      test ! -e "$index_root/$run_id.txt" || validate_index "$run_id" "$registration_file"
    ); then
      fail DUPLICATE_REGISTRATION_CONFLICT
    fi
    ensure_index "$run_id" "$registration_file"
    printf 'run_id=%s\nstate=REGISTERED\nregistration=EXISTING_IDENTICAL\nCONTROLLER_RESULT=PASS\n' "$run_id"
    return
  fi

  active_file="$(require_single_active_candidate "$run_id")"
  test "$active_file" = "$candidate_file" || fail active_candidate_path_mismatch
  validate_candidate "$candidate_file" "$run_id"
  test ! -e "$index_root/$run_id.txt" || fail DUPLICATE_REGISTRATION_CONFLICT

  cohort_file="$run_dir/00-environment/cohort.tsv"
  entry_dir="$run_dir/01-entry-baseline"
  for required_file in "$cohort_file" "$entry_dir/baseline-watermarks.tsv" \
    "$entry_dir/observed-residue.tsv" "$entry_dir/successor-identity-state.tsv" \
    "$entry_dir/runtime-metrics.tsv"; do
    test -f "$required_file" || fail "registration_prerequisite_missing:$required_file"
  done

  reconciliation_temp="$(mktemp "$entry_dir/.baseline-reconciliation.XXXXXX")"
  if ! "$reconciliation" \
    --run-id "$run_id" \
    --cohort "$cohort_file" \
    --registered-watermarks "$entry_dir/baseline-watermarks.tsv" \
    --observed-watermarks "$entry_dir/baseline-watermarks.tsv" \
    --observed-residue "$entry_dir/observed-residue.tsv" \
    --identity-state "$entry_dir/successor-identity-state.tsv" \
    --runtime-metrics "$entry_dir/runtime-metrics.tsv" > "$reconciliation_temp"; then
    rm -f "$reconciliation_temp"
    fail baseline_reconciliation_failed
  fi
  grep -Fx 'SUCCESSOR_BASELINE_RECONCILIATION=PASS' "$reconciliation_temp" >/dev/null \
    || fail baseline_reconciliation_marker_missing
  reconciliation_file="$entry_dir/baseline-reconciliation.txt"
  if [ -e "$reconciliation_file" ]; then
    cmp -s "$reconciliation_temp" "$reconciliation_file" \
      || fail baseline_reconciliation_conflict
    rm "$reconciliation_temp"
  else
    atomic_publish_no_replace "$reconciliation_temp" "$reconciliation_file"
  fi

  clock_read
  registered_at_utc="$(stamp_to_utc "$clock_stamp")"
  allocated_at_utc="$(read_field "$candidate_file" allocated_at_utc)"
  registration_temp="$(mktemp "$run_dir/00-environment/.run-registration.XXXXXX")"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'contract_revision=%s\ncontract_status=FROZEN\n' "$contract_revision"
    printf 'state=REGISTERED\nexecution_state=NOT_EXECUTED\noutcome=NOT_ASSIGNED\nverified_reproduction_claim=NONE\n'
    printf 'allocated_at_utc=%s\nregistered_at_utc=%s\n' "$allocated_at_utc" "$registered_at_utc"
    printf 'implementation_revision=%s\npreparation_revision=%s\n' "$implementation_revision" "$preparation_revision"
    printf 'baseline_isolation_version=%s\n' "$baseline_isolation_version"
    printf 'historical_residue_inventory_sha256=%s\n' "$inventory_sha256"
    printf 'contract_sha256=%s\ncontroller_version=%s\n' "$contract_sha256" "$controller_version"
  } > "$registration_temp"
  validate_registration "$registration_temp" "$run_id"
  atomic_publish_no_replace "$registration_temp" "$registration_file"

  ensure_index "$run_id" "$registration_file"

  printf 'run_id=%s\nstate=REGISTERED\nexecution_state=NOT_EXECUTED\noutcome=NOT_ASSIGNED\n' "$run_id"
  printf 'registered_at_utc=%s\nexecution_eligibility=BLOCKED\nreason=SYNCHRONIZATION_BLOCKED\n' "$registered_at_utc"
  printf 'CONTROLLER_RESULT=PASS\n'
}

check_eligibility() {
  test "$#" -eq 2 || usage
  run_id="$2"
  require_run_id "$run_id"
  registration_file="$(registration_file_for "$run_id")"
  claims="$(registration_claim_files "$run_id")"
  claim_count="$(printf '%s\n' "$claims" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "$claim_count" -eq 1 || fail DUPLICATE_REGISTRATION_CONFLICT
  test "$claims" = "$registration_file" || fail DUPLICATE_REGISTRATION_CONFLICT
  validate_registration "$registration_file" "$run_id"
  validate_index "$run_id" "$registration_file"

  synchronized=0
  if [ "$test_mode" = 1 ]; then
    synchronized="${BIP_FR005_TEST_SYNCHRONIZED:-0}"
  else
    registration_rel="${registration_file#$repo_root/}"
    index_rel="${index_root#$repo_root/}/$run_id.txt"
    if git ls-files --error-unmatch "$registration_rel" "$index_rel" >/dev/null 2>&1 \
      && test -z "$(git status --porcelain --untracked-files=all)" \
      && upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
      && test "$(git rev-parse HEAD)" = "$(git rev-parse "$upstream")"; then
      synchronized=1
    fi
  fi

  if [ "$synchronized" != 1 ]; then
    printf 'run_id=%s\nstate=REGISTERED\nexecution_eligibility=BLOCKED\nreason=SYNCHRONIZATION_BLOCKED\n' "$run_id"
    exit 1
  fi
  printf 'run_id=%s\nstate=REGISTERED\nsynchronization=PASS\nexecution_eligibility=ELIGIBLE_FOR_PREFLIGHT\nCONTROLLER_RESULT=PASS\n' "$run_id"
}

case "$command_name" in
  allocate) allocate_candidate "$@" ;;
  resume) resume_candidate "$@" ;;
  register) register_candidate "$@" ;;
  eligibility) check_eligibility "$@" ;;
  *) usage ;;
esac
