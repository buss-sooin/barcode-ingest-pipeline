#!/usr/bin/env bash

set -euo pipefail

run_id="${1:-}"
cohort_file="${2:-}"
output_dir="${3:-}"

if [ "$#" -ne 3 ] || ! printf '%s\n' "$run_id" | grep -Eq '^BIP-FR-005-MR-[0-9]{8}T[0-9]{6}Z$'; then
  echo 'usage: successor-baseline-capture-v1.sh <successor-run-id> <cohort.tsv> <new-output-dir>' >&2
  exit 2
fi

fail() {
  printf 'failed_predicate=%s\nSUCCESSOR_BASELINE_CAPTURE=FAIL\n' "$1" >&2
  exit 1
}

for command_name in docker jq awk grep sort mktemp mv mkdir dirname; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required_command_missing:$command_name"
done
test -f "$cohort_file" || fail cohort_file_missing
test ! -e "$output_dir" || fail output_directory_already_exists

output_parent="$(dirname "$output_dir")"
mkdir -p "$output_parent"
capture_dir="$(mktemp -d "$output_parent/.successor-capture-v1.XXXXXX")"
trap 'rm -rf "$capture_dir"' EXIT

watermarks="$capture_dir/baseline-watermarks.tsv"
residue="$capture_dir/observed-residue.tsv"
identity_state="$capture_dir/successor-identity-state.tsv"
metrics="$capture_dir/runtime-metrics.tsv"

printf 'topic\tpartition\tlog_start_offset\tbaseline_end_offset\n' > "$watermarks"
printf 'topic\tpartition\toffset\towner_run_id\troot_identity\n' > "$residue"

for topic in barcode-events-dlt barcode-events-quarantine; do
  starts="$(docker exec bip-fr-002-broker-1 kafka-get-offsets \
    --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
    --topic "$topic" --time -2)"
  ends="$(docker exec bip-fr-002-broker-1 kafka-get-offsets \
    --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
    --topic "$topic" --time -1)"

  topic_record_count=0
  for partition in 0 1 2; do
    start="$(printf '%s\n' "$starts" | awk -F: -v p="$partition" '$2 == p {print $3}')"
    end="$(printf '%s\n' "$ends" | awk -F: -v p="$partition" '$2 == p {print $3}')"
    printf '%s\n' "$start" | grep -Eq '^[0-9]+$' || fail "invalid_log_start:$topic:$partition"
    printf '%s\n' "$end" | grep -Eq '^[0-9]+$' || fail "invalid_log_end:$topic:$partition"
    count=$((end - start))
    test "$count" -ge 0 || fail "negative_partition_span:$topic:$partition"
    topic_record_count=$((topic_record_count + count))
    test "$topic_record_count" -le 10000 || fail "topic_capture_bound_exceeded:$topic"
    printf '%s\t%s\t%s\t%s\n' "$topic" "$partition" "$start" "$end" >> "$watermarks"

    test "$count" -gt 0 || continue
    raw_records="$(docker exec bip-fr-002-broker-1 kafka-console-consumer \
      --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
      --topic "$topic" --partition "$partition" --offset "$start" \
      --max-messages "$count" --timeout-ms 10000 \
      --property print.partition=true --property print.offset=true \
      --property print.key=false --property print.headers=false --property print.value=true \
      2>/dev/null)" || fail "partition_capture_failed:$topic:$partition"

    captured=0
    while IFS=$'\t' read -r partition_field offset_field payload; do
      test -n "$partition_field" || continue
      actual_partition="${partition_field#Partition:}"
      actual_offset="${offset_field#Offset:}"
      root_identity="$(printf '%s' "$payload" | jq -er '.barcode | strings')" \
        || fail "root_identity_missing:$topic:$partition:$actual_offset"
      owner_run_id="$(printf '%s\n' "$root_identity" | sed -E 's/-C[0-3]-001$//')"
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$topic" "$actual_partition" "$actual_offset" "$owner_run_id" "$root_identity" >> "$residue"
      captured=$((captured + 1))
    done <<< "$raw_records"
    test "$captured" -eq "$count" || fail "partition_capture_incomplete:$topic:$partition"
  done
done

redis_stream_length="$(docker exec bip-fr-002-redis redis-cli XLEN barcode:stream | tr -d '\r')"
worker_dlq_length="$(docker exec bip-fr-002-redis redis-cli XLEN barcode:stream:dlq | tr -d '\r')"
printf '%s\n' "$redis_stream_length" | grep -Eq '^[0-9]+$' || fail redis_stream_length_unreadable
printf '%s\n' "$worker_dlq_length" | grep -Eq '^[0-9]+$' || fail worker_dlq_length_unreadable
test "$redis_stream_length" -le 10000 || fail redis_stream_identity_scan_bound_exceeded
test "$worker_dlq_length" -le 10000 || fail worker_dlq_identity_scan_bound_exceeded

printf 'originalBarcode\tmysql\tredis_stream\tworker_dlq\tdedupe\n' > "$identity_state"
while IFS=$'\t' read -r cohort role original_barcode device_id kafka_key scan_time state; do
  test "$cohort" != cohort || continue
  mysql_count="$(docker exec -e BIP_ORIGINAL_BARCODE="$original_barcode" bip-fr-002-mysql sh -lc \
    'mysql -N -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT COUNT(*) FROM barcodes WHERE original_barcode = \"${BIP_ORIGINAL_BARCODE}\""' \
    2>/dev/null | tr -d '\r')"
  redis_stream_count="$(docker exec bip-fr-002-redis redis-cli --json XRANGE barcode:stream - + COUNT 10000 \
    | jq --arg identity "$original_barcode" '[.[] | select(tostring | contains($identity))] | length')"
  worker_dlq_count="$(docker exec bip-fr-002-redis redis-cli --json XRANGE barcode:stream:dlq - + COUNT 10000 \
    | jq --arg identity "$original_barcode" '[.[] | select(tostring | contains($identity))] | length')"
  dedupe_count="$(docker exec bip-fr-002-redis redis-cli EXISTS "barcode:processed:$original_barcode" | tr -d '\r')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$original_barcode" "$mysql_count" \
    "$redis_stream_count" "$worker_dlq_count" "$dedupe_count" >> "$identity_state"
done < "$cohort_file"

source_group="$(docker exec bip-fr-002-broker-1 kafka-consumer-groups \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --group barcode-processing-group)"
source_lag="$(printf '%s\n' "$source_group" | awk '$6 ~ /^[0-9]+$/ {sum += $6; rows++} END {if (!rows) exit 1; print sum+0}')" \
  || fail source_consumer_group_unreadable
redis_groups="$(docker exec bip-fr-002-redis redis-cli --json XINFO GROUPS barcode:stream)"
redis_group_lag="$(printf '%s' "$redis_groups" | jq -er '[.[] | select(.name == "barcode-persistence-group")][0].lag')" \
  || fail redis_group_lag_unreadable
redis_pel="$(docker exec bip-fr-002-redis redis-cli --json XPENDING barcode:stream barcode-persistence-group \
  | jq -er '.[0]')" || fail redis_pel_unreadable

printf 'metric\tvalue\n' > "$metrics"
printf 'source_consumer_lag\t%s\n' "$source_lag" >> "$metrics"
printf 'redis_group_lag\t%s\n' "$redis_group_lag" >> "$metrics"
printf 'redis_pel_pending\t%s\n' "$redis_pel" >> "$metrics"

mv "$capture_dir" "$output_dir"
trap - EXIT
printf 'run_id=%s\noutput_dir=%s\nSUCCESSOR_BASELINE_CAPTURE=PASS\n' "$run_id" "$output_dir"
