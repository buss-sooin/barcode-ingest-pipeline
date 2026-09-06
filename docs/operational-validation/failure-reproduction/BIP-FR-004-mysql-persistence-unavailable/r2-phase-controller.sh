#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root="${BIP_FR004_REPOSITORY_ROOT:-$(git -C "$script_dir" rev-parse --show-toplevel)}"
controller_root="${BIP_FR004_CONTROLLER_ROOT:-$script_dir/evidence}"
docker_command="${BIP_FR004_DOCKER_COMMAND:-docker}"
baseline_max_age_seconds="${BIP_FR004_BASELINE_MAX_AGE_SECONDS:-600}"
traffic_freshness_seconds="${BIP_FR004_TRAFFIC_FRESHNESS_SECONDS:-30}"
reclaim_timeout_seconds="${BIP_FR004_RECLAIM_TIMEOUT_SECONDS:-420}"
expected_branch="validation/bip-fr-004-mysql-persistence-unavailable"
expected_contract="BIP-FR-004-RC-R2"

usage() {
  cat >&2 <<'USAGE'
usage:
  r2-phase-controller.sh register <run-id> approved_head=<sha> gate_reference=<ref> contract_file=<path>
  r2-phase-controller.sh start <run-id> <phase> [key=value ...]
  r2-phase-controller.sh finish <run-id> <phase> <PASS|FAIL|STOP> [key=value ...]
  r2-phase-controller.sh status <run-id>

phases:
  baseline traffic-pre traffic-fault mysql-stop observe-outage mysql-start
  traffic-post observe-reclaim reconcile
USAGE
  exit 2
}

fail() {
  printf 'CONTROLLER_RESULT=STOP reason=%s\n' "$*" >&2
  exit 1
}

require_run_id() {
  case "$1" in
    BIP-FR-004-MR-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) fail "invalid_run_id" ;;
  esac
}

require_phase() {
  case "$1" in
    baseline|traffic-pre|traffic-fault|mysql-stop|observe-outage|mysql-start|traffic-post|observe-reclaim|reconcile) ;;
    *) fail "invalid_phase:$1" ;;
  esac
}

predecessor() {
  case "$1" in
    baseline) printf 'register\n' ;;
    traffic-pre) printf 'baseline\n' ;;
    traffic-fault) printf 'traffic-pre\n' ;;
    mysql-stop) printf 'traffic-fault\n' ;;
    observe-outage) printf 'mysql-stop\n' ;;
    mysql-start) printf 'observe-outage\n' ;;
    traffic-post) printf 'mysql-start\n' ;;
    observe-reclaim) printf 'traffic-post\n' ;;
    reconcile) printf 'observe-reclaim\n' ;;
  esac
}

arg_value() {
  requested_key="$1"
  shift
  for pair in "$@"; do
    case "$pair" in
      "$requested_key"=*) printf '%s\n' "${pair#*=}"; return 0 ;;
    esac
  done
  return 1
}

require_arg() {
  value="$(arg_value "$@" || true)"
  test -n "$value" || fail "missing_argument:$1"
  printf '%s\n' "$value"
}

safe_key() {
  case "$1" in
    *[!a-z0-9_-]*|'') fail "invalid_state_key:$1" ;;
  esac
}

write_state() {
  key="$1"
  value="$2"
  safe_key "$key"
  test "${value#*$'\n'}" = "$value" || fail "multiline_state_value:$key"
  printf '%s\n' "$value" >"$state_dir/$key"
}

read_state() {
  key="$1"
  safe_key "$key"
  test -f "$state_dir/$key" || return 1
  sed -n '1p' "$state_dir/$key"
}

require_file() {
  label="$1"
  file="$2"
  test -f "$file" || fail "missing_${label}:$file"
}

phase_status() {
  phase="$1"
  file="$state_dir/phases/$phase/status"
  test -f "$file" || return 1
  sed -n '1p' "$file"
}

append_event() {
  action="$1"
  phase="$2"
  result="$3"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$action" "$phase" "$result" \
    >>"$state_dir/events.tsv"
}

acquire_lock() {
  lock_dir="$state_dir/.lock"
  mkdir "$lock_dir" 2>/dev/null || fail "controller_locked"
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM
}

assert_repository_identity() {
  approved_head="$1"
  test "$(git -C "$repository_root" branch --show-current)" = "$expected_branch" \
    || fail "unexpected_branch"
  test "$(git -C "$repository_root" rev-parse HEAD)" = "$approved_head" \
    || fail "approved_head_mismatch"
  test -z "$(git -C "$repository_root" status --porcelain=v1)" \
    || fail "working_tree_not_clean"
}

assert_registered_repository_unchanged() {
  test "$(git -C "$repository_root" branch --show-current)" = "$expected_branch" \
    || fail "unexpected_branch"
  test "$(git -C "$repository_root" rev-parse HEAD)" = "$(read_state approved_head)" \
    || fail "approved_head_mismatch"
  git -C "$repository_root" diff --quiet || fail "tracked_working_tree_changed"
  git -C "$repository_root" diff --cached --quiet || fail "index_changed"
}

inspect_mysql() {
  container_id="$1"
  "$docker_command" inspect --format '{{.Id}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id"
}

require_mysql_state() {
  expected_status="$1"
  expected_health="${2:-}"
  expected_id="$(read_state mysql_container_id || true)"
  test -n "$expected_id" || fail "mysql_container_identity_missing"
  inspection="$(inspect_mysql "$expected_id" 2>/dev/null || true)"
  test -n "$inspection" || fail "mysql_container_not_inspectable"
  actual_id="${inspection%%|*}"
  remainder="${inspection#*|}"
  actual_status="${remainder%%|*}"
  actual_health="${remainder#*|}"
  test "$actual_id" = "$expected_id" || fail "mysql_container_identity_changed"
  test "$actual_status" = "$expected_status" || fail "mysql_status_expected_${expected_status}_actual_${actual_status}"
  if [ -n "$expected_health" ]; then
    test "$actual_health" = "$expected_health" \
      || fail "mysql_health_expected_${expected_health}_actual_${actual_health}"
  fi
}

require_active_traffic() {
  traffic_pid="$(read_state traffic_pid || true)"
  traffic_log="$(read_state traffic_log || true)"
  test -n "$traffic_pid" || fail "traffic_pid_missing"
  case "$traffic_pid" in *[!0-9]*|'') fail "invalid_traffic_pid" ;; esac
  require_file traffic_log "$traffic_log"
  kill -0 "$traffic_pid" 2>/dev/null || fail "traffic_not_active"
  ps -p "$traffic_pid" -o command= | grep -F 'traffic-driver.sh' >/dev/null \
    || fail "traffic_pid_not_driver"
  grep -F "DRIVER_START phase=$run_id " "$traffic_log" >/dev/null \
    || fail "traffic_log_run_id_mismatch"
  now_epoch="$(date +%s)"
  log_epoch="$(stat -f '%m' "$traffic_log")"
  test "$((now_epoch - log_epoch))" -le "$traffic_freshness_seconds" \
    || fail "traffic_evidence_stale"
}

require_fresh_baseline() {
  baseline_epoch="$(read_state baseline_completed_epoch || true)"
  test -n "$baseline_epoch" || fail "baseline_timestamp_missing"
  now_epoch="$(date +%s)"
  test "$((now_epoch - baseline_epoch))" -le "$baseline_max_age_seconds" \
    || fail "stale_baseline"
}

validate_start_preconditions() {
  phase="$1"
  shift

  case "$phase" in
    baseline)
      preflight_file="$(require_arg preflight_file "$@")"
      require_file preflight "$preflight_file"
      grep -F 'RESOURCE_PREFLIGHT=PASS' "$preflight_file" >/dev/null \
        || fail "preflight_not_pass"
      ;;
    traffic-pre)
      require_fresh_baseline
      ;;
    traffic-fault)
      require_fresh_baseline
      require_active_traffic
      ;;
    mysql-stop)
      require_fresh_baseline
      require_active_traffic
      supplied_id="$(require_arg mysql_container_id "$@")"
      test "$supplied_id" = "$(read_state mysql_container_id)" \
        || fail "mysql_stop_target_mismatch"
      require_mysql_state running healthy
      ;;
    observe-outage)
      require_mysql_state exited
      ;;
    mysql-start)
      require_mysql_state exited
      ;;
    traffic-post)
      require_active_traffic
      write_state traffic_post_start_lines "$(wc -l <"$(read_state traffic_log)" | tr -d ' ')"
      ;;
    observe-reclaim)
      write_state reclaim_deadline_epoch "$(( $(date +%s) + reclaim_timeout_seconds ))"
      ;;
    reconcile)
      for evidence_key in baseline_evidence traffic_log mysql_stop_evidence outage_evidence pending_evidence mysql_recovery_evidence traffic_post_evidence reclaim_evidence; do
        evidence_path="$(read_state "$evidence_key" || true)"
        test -n "$evidence_path" || fail "required_evidence_locator_missing:$evidence_key"
        require_file "$evidence_key" "$evidence_path"
      done
      ;;
  esac
}

validate_finish_pass() {
  phase="$1"
  shift

  case "$phase" in
    baseline)
      baseline_evidence="$(require_arg baseline_evidence "$@")"
      mysql_container_id="$(require_arg mysql_container_id "$@")"
      require_file baseline_evidence "$baseline_evidence"
      write_state baseline_evidence "$baseline_evidence"
      write_state mysql_container_id "$mysql_container_id"
      write_state baseline_completed_epoch "$(date +%s)"
      require_mysql_state running healthy
      ;;
    traffic-pre|traffic-fault)
      traffic_pid="$(require_arg traffic_pid "$@")"
      traffic_log="$(require_arg traffic_log "$@")"
      write_state traffic_pid "$traffic_pid"
      write_state traffic_log "$traffic_log"
      require_active_traffic
      ;;
    mysql-stop)
      mysql_stop_evidence="$(require_arg mysql_stop_evidence "$@")"
      require_file mysql_stop_evidence "$mysql_stop_evidence"
      write_state mysql_stop_evidence "$mysql_stop_evidence"
      require_mysql_state exited
      ;;
    observe-outage)
      outage_evidence="$(require_arg outage_evidence "$@")"
      pending_evidence="$(require_arg pending_evidence "$@")"
      require_file outage_evidence "$outage_evidence"
      require_file pending_evidence "$pending_evidence"
      write_state outage_evidence "$outage_evidence"
      write_state pending_evidence "$pending_evidence"
      require_mysql_state exited
      ;;
    mysql-start)
      recovered_id="$(require_arg mysql_container_id "$@")"
      mysql_recovery_evidence="$(require_arg mysql_recovery_evidence "$@")"
      test "$recovered_id" = "$(read_state mysql_container_id)" \
        || fail "mysql_recovery_container_mismatch"
      require_file mysql_recovery_evidence "$mysql_recovery_evidence"
      write_state mysql_recovery_evidence "$mysql_recovery_evidence"
      require_mysql_state running healthy
      ;;
    traffic-post)
      traffic_post_evidence="$(require_arg traffic_post_evidence "$@")"
      require_file traffic_post_evidence "$traffic_post_evidence"
      current_lines="$(wc -l <"$(read_state traffic_log)" | tr -d ' ')"
      start_lines="$(read_state traffic_post_start_lines)"
      test "$current_lines" -gt "$start_lines" || fail "post_recovery_traffic_not_observed"
      grep -F 'DRIVER_EVENT ' "$traffic_post_evidence" >/dev/null \
        || fail "post_recovery_traffic_evidence_invalid"
      write_state traffic_post_evidence "$traffic_post_evidence"
      ;;
    observe-reclaim)
      reclaim_evidence="$(require_arg reclaim_evidence "$@")"
      require_file reclaim_evidence "$reclaim_evidence"
      test "$(date +%s)" -le "$(read_state reclaim_deadline_epoch)" \
        || fail "reclaim_observation_timeout"
      grep -E '(^|[[:space:]])pending=0($|[[:space:]])' "$reclaim_evidence" >/dev/null \
        || fail "pending_not_zero"
      write_state reclaim_evidence "$reclaim_evidence"
      ;;
    reconcile)
      reconciliation_evidence="$(require_arg reconciliation_evidence "$@")"
      require_file reconciliation_evidence "$reconciliation_evidence"
      grep -E '(^|[[:space:]])unaccounted=0($|[[:space:]])' "$reconciliation_evidence" >/dev/null \
        || fail "unaccounted_not_zero"
      grep -E '(^|[[:space:]])multi_state_conflict=0($|[[:space:]])' "$reconciliation_evidence" >/dev/null \
        || fail "multi_state_conflict_not_zero"
      grep -E '(^|[[:space:]])pending=0($|[[:space:]])' "$reconciliation_evidence" >/dev/null \
        || fail "reconciliation_pending_not_zero"
      write_state reconciliation_evidence "$reconciliation_evidence"
      ;;
  esac
}

command="${1:-}"
run_id="${2:-}"
test -n "$command" && test -n "$run_id" || usage
require_run_id "$run_id"
state_dir="$controller_root/$run_id/controller"

case "$command" in
  register)
    test "$#" -ge 4 || usage
    test ! -e "$state_dir" || fail "run_already_registered"
    approved_head="$(require_arg approved_head "${@:3}")"
    gate_reference="$(require_arg gate_reference "${@:3}")"
    contract_file="$(require_arg contract_file "${@:3}")"
    case "$approved_head" in *[!0-9a-f]*|'') fail "invalid_approved_head" ;; esac
    test "${#approved_head}" -eq 40 || fail "invalid_approved_head"
    assert_repository_identity "$approved_head"
    case "$contract_file" in
      /*) resolved_contract_file="$contract_file" ;;
      *) resolved_contract_file="$repository_root/$contract_file" ;;
    esac
    case "$resolved_contract_file" in
      "$repository_root"/*) ;;
      *) fail "contract_outside_repository" ;;
    esac
    require_file contract "$resolved_contract_file"
    grep -F "$expected_contract" "$resolved_contract_file" >/dev/null \
      || fail "contract_revision_mismatch"
    mkdir -p "$state_dir/phases/register"
    write_state run_id "$run_id"
    write_state contract_revision "$expected_contract"
    write_state approved_head "$approved_head"
    write_state gate_reference "$gate_reference"
    write_state contract_file "$resolved_contract_file"
    write_state contract_sha256 "$(shasum -a 256 "$resolved_contract_file" | awk '{print $1}')"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/phases/register/start_utc"
    cp "$state_dir/phases/register/start_utc" "$state_dir/phases/register/end_utc"
    printf 'PASS\n' >"$state_dir/phases/register/status"
    printf 'utc\trun_id\taction\tphase\tresult\n' >"$state_dir/events.tsv"
    append_event finish register PASS
    printf 'CONTROLLER_RESULT=PASS run_id=%s phase=register next=baseline\n' "$run_id"
    ;;
  start)
    test "$#" -ge 3 || usage
    phase="$3"
    require_phase "$phase"
    test -d "$state_dir" || fail "run_not_registered"
    acquire_lock
    assert_registered_repository_unchanged
    predecessor_phase="$(predecessor "$phase")"
    test "$(phase_status "$predecessor_phase" || true)" = "PASS" \
      || fail "predecessor_not_pass:$predecessor_phase"
    test ! -e "$state_dir/phases/$phase" || fail "phase_already_started:$phase"
    validate_start_preconditions "$phase" "${@:4}"
    mkdir -p "$state_dir/phases/$phase"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/phases/$phase/start_utc"
    printf 'STARTED\n' >"$state_dir/phases/$phase/status"
    append_event start "$phase" STARTED
    printf 'CONTROLLER_RESULT=PASS run_id=%s phase=%s state=STARTED\n' "$run_id" "$phase"
    ;;
  finish)
    test "$#" -ge 5 || usage
    phase="$3"
    result="$4"
    require_phase "$phase"
    case "$result" in PASS|FAIL|STOP) ;; *) fail "invalid_phase_result:$result" ;; esac
    test -d "$state_dir" || fail "run_not_registered"
    acquire_lock
    assert_registered_repository_unchanged
    test "$(phase_status "$phase" || true)" = "STARTED" || fail "phase_not_started:$phase"
    if [ "$result" = "PASS" ]; then
      validate_finish_pass "$phase" "${@:5}"
    fi
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/phases/$phase/end_utc"
    printf '%s\n' "$result" >"$state_dir/phases/$phase/status"
    append_event finish "$phase" "$result"
    printf 'CONTROLLER_RESULT=PASS run_id=%s phase=%s state=%s\n' "$run_id" "$phase" "$result"
    ;;
  status)
    test -d "$state_dir" || fail "run_not_registered"
    printf 'run_id=%s\ncontract_revision=%s\napproved_head=%s\ngate_reference=%s\n' \
      "$run_id" "$(read_state contract_revision)" "$(read_state approved_head)" "$(read_state gate_reference)"
    for phase in register baseline traffic-pre traffic-fault mysql-stop observe-outage mysql-start traffic-post observe-reclaim reconcile; do
      printf 'phase=%s status=%s\n' "$phase" "$(phase_status "$phase" || printf 'NOT_STARTED')"
    done
    ;;
  *) usage ;;
esac
