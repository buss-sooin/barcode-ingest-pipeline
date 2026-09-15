#!/usr/bin/env bash

set -euo pipefail

scenario_dir="$(cd "$(dirname "$0")/.." && pwd)"
controller="$scenario_dir/successor-registration-controller-v1.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/bip-fr-005-registration-controller-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

clock_command="$test_root/clock.sh"
cat > "$clock_command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
clock_file="${BIP_FR005_TEST_CLOCK_FILE:?}"
lock="$clock_file.lock"
for attempt in $(seq 1 100); do
  if mkdir "$lock" 2>/dev/null; then break; fi
  test "$attempt" -lt 100
  sleep 0.01
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
line="$(sed -n '1p' "$clock_file")"
test -n "$line"
sed '1d' "$clock_file" > "$clock_file.next"
mv "$clock_file.next" "$clock_file"
printf '%s\n' "$line"
EOF
chmod +x "$clock_command"

run_controller() {
  local evidence_root="$1"
  local clock_file="$2"
  shift 2
  BIP_FR005_CONTROLLER_TEST_MODE=1 \
  BIP_FR005_TEST_EVIDENCE_ROOT="$evidence_root" \
  BIP_FR005_TEST_CLOCK_COMMAND="$clock_command" \
  BIP_FR005_TEST_CLOCK_FILE="$clock_file" \
  "$controller" "$@"
}

expect_failure() {
  local predicate="$1"
  local evidence_root="$2"
  local clock_file="$3"
  shift 3
  local output="$test_root/failure-$RANDOM.txt"
  if run_controller "$evidence_root" "$clock_file" "$@" > "$output" 2>&1; then
    echo "expected failure: $predicate" >&2
    exit 1
  fi
  grep -F "failed_predicate=$predicate" "$output" >/dev/null
}

write_registered_collision() {
  local evidence_root="$1"
  local run_id="$2"
  mkdir -p "$evidence_root/$run_id/00-environment"
  printf 'run_id=%s\nstate=REGISTERED\n' "$run_id" \
    > "$evidence_root/$run_id/00-environment/run-registration.txt"
}

write_registration_fixture() {
  local evidence_root="$1"
  local run_id="$2"
  local run_dir="$evidence_root/$run_id"
  mkdir -p "$run_dir/01-entry-baseline"
  cat > "$run_dir/00-environment/cohort.tsv" <<EOF
cohort	role	originalBarcode	deviceId	kafkaKey	scanTime	state
C0	baseline-good	$run_id-C0-001	SEOUL-CENTER-PC-001	SEOUL-CENTER-PC-001	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C1	transient-redis-failure	$run_id-C1-001	SEOUL-CENTER-PC-002	SEOUL-CENTER-PC-002	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C2	permanent-validation	$run_id-C2-001	<BLANK>	bip-fr-005-c2-invalid	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C3	post-recovery-good	$run_id-C3-001	SEOUL-CENTER-PC-003	SEOUL-CENTER-PC-003	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
EOF
  cat > "$run_dir/01-entry-baseline/baseline-watermarks.tsv" <<'EOF'
topic	partition	log_start_offset	baseline_end_offset
barcode-events-dlt	0	0	2
barcode-events-dlt	1	0	0
barcode-events-dlt	2	0	0
barcode-events-quarantine	0	0	0
barcode-events-quarantine	1	0	0
barcode-events-quarantine	2	0	0
EOF
  cat > "$run_dir/01-entry-baseline/observed-residue.tsv" <<'EOF'
topic	partition	offset	owner_run_id	root_identity
barcode-events-dlt	0	0	BIP-FR-005-MR-20260911T112314Z	BIP-FR-005-MR-20260911T112314Z-C1-001
barcode-events-dlt	0	1	BIP-FR-005-MR-20260911T112314Z	BIP-FR-005-MR-20260911T112314Z-C2-001
EOF
  cat > "$run_dir/01-entry-baseline/successor-identity-state.tsv" <<EOF
originalBarcode	mysql	redis_stream	worker_dlq	dedupe
$run_id-C0-001	0	0	0	0
$run_id-C1-001	0	0	0	0
$run_id-C2-001	0	0	0	0
$run_id-C3-001	0	0	0	0
EOF
  cat > "$run_dir/01-entry-baseline/runtime-metrics.tsv" <<'EOF'
metric	value
source_consumer_lag	0
redis_group_lag	0
redis_pel_pending	0
EOF
}

# Valid allocation, lexical ID, UTC reservation time and candidate != registration.
valid_root="$test_root/valid/evidence"
valid_clock="$test_root/valid.clock"
mkdir -p "$valid_root"
printf '4102444800 21000101T000000Z\n4102444805 21000101T000005Z\n' > "$valid_clock"
allocation_output="$(run_controller "$valid_root" "$valid_clock" allocate)"
valid_run_id="$(printf '%s\n' "$allocation_output" | awk -F= '$1 == "run_id" {print $2}')"
test "$valid_run_id" = BIP-FR-005-MR-21000101T000000Z
printf '%s\n' "$valid_run_id" | grep -Eq '^BIP-FR-005-MR-[0-9]{8}T[0-9]{6}Z$'
candidate_file="$valid_root/$valid_run_id/00-environment/candidate-reservation.txt"
grep -Fx 'allocated_at_utc=2100-01-01T00:00:00Z' "$candidate_file" >/dev/null
grep -Fx 'state=CANDIDATE_RESERVED' "$candidate_file" >/dev/null
grep -Fx 'contract_revision=BIP-FR-005-RC-R1' "$candidate_file" >/dev/null
grep -Fx 'implementation_revision=83eaa799e2359a353e748e567a5fbfc0df0cf9c3' "$candidate_file" >/dev/null
grep -Fx 'preparation_revision=b124748fb72581614caa208287a31a3c4a3da8a1' "$candidate_file" >/dev/null
grep -Fx 'baseline_isolation_version=1' "$candidate_file" >/dev/null
test ! -e "$valid_root/$valid_run_id/00-environment/run-registration.txt"

# Valid resume.
resume_output="$(run_controller "$valid_root" "$valid_clock" resume)"
grep -Fx 'resume=PASS' <<< "$resume_output" >/dev/null

# Binding mismatch rejection.
mismatch_root="$test_root/mismatch/evidence"
mismatch_clock="$test_root/mismatch.clock"
mkdir -p "$mismatch_root"
printf '4102444860 21000101T000100Z\n' > "$mismatch_clock"
mismatch_output="$(run_controller "$mismatch_root" "$mismatch_clock" allocate)"
mismatch_id="$(printf '%s\n' "$mismatch_output" | awk -F= '$1 == "run_id" {print $2}')"
mismatch_candidate="$mismatch_root/$mismatch_id/00-environment/candidate-reservation.txt"
chmod u+w "$mismatch_candidate"
sed -i.bak 's/baseline_isolation_version=1/baseline_isolation_version=2/' "$mismatch_candidate"
rm "$mismatch_candidate.bak"
expect_failure 'binding_mismatch:baseline_isolation_version' "$mismatch_root" "$mismatch_clock" resume

# Multiple active reservations reject resume.
multiple_root="$test_root/multiple/evidence"
multiple_clock="$test_root/multiple.clock"
mkdir -p "$multiple_root"
for suffix in 000200 000201; do
  id="BIP-FR-005-MR-21000101T${suffix}Z"
  mkdir -p "$multiple_root/$id/00-environment"
  printf 'run_id=%s\nstate=CANDIDATE_RESERVED\n' "$id" \
    > "$multiple_root/$id/00-environment/candidate-reservation.txt"
done
printf '4102444920 21000101T000200Z\n' > "$multiple_clock"
expect_failure 'active_reservation_count:2' "$multiple_root" "$multiple_clock" resume

# Historical/current-second reuse cannot overwrite and a non-advancing clock blocks.
reuse_root="$test_root/reuse/evidence"
reuse_clock="$test_root/reuse.clock"
reuse_id=BIP-FR-005-MR-21000101T000300Z
mkdir -p "$reuse_root"
write_registered_collision "$reuse_root" "$reuse_id"
printf '4102444980 21000101T000300Z\n4102444980 21000101T000300Z\n4102444980 21000101T000300Z\n' > "$reuse_clock"
expect_failure clock_did_not_advance "$reuse_root" "$reuse_clock" allocate
grep -Fx "run_id=$reuse_id" "$reuse_root/$reuse_id/00-environment/run-registration.txt" >/dev/null

# Same-second collision waits for the observed next second; no future time is synthesized.
collision_root="$test_root/collision/evidence"
collision_clock="$test_root/collision.clock"
collision_id=BIP-FR-005-MR-21000101T000400Z
mkdir -p "$collision_root"
write_registered_collision "$collision_root" "$collision_id"
printf '4102445040 21000101T000400Z\n4102445041 21000101T000401Z\n' > "$collision_clock"
collision_output="$(run_controller "$collision_root" "$collision_clock" allocate)"
grep -Fx 'run_id=BIP-FR-005-MR-21000101T000401Z' <<< "$collision_output" >/dev/null

# A clock behind the greatest existing Run ID fails without reservation.
backward_root="$test_root/backward/evidence"
backward_clock="$test_root/backward.clock"
mkdir -p "$backward_root"
write_registered_collision "$backward_root" BIP-FR-005-MR-21000101T000700Z
printf '4102445160 21000101T000600Z\n' > "$backward_clock"
expect_failure clock_moved_backward_before_latest_run "$backward_root" "$backward_clock" allocate
test "$(find "$backward_root" -mindepth 1 -maxdepth 1 -type d -name 'BIP-FR-005-MR-*' | wc -l | tr -d ' ')" -eq 1

# Concurrent allocators serialize: one reservation succeeds and the other is blocked.
concurrent_root="$test_root/concurrent/evidence"
concurrent_clock="$test_root/concurrent.clock"
mkdir -p "$concurrent_root"
printf '4102445100 21000101T000500Z\n4102445100 21000101T000500Z\n' > "$concurrent_clock"
set +e
run_controller "$concurrent_root" "$concurrent_clock" allocate > "$test_root/concurrent-1.out" 2>&1 &
pid_one=$!
run_controller "$concurrent_root" "$concurrent_clock" allocate > "$test_root/concurrent-2.out" 2>&1 &
pid_two=$!
wait "$pid_one"; status_one=$?
wait "$pid_two"; status_two=$?
set -e
test $((status_one + status_two)) -eq 1
test "$(find "$concurrent_root" -mindepth 1 -maxdepth 1 -type d -name 'BIP-FR-005-MR-*' | wc -l | tr -d ' ')" -eq 1

# Successful atomic registration and duplicate-idempotency.
write_registration_fixture "$valid_root" "$valid_run_id"
registration_output="$(run_controller "$valid_root" "$valid_clock" register "$valid_run_id")"
registration_file="$valid_root/$valid_run_id/00-environment/run-registration.txt"
grep -Fx 'state=REGISTERED' "$registration_file" >/dev/null
grep -Fx 'execution_state=NOT_EXECUTED' "$registration_file" >/dev/null
grep -Fx 'outcome=NOT_ASSIGNED' "$registration_file" >/dev/null
grep -Fx 'allocated_at_utc=2100-01-01T00:00:00Z' "$registration_file" >/dev/null
grep -Fx 'registered_at_utc=2100-01-01T00:00:05Z' "$registration_file" >/dev/null
grep -Fx 'execution_eligibility=BLOCKED' <<< "$registration_output" >/dev/null
grep -Fx 'reason=SYNCHRONIZATION_BLOCKED' <<< "$registration_output" >/dev/null
registration_sha_before="$(shasum -a 256 "$registration_file" | awk '{print $1}')"
duplicate_output="$(run_controller "$valid_root" "$valid_clock" register "$valid_run_id")"
grep -Fx 'registration=EXISTING_IDENTICAL' <<< "$duplicate_output" >/dev/null
test "$(shasum -a 256 "$registration_file" | awk '{print $1}')" = "$registration_sha_before"

# Synchronization failure keeps REGISTERED and blocks execution.
eligibility_output="$test_root/eligibility.out"
if BIP_FR005_TEST_SYNCHRONIZED=0 run_controller "$valid_root" "$valid_clock" eligibility "$valid_run_id" \
  > "$eligibility_output" 2>&1; then
  echo 'expected synchronization-blocked eligibility' >&2
  exit 1
fi
grep -Fx 'state=REGISTERED' "$eligibility_output" >/dev/null
grep -Fx 'execution_eligibility=BLOCKED' "$eligibility_output" >/dev/null
grep -Fx 'reason=SYNCHRONIZATION_BLOCKED' "$eligibility_output" >/dev/null
grep -Fx 'state=REGISTERED' "$registration_file" >/dev/null

# Conflicting duplicate registration fails closed.
chmod u+w "$registration_file"
sed -i.bak 's/baseline_isolation_version=1/baseline_isolation_version=2/' "$registration_file"
rm "$registration_file.bak"
expect_failure DUPLICATE_REGISTRATION_CONFLICT "$valid_root" "$valid_clock" register "$valid_run_id"

printf 'VALID_ALLOCATION=PASS\n'
printf 'LEXICAL_RUN_ID=PASS\n'
printf 'ALLOCATION_TIMESTAMP_SEMANTICS=PASS\n'
printf 'HISTORICAL_ID_REUSE_REJECTION=PASS\n'
printf 'SAME_SECOND_COLLISION=PASS\n'
printf 'CONCURRENT_ALLOCATION_UNIQUENESS=PASS\n'
printf 'CLOCK_NON_ADVANCEMENT_BLOCK=PASS\n'
printf 'CLOCK_BACKWARD_BLOCK=PASS\n'
printf 'CANDIDATE_NOT_REGISTERED=PASS\n'
printf 'CANDIDATE_RESUME=PASS\n'
printf 'BINDING_MISMATCH_REJECTION=PASS\n'
printf 'MULTIPLE_ACTIVE_RESERVATION_REJECTION=PASS\n'
printf 'REGISTRATION_FINALIZATION=PASS\n'
printf 'DUPLICATE_IDENTICAL_IDEMPOTENCY=PASS\n'
printf 'DUPLICATE_CONFLICT_REJECTION=PASS\n'
printf 'SYNCHRONIZATION_BLOCKED_STATE=PASS\n'
printf 'SUCCESSOR_REGISTRATION_CONTROLLER_TEST=PASS\n'
