#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability"
run_id="BIP-FR-005-MR-20260911T112314Z"
cohort_file="$scenario_dir/evidence/$run_id/00-environment/cohort.tsv"
base_compose="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
release_compose="$scenario_dir/docker-compose.release.yml"
compose=(docker compose --env-file "$repo_root/.env" -f "$base_compose" -f "$release_compose")

fail() {
  printf 'failure_reason=%s\nNORMAL_COHORT_DATA_CONTRACT=FAIL\n' "$1" >&2
  exit 1
}

for command_name in git docker jq awk grep sort uniq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required_command_missing:$command_name"
done

test -f "$cohort_file" || fail 'cohort_file_missing'

cohort_rows="$(awk -F '\t' 'NR > 1 {print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7}' "$cohort_file")"
test "$(printf '%s\n' "$cohort_rows" | awk 'NF {count++} END {print count+0}')" -eq 4 \
  || fail 'cohort_count_not_four'

for required_cohort in C0 C1 C2 C3; do
  test "$(printf '%s\n' "$cohort_rows" | awk -F '|' -v cohort="$required_cohort" '$1 == cohort {count++} END {print count+0}')" -eq 1 \
    || fail "cohort_missing_or_duplicate:$required_cohort"
done

barcode_list="$(printf '%s\n' "$cohort_rows" | awk -F '|' '{print $3}')"
test "$(printf '%s\n' "$barcode_list" | sort | uniq | awk 'NF {count++} END {print count+0}')" -eq 4 \
  || fail 'original_barcode_not_unique'

printf 'checked_at_utc=%s\nrun_id=%s\ncohort_file=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$cohort_file"

while IFS='|' read -r cohort role original_barcode device_id kafka_key scan_time state; do
  test -n "$cohort" || continue
  test "$original_barcode" = "$run_id-$cohort-001" \
    || fail "invalid_run_scoped_identity:$cohort"
  test "$scan_time" = EXECUTION_EPOCH_MS || fail "scan_time_not_deferred:$cohort"
  test "$state" = PREPARED_NOT_SENT || fail "cohort_not_prepared_not_sent:$cohort"

  case "$cohort" in
    C0|C1|C3)
      case "$cohort:$role" in
        C0:baseline-good|C1:transient-redis-failure|C3:post-recovery-good) ;;
        *) fail "normal_cohort_role_mismatch:$cohort:$role" ;;
      esac
      test "$device_id" != '<BLANK>' && test -n "$device_id" \
        || fail "normal_cohort_device_blank:$cohort"
      test "$kafka_key" = "$device_id" || fail "normal_cohort_key_mismatch:$cohort"
      mapping_count="$("${compose[@]}" exec -T -e BIP_DEVICE_ID="$device_id" mysql sh -lc \
        'mysql -N -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT COUNT(*) FROM device_center_mapping WHERE device_id = \"${BIP_DEVICE_ID}\""' \
        </dev/null 2>/dev/null | tr -d '\r')"
      test "$mapping_count" = 1 || fail "normal_cohort_mapping_count_${mapping_count}:$cohort:$device_id"
      ;;
    C2)
      test "$role" = permanent-validation || fail 'C2_role_mismatch'
      test "$device_id" = '<BLANK>' || fail 'C2_device_must_be_blank'
      test "$kafka_key" = 'bip-fr-005-c2-invalid' || fail 'C2_kafka_key_mismatch'
      ;;
    *) fail "unexpected_cohort:$cohort" ;;
  esac

  mysql_count="$("${compose[@]}" exec -T -e BIP_ORIGINAL_BARCODE="$original_barcode" mysql sh -lc \
    'mysql -N -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT COUNT(*) FROM barcodes WHERE original_barcode = \"${BIP_ORIGINAL_BARCODE}\""' \
    </dev/null 2>/dev/null | tr -d '\r')"
  test "$mysql_count" = 0 || fail "identity_already_in_mysql:$cohort"

  stream_count="$("${compose[@]}" exec -T redis redis-cli --json XRANGE barcode:stream - + \
    </dev/null | jq --arg barcode "$original_barcode" '[.[] | select(tostring | contains($barcode))] | length')"
  test "$stream_count" = 0 || fail "identity_already_in_redis_stream:$cohort"

  worker_dlq_count="$("${compose[@]}" exec -T redis redis-cli --json XRANGE barcode:stream:dlq - + \
    </dev/null | jq --arg barcode "$original_barcode" '[.[] | select(tostring | contains($barcode))] | length')"
  test "$worker_dlq_count" = 0 || fail "identity_already_in_worker_dlq:$cohort"

  dedupe_exists="$("${compose[@]}" exec -T redis redis-cli EXISTS "barcode:processed:$original_barcode" \
    </dev/null | tr -d '\r')"
  test "$dedupe_exists" = 0 || fail "identity_dedupe_key_exists:$cohort"

  printf 'cohort=%s role=%s original_barcode=%s device_id=%s mapping=%s mysql=%s redis_stream=%s worker_dlq=%s dedupe_exists=%s\n' \
    "$cohort" "$role" "$original_barcode" "$device_id" \
    "${mapping_count:-NOT_APPLICABLE}" "$mysql_count" "$stream_count" "$worker_dlq_count" "$dedupe_exists"
  unset mapping_count
done <<< "$cohort_rows"

echo 'NORMAL_COHORT_DATA_CONTRACT=PASS'
