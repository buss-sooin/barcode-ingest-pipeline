#!/usr/bin/env bash

set -euo pipefail

run_id=""
cohort_file=""
registered_watermarks=""
observed_watermarks=""
observed_residue=""
identity_state=""
runtime_metrics=""

usage() {
  cat >&2 <<'EOF'
usage: successor-baseline-reconciliation-v1.sh \
  --run-id <id> \
  --cohort <cohort.tsv> \
  --registered-watermarks <baseline-watermarks.tsv> \
  --observed-watermarks <observed-watermarks.tsv> \
  --observed-residue <observed-residue.tsv> \
  --identity-state <successor-identity-state.tsv> \
  --runtime-metrics <runtime-metrics.tsv>
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) run_id="${2:-}"; shift 2 ;;
    --cohort) cohort_file="${2:-}"; shift 2 ;;
    --registered-watermarks) registered_watermarks="${2:-}"; shift 2 ;;
    --observed-watermarks) observed_watermarks="${2:-}"; shift 2 ;;
    --observed-residue) observed_residue="${2:-}"; shift 2 ;;
    --identity-state) identity_state="${2:-}"; shift 2 ;;
    --runtime-metrics) runtime_metrics="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

fail() {
  printf 'failed_predicate=%s\nSUCCESSOR_BASELINE_RECONCILIATION=FAIL\n' "$1" >&2
  exit 1
}

require_header() {
  local file="$1"
  local expected="$2"
  local actual
  IFS= read -r actual < "$file" || fail "empty_file:$file"
  test "$actual" = "$expected" || fail "invalid_header:$file"
}

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
known_inventory="$scenario_dir/known-historical-residue-v1.tsv"
contract_file="$scenario_dir/REPRODUCTION-CONTRACT.md"
expected_contract_sha256="1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865"

for command_name in git awk sort comm cmp shasum grep sed wc; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required_command_missing:$command_name"
done

printf '%s\n' "$run_id" | grep -Eq '^BIP-FR-005-MR-[0-9]{8}T[0-9]{6}Z$' \
  || fail invalid_successor_run_id
case "$run_id" in
  BIP-FR-005-MR-20260909T124024Z|BIP-FR-005-MR-20260911T112314Z)
    fail historical_run_cannot_be_successor
    ;;
esac

for required_file in "$contract_file" "$known_inventory" "$cohort_file" \
  "$registered_watermarks" "$observed_watermarks" "$observed_residue" \
  "$identity_state" "$runtime_metrics"; do
  test -f "$required_file" || fail "required_file_missing:$required_file"
done

test "$(shasum -a 256 "$contract_file" | awk '{print $1}')" = "$expected_contract_sha256" \
  || fail frozen_contract_hash_mismatch

require_header "$known_inventory" $'topic\tpartition\toffset\towner_run_id\troot_identity\tevidence_file\tevidence_sha256'
require_header "$registered_watermarks" $'topic\tpartition\tlog_start_offset\tbaseline_end_offset'
require_header "$observed_watermarks" $'topic\tpartition\tlog_start_offset\tbaseline_end_offset'
require_header "$observed_residue" $'topic\tpartition\toffset\towner_run_id\troot_identity'
require_header "$cohort_file" $'cohort\trole\toriginalBarcode\tdeviceId\tkafkaKey\tscanTime\tstate'
require_header "$identity_state" $'originalBarcode\tmysql\tredis_stream\tworker_dlq\tdedupe'
require_header "$runtime_metrics" $'metric\tvalue'

awk -F '\t' '
  NR == 1 { next }
  NF != 4 { exit 1 }
  $1 != "barcode-events-dlt" && $1 != "barcode-events-quarantine" { exit 1 }
  $2 !~ /^[0-2]$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { exit 1 }
  $3 > $4 || ($4 - $3) > 10000 { exit 1 }
  { key=$1 SUBSEP $2; if (seen[key]++) exit 1 }
  END {
    if (NR != 7) exit 1
    for (t = 1; t <= 2; t++) {
      topic = t == 1 ? "barcode-events-dlt" : "barcode-events-quarantine"
      for (p = 0; p < 3; p++) if (!seen[topic SUBSEP p]) exit 1
    }
  }
' "$registered_watermarks" || fail invalid_registered_partition_watermarks

awk -F '\t' '
  NR == 1 { next }
  NF != 4 { exit 1 }
  $1 != "barcode-events-dlt" && $1 != "barcode-events-quarantine" { exit 1 }
  $2 !~ /^[0-2]$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { exit 1 }
  $3 > $4 || ($4 - $3) > 10000 { exit 1 }
  { key=$1 SUBSEP $2; if (seen[key]++) exit 1 }
  END {
    if (NR != 7) exit 1
    for (t = 1; t <= 2; t++) {
      topic = t == 1 ? "barcode-events-dlt" : "barcode-events-quarantine"
      for (p = 0; p < 3; p++) if (!seen[topic SUBSEP p]) exit 1
    }
  }
' "$observed_watermarks" || fail invalid_observed_partition_watermarks

cmp -s "$registered_watermarks" "$observed_watermarks" \
  || fail partition_watermark_drift

while IFS=$'\t' read -r topic partition offset owner root_identity evidence_file evidence_sha256; do
  test "$topic" != topic || continue
  test "$owner" = BIP-FR-005-MR-20260909T124024Z \
    || test "$owner" = BIP-FR-005-MR-20260911T112314Z \
    || fail "unknown_historical_owner:$topic:$partition:$offset"
  case "$root_identity" in
    "$owner"-C0-001|"$owner"-C1-001|"$owner"-C2-001|"$owner"-C3-001) ;;
    *) fail "invalid_historical_root_identity:$topic:$partition:$offset" ;;
  esac
  test -f "$repo_root/$evidence_file" \
    || fail "historical_owner_evidence_missing:$topic:$partition:$offset"
  test "$(shasum -a 256 "$repo_root/$evidence_file" | awk '{print $1}')" = "$evidence_sha256" \
    || fail "historical_owner_evidence_hash_mismatch:$topic:$partition:$offset"
  grep -aF "Partition:$partition" "$repo_root/$evidence_file" >/dev/null \
    || fail "historical_owner_partition_evidence_missing:$topic:$partition:$offset"
  grep -aF "Offset:$offset" "$repo_root/$evidence_file" >/dev/null \
    || fail "historical_owner_offset_evidence_missing:$topic:$partition:$offset"
  grep -aF "$root_identity" "$repo_root/$evidence_file" >/dev/null \
    || fail "historical_owner_root_evidence_missing:$topic:$partition:$offset"
done < "$known_inventory"

awk -F '\t' 'NR > 1 {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5}' "$known_inventory" \
  | sort > "${TMPDIR:-/tmp}/bip-fr-005-known-residue.$$"
known_normalized="${TMPDIR:-/tmp}/bip-fr-005-known-residue.$$"
observed_normalized="${TMPDIR:-/tmp}/bip-fr-005-observed-residue.$$"
expected_offsets="${TMPDIR:-/tmp}/bip-fr-005-expected-offsets.$$"
observed_offsets="${TMPDIR:-/tmp}/bip-fr-005-observed-offsets.$$"
cohort_identities="${TMPDIR:-/tmp}/bip-fr-005-cohort-identities.$$"
state_identities="${TMPDIR:-/tmp}/bip-fr-005-state-identities.$$"
trap 'rm -f "$known_normalized" "$observed_normalized" "$expected_offsets" "$observed_offsets" "$cohort_identities" "$state_identities"' EXIT

awk -F '\t' '
  NR == 1 { next }
  NF != 5 { exit 1 }
  $1 != "barcode-events-dlt" && $1 != "barcode-events-quarantine" { exit 1 }
  $2 !~ /^[0-2]$/ || $3 !~ /^[0-9]+$/ { exit 1 }
  { key=$1 SUBSEP $2 SUBSEP $3; if (seen[key]++) exit 1; print }
' "$observed_residue" | sort > "$observed_normalized" \
  || fail invalid_observed_residue_inventory

test -z "$(comm -3 "$known_normalized" "$observed_normalized")" \
  || fail historical_residue_inventory_mismatch

awk -F '\t' 'NR > 1 {for (offset=$3; offset<$4; offset++) print $1 "\t" $2 "\t" offset}' \
  "$observed_watermarks" | sort > "$expected_offsets"
awk -F '\t' 'NR > 1 {print $1 "\t" $2 "\t" $3}' "$observed_residue" \
  | sort > "$observed_offsets"
test -z "$(comm -3 "$expected_offsets" "$observed_offsets")" \
  || fail partition_inventory_not_exact

awk -F '\t' -v run_id="$run_id" '
  NR == 1 { next }
  NF != 7 { exit 1 }
  $1 !~ /^C[0-3]$/ || seen_cohort[$1]++ { exit 1 }
  $3 != run_id "-" $1 "-001" || seen_identity[$3]++ { exit 1 }
  $6 != "EXECUTION_EPOCH_MS" || $7 != "PREPARED_NOT_SENT" { exit 1 }
  { print $3 }
  END { if (NR != 5) exit 1 }
' "$cohort_file" | sort > "$cohort_identities" \
  || fail invalid_successor_cohort_contract

if awk -F '\t' 'NR == FNR {identity[$1]=1; next} $5 in identity {found=1} END {exit found ? 0 : 1}' \
  "$cohort_identities" "$observed_normalized"; then
  fail successor_identity_present_in_historical_residue
fi

awk -F '\t' '
  NR == 1 { next }
  NF != 5 { invalid=1; next }
  $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ { invalid=1; next }
  seen[$1]++ { invalid=1 }
  $2 != 0 || $3 != 0 || $4 != 0 || $5 != 0 { collision=1 }
  { print $1 }
  END {
    if (invalid || NR != 5) exit 1
    if (collision) exit 2
  }
' "$identity_state" | sort > "$state_identities" || {
  status=$?
  test "$status" -eq 2 && fail successor_identity_collision
  fail invalid_successor_identity_state
}
test -z "$(comm -3 "$cohort_identities" "$state_identities")" \
  || fail successor_identity_state_set_mismatch

awk -F '\t' '
  NR == 1 { next }
  NF != 2 || $1 == "" || $2 !~ /^[0-9]+$/ || seen[$1]++ { exit 1 }
  { value[$1]=$2 }
  END {
    required[1]="source_consumer_lag"
    required[2]="redis_group_lag"
    required[3]="redis_pel_pending"
    for (i=1; i<=3; i++) {
      key=required[i]
      if (!(key in value)) exit 1
      if (value[key] != 0) exit i + 1
    }
  }
' "$runtime_metrics" || {
  status=$?
  case "$status" in
    2) fail source_consumer_lag_positive ;;
    3) fail redis_group_lag_positive ;;
    4) fail redis_pel_positive ;;
    *) fail invalid_runtime_metrics ;;
  esac
}

dlt_total="$(awk -F '\t' 'NR > 1 && $1 == "barcode-events-dlt" {sum += $4} END {print sum+0}' "$observed_watermarks")"
quarantine_total="$(awk -F '\t' 'NR > 1 && $1 == "barcode-events-quarantine" {sum += $4} END {print sum+0}' "$observed_watermarks")"
residue_count="$(awk 'NR > 1 {count++} END {print count+0}' "$observed_residue")"

printf 'run_id=%s\n' "$run_id"
printf 'contract_revision=BIP-FR-005-RC-R1\n'
printf 'historical_residue_records=%s\n' "$residue_count"
printf 'diagnostic_dlt_total_end_offset=%s\n' "$dlt_total"
printf 'diagnostic_quarantine_total_end_offset=%s\n' "$quarantine_total"
printf 'GLOBAL_COUNTS=DIAGNOSTIC_ONLY\n'
printf 'PARTITION_WATERMARKS=PASS\n'
printf 'HISTORICAL_RESIDUE_OWNERSHIP=PASS\n'
printf 'SUCCESSOR_ROOT_IDENTITY_ABSENCE=PASS\n'
printf 'SOURCE_CONSUMER_LAG=PASS\n'
printf 'REDIS_GROUP_LAG=PASS\n'
printf 'REDIS_PEL=PASS\n'
printf 'FROZEN_R1_ROOT_IDENTITY_RECONCILIATION=PASS\n'
printf 'SUCCESSOR_BASELINE_RECONCILIATION=PASS\n'
