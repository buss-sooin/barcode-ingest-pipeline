#!/usr/bin/env bash

set -euo pipefail

scenario_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
controller="$scenario_dir/r2-phase-controller.sh"
test_root="$(mktemp -d)"
traffic_pid=""

cleanup() {
  if [ -n "$traffic_pid" ]; then
    kill "$traffic_pid" 2>/dev/null || true
    wait "$traffic_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

test_repo="$test_root/repository"
controller_root="$test_root/controller-root"
mkdir -p "$test_repo" "$controller_root"
git -C "$test_repo" init -q
git -C "$test_repo" checkout -q -b validation/bip-fr-004-mysql-persistence-unavailable
git -C "$test_repo" config user.name test
git -C "$test_repo" config user.email test@example.invalid
printf 'fixture\n' >"$test_repo/fixture.txt"
printf 'Contract Revision: BIP-FR-004-RC-R2\n' >"$test_repo/R2-CONTRACT.md"
git -C "$test_repo" add fixture.txt R2-CONTRACT.md
git -C "$test_repo" commit -q -m fixture
approved_head="$(git -C "$test_repo" rev-parse HEAD)"

mysql_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
docker_state="$test_root/docker-state"
printf 'running\n' >"$docker_state"
fake_docker="$test_root/fake-docker"
cat >"$fake_docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = "inspect"
shift
if [ "$1" = "--format" ]; then
  shift 2
fi
test "$1" = "$FAKE_MYSQL_ID"
printf '%s|%s|healthy\n' "$FAKE_MYSQL_ID" "$(sed -n '1p' "$FAKE_DOCKER_STATE")"
FAKE_DOCKER
chmod +x "$fake_docker"

traffic_helper="$test_root/traffic-driver.sh"
cat >"$traffic_helper" <<'TRAFFIC_HELPER'
#!/usr/bin/env bash
sleep 300
TRAFFIC_HELPER
chmod +x "$traffic_helper"
"$traffic_helper" &
traffic_pid=$!

run_controller() {
  BIP_FR004_REPOSITORY_ROOT="$test_repo" \
  BIP_FR004_CONTROLLER_ROOT="$controller_root" \
  BIP_FR004_DOCKER_COMMAND="$fake_docker" \
  FAKE_MYSQL_ID="$mysql_id" \
  FAKE_DOCKER_STATE="$docker_state" \
  "$controller" "$@"
}

expect_stop() {
  if run_controller "$@" >"$test_root/expected-stop.out" 2>&1; then
    printf 'expected STOP but command passed: %s\n' "$*" >&2
    exit 1
  fi
  grep -F 'CONTROLLER_RESULT=STOP' "$test_root/expected-stop.out" >/dev/null
}

touch_evidence() {
  file="$1"
  content="$2"
  printf '%s\n' "$content" >"$file"
}

run_id="BIP-FR-004-MR-20260906T010101Z"
preflight="$test_root/preflight.txt"
baseline="$test_root/baseline.txt"
traffic_log="$test_root/traffic.log"
mysql_stop="$test_root/mysql-stop.txt"
outage="$test_root/outage.txt"
pending="$test_root/pending.txt"
mysql_recovery="$test_root/mysql-recovery.txt"
reclaim="$test_root/reclaim.txt"
reconciliation="$test_root/reconciliation.txt"

touch_evidence "$preflight" 'RESOURCE_PREFLIGHT=PASS'
touch_evidence "$baseline" 'baseline=healthy'
touch_evidence "$traffic_log" "DRIVER_START phase=$run_id started_at=2026-09-06T01:01:01Z"
touch_evidence "$mysql_stop" 'mysql_status=exited'
touch_evidence "$outage" 'mysql_available=false'
touch_evidence "$pending" 'pending=136'
touch_evidence "$mysql_recovery" 'mysql_status=running'
touch_evidence "$reclaim" 'pending=0'
touch_evidence "$reconciliation" 'unaccounted=0 multi_state_conflict=0 pending=0'

expect_stop register INVALID-RUN approved_head="$approved_head" gate_reference=gate contract_file=R2-CONTRACT.md
run_controller register "$run_id" approved_head="$approved_head" gate_reference=human-gate-r2 \
  contract_file=R2-CONTRACT.md >/dev/null
expect_stop start "$run_id" traffic-pre

run_controller start "$run_id" baseline preflight_file="$preflight" >/dev/null
run_controller finish "$run_id" baseline PASS \
  baseline_evidence="$baseline" mysql_container_id="$mysql_id" >/dev/null
run_controller start "$run_id" traffic-pre >/dev/null
run_controller finish "$run_id" traffic-pre PASS \
  traffic_pid="$traffic_pid" traffic_log="$traffic_log" >/dev/null
run_controller start "$run_id" traffic-fault >/dev/null
printf 'DRIVER_EVENT phase=%s sequence=1\n' "$run_id" >>"$traffic_log"
run_controller finish "$run_id" traffic-fault PASS \
  traffic_pid="$traffic_pid" traffic_log="$traffic_log" >/dev/null

expect_stop start "$run_id" mysql-stop mysql_container_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run_controller start "$run_id" mysql-stop mysql_container_id="$mysql_id" >/dev/null
printf 'exited\n' >"$docker_state"
run_controller finish "$run_id" mysql-stop PASS mysql_stop_evidence="$mysql_stop" >/dev/null
run_controller start "$run_id" observe-outage >/dev/null
run_controller finish "$run_id" observe-outage PASS \
  outage_evidence="$outage" pending_evidence="$pending" >/dev/null
run_controller start "$run_id" mysql-start >/dev/null
printf 'running\n' >"$docker_state"
expect_stop finish "$run_id" mysql-start PASS \
  mysql_container_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  mysql_recovery_evidence="$mysql_recovery"
run_controller finish "$run_id" mysql-start PASS \
  mysql_container_id="$mysql_id" mysql_recovery_evidence="$mysql_recovery" >/dev/null

run_controller start "$run_id" traffic-post >/dev/null
expect_stop finish "$run_id" traffic-post PASS traffic_post_evidence="$traffic_log"
printf 'DRIVER_EVENT phase=%s sequence=2\n' "$run_id" >>"$traffic_log"
run_controller finish "$run_id" traffic-post PASS traffic_post_evidence="$traffic_log" >/dev/null
run_controller start "$run_id" observe-reclaim >/dev/null
printf '0\n' >"$controller_root/$run_id/controller/reclaim_deadline_epoch"
expect_stop finish "$run_id" observe-reclaim PASS reclaim_evidence="$reclaim"
printf '%s\n' "$(( $(date +%s) + 420 ))" \
  >"$controller_root/$run_id/controller/reclaim_deadline_epoch"
run_controller finish "$run_id" observe-reclaim PASS reclaim_evidence="$reclaim" >/dev/null

mv "$reclaim" "$reclaim.missing"
expect_stop start "$run_id" reconcile
mv "$reclaim.missing" "$reclaim"
run_controller start "$run_id" reconcile >/dev/null
run_controller finish "$run_id" reconcile PASS reconciliation_evidence="$reconciliation" >/dev/null
run_controller status "$run_id" | grep -F 'phase=reconcile status=PASS' >/dev/null

stale_run_id="BIP-FR-004-MR-20260906T020202Z"
run_controller register "$stale_run_id" approved_head="$approved_head" gate_reference=human-gate-r2 \
  contract_file=R2-CONTRACT.md >/dev/null
run_controller start "$stale_run_id" baseline preflight_file="$preflight" >/dev/null
run_controller finish "$stale_run_id" baseline PASS \
  baseline_evidence="$baseline" mysql_container_id="$mysql_id" >/dev/null
if BIP_FR004_BASELINE_MAX_AGE_SECONDS=-1 run_controller start "$stale_run_id" traffic-pre \
    >"$test_root/stale.out" 2>&1; then
  echo 'stale baseline unexpectedly accepted' >&2
  exit 1
fi
grep -F 'reason=stale_baseline' "$test_root/stale.out" >/dev/null

printf 'R2_PHASE_CONTROLLER_TEST=PASS\n'
