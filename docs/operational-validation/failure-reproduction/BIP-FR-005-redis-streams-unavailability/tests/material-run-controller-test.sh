#!/usr/bin/env bash

set -euo pipefail

scenario_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_docker="$scenario_dir/tests/fake-docker"
controller="$scenario_dir/material-run-controller.sh"
fixture_run_id="BIP-FR-005-MR-20990101T000000Z"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/bip-fr-005-controller-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
cp "$fixture_docker" "$test_dir/bin/docker"
chmod +x "$test_dir/bin/docker"

run_rejected_case() {
  local mode="$1"
  local expected_predicate="$2"
  local output="$test_dir/$mode.out"
  local action_log="$test_dir/$mode.actions"

  if PATH="$test_dir/bin:$PATH" BIP_FAKE_MODE="$mode" BIP_FAKE_ACTION_LOG="$action_log" \
    "$controller" "$fixture_run_id" enter-redis-fault --apply >"$output" 2>&1; then
    echo "expected rejected transition for mode=$mode" >&2
    exit 1
  fi

  grep -F "failed_predicate=$expected_predicate" "$output" >/dev/null
  grep -Fx 'transition=ENTER_REDIS_FAULT_REJECTED' "$output" >/dev/null
  grep -Fx 'execution_state=ABORTED' "$output" >/dev/null
  grep -Fx 'redis_fault_action=NOT_EXECUTED' "$output" >/dev/null
  test ! -s "$action_log"
}

run_rejected_case oom 'required_broker_oom:bip-fr-002-broker-3'
run_rejected_case exited 'required_broker_not_running:bip-fr-002-broker-3:exited'
run_rejected_case unhealthy 'required_broker_not_healthy:bip-fr-002-broker-3:unhealthy'
run_rejected_case urp 'kafka_under_replicated_partitions:barcode-events'
run_rejected_case unavailable 'kafka_unavailable_partitions:barcode-events'
run_rejected_case isr 'kafka_required_isr_mismatch:barcode-events'

pass_output="$test_dir/pass.out"
pass_action_log="$test_dir/pass.actions"
PATH="$test_dir/bin:$PATH" BIP_FAKE_MODE=pass BIP_FAKE_ACTION_LOG="$pass_action_log" \
  "$controller" "$fixture_run_id" enter-redis-fault --apply >"$pass_output" 2>&1
grep -Fx 'PRE_FAULT_GATE=PASS' "$pass_output" >/dev/null
grep -Fx 'transition=ENTER_REDIS_FAULT_PERMITTED' "$pass_output" >/dev/null
grep -Fx 'redis_fault_action=EXECUTED' "$pass_output" >/dev/null
grep -Fx 'stop --timeout 10 bip-fr-002-redis' "$pass_action_log" >/dev/null

echo 'MATERIAL_RUN_CONTROLLER_TEST=PASS'
