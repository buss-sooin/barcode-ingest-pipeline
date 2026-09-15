#!/usr/bin/env bash

set -euo pipefail

scenario_dir="$(cd "$(dirname "$0")/.." && pwd)"
validator="$scenario_dir/successor-baseline-reconciliation-v1.sh"
fixture_run_id="BIP-FR-005-MR-20990101T000000Z"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/bip-fr-005-successor-baseline-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

write_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/watermarks.tsv" <<'EOF'
topic	partition	log_start_offset	baseline_end_offset
barcode-events-dlt	0	0	2
barcode-events-dlt	1	0	0
barcode-events-dlt	2	0	0
barcode-events-quarantine	0	0	0
barcode-events-quarantine	1	0	0
barcode-events-quarantine	2	0	0
EOF
  cat > "$dir/residue.tsv" <<'EOF'
topic	partition	offset	owner_run_id	root_identity
barcode-events-dlt	0	0	BIP-FR-005-MR-20260911T112314Z	BIP-FR-005-MR-20260911T112314Z-C1-001
barcode-events-dlt	0	1	BIP-FR-005-MR-20260911T112314Z	BIP-FR-005-MR-20260911T112314Z-C2-001
EOF
  cat > "$dir/cohort.tsv" <<EOF
cohort	role	originalBarcode	deviceId	kafkaKey	scanTime	state
C0	baseline-good	$fixture_run_id-C0-001	SEOUL-CENTER-PC-001	SEOUL-CENTER-PC-001	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C1	transient-redis-failure	$fixture_run_id-C1-001	SEOUL-CENTER-PC-002	SEOUL-CENTER-PC-002	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C2	permanent-validation	$fixture_run_id-C2-001	<BLANK>	bip-fr-005-c2-invalid	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
C3	post-recovery-good	$fixture_run_id-C3-001	SEOUL-CENTER-PC-003	SEOUL-CENTER-PC-003	EXECUTION_EPOCH_MS	PREPARED_NOT_SENT
EOF
  cat > "$dir/identity-state.tsv" <<EOF
originalBarcode	mysql	redis_stream	worker_dlq	dedupe
$fixture_run_id-C0-001	0	0	0	0
$fixture_run_id-C1-001	0	0	0	0
$fixture_run_id-C2-001	0	0	0	0
$fixture_run_id-C3-001	0	0	0	0
EOF
  cat > "$dir/metrics.tsv" <<'EOF'
metric	value
source_consumer_lag	0
redis_group_lag	0
redis_pel_pending	0
diagnostic_global_dlt_count	999
diagnostic_global_quarantine_count	888
EOF
}

run_validator() {
  local dir="$1"
  "$validator" \
    --run-id "$fixture_run_id" \
    --cohort "$dir/cohort.tsv" \
    --registered-watermarks "$dir/watermarks.tsv" \
    --observed-watermarks "$dir/watermarks.tsv" \
    --observed-residue "$dir/residue.tsv" \
    --identity-state "$dir/identity-state.tsv" \
    --runtime-metrics "$dir/metrics.tsv"
}

expect_failure() {
  local dir="$1"
  local predicate="$2"
  local output="$dir/output.txt"
  if run_validator "$dir" > "$output" 2>&1; then
    echo "expected failure: $predicate" >&2
    exit 1
  fi
  grep -F "failed_predicate=$predicate" "$output" >/dev/null
  grep -Fx 'SUCCESSOR_BASELINE_RECONCILIATION=FAIL' "$output" >/dev/null
}

pass_dir="$test_root/pass"
write_fixture "$pass_dir"
run_validator "$pass_dir" > "$pass_dir/output.txt"
grep -Fx 'historical_residue_records=2' "$pass_dir/output.txt" >/dev/null
grep -Fx 'diagnostic_dlt_total_end_offset=2' "$pass_dir/output.txt" >/dev/null
grep -Fx 'GLOBAL_COUNTS=DIAGNOSTIC_ONLY' "$pass_dir/output.txt" >/dev/null
grep -Fx 'SUCCESSOR_BASELINE_RECONCILIATION=PASS' "$pass_dir/output.txt" >/dev/null

collision_dir="$test_root/collision"
write_fixture "$collision_dir"
sed -i.bak "s/$fixture_run_id-C1-001\t0\t0\t0\t0/$fixture_run_id-C1-001\t0\t1\t0\t0/" \
  "$collision_dir/identity-state.tsv"
rm "$collision_dir/identity-state.tsv.bak"
expect_failure "$collision_dir" successor_identity_collision

unknown_dir="$test_root/unknown"
write_fixture "$unknown_dir"
sed -i.bak 's/barcode-events-dlt\t0\t0\t2/barcode-events-dlt\t0\t0\t3/' "$unknown_dir/watermarks.tsv"
rm "$unknown_dir/watermarks.tsv.bak"
printf 'barcode-events-dlt\t0\t2\tBIP-FR-005-MR-20260910T000000Z\tBIP-FR-005-MR-20260910T000000Z-C1-001\n' \
  >> "$unknown_dir/residue.tsv"
expect_failure "$unknown_dir" historical_residue_inventory_mismatch

source_lag_dir="$test_root/source-lag"
write_fixture "$source_lag_dir"
sed -i.bak 's/source_consumer_lag\t0/source_consumer_lag\t1/' "$source_lag_dir/metrics.tsv"
rm "$source_lag_dir/metrics.tsv.bak"
expect_failure "$source_lag_dir" source_consumer_lag_positive

pel_dir="$test_root/pel"
write_fixture "$pel_dir"
sed -i.bak 's/redis_pel_pending\t0/redis_pel_pending\t1/' "$pel_dir/metrics.tsv"
rm "$pel_dir/metrics.tsv.bak"
expect_failure "$pel_dir" redis_pel_positive

printf 'KNOWN_NONZERO_HISTORICAL_RESIDUE=PASS\n'
printf 'SUCCESSOR_IDENTITY_COLLISION_REJECTION=PASS\n'
printf 'UNKNOWN_DLT_RESIDUE_REJECTION=PASS\n'
printf 'POSITIVE_SOURCE_LAG_REJECTION=PASS\n'
printf 'POSITIVE_REDIS_PEL_REJECTION=PASS\n'
printf 'GLOBAL_COUNTS_DIAGNOSTIC_ONLY=PASS\n'
printf 'SUCCESSOR_BASELINE_RECONCILIATION_TEST=PASS\n'
