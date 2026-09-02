#!/usr/bin/env bash

set -euo pipefail

repo_root="/Users/sooinlee/Documents/CodexProjects/barcode-ingest-pipeline"
scenario_dir="$repo_root/docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure"
evidence_dir="$scenario_dir/evidence/BIP-FR-002-MR-20260902T053228Z"
final_dir="$evidence_dir/final"
compose_file="$scenario_dir/docker-compose.validation.yml"
env_file="$repo_root/.env"
bootstrap="broker-1:29092,broker-2:29092,broker-3:29092"
compose=(docker compose --env-file "$env_file" -f "$compose_file")

mkdir -p "$final_dir"
cd "$repo_root"

awk -F '\t' 'NR > 1 {print $5}' "$evidence_dir/03-generated-manifest.tsv" | sort -n \
  >"$final_dir/13-generated-scan-times.txt"
awk -F '\t' 'NR > 1 && $6 != 200 {print}' "$evidence_dir/03-generated-manifest.tsv" \
  >"$final_dir/14-non-200-generated-requests.tsv"

generated_count="$(wc -l <"$final_dir/13-generated-scan-times.txt" | tr -d ' ')"
generated_unique="$(sort -u "$final_dir/13-generated-scan-times.txt" | wc -l | tr -d ' ')"
generated_duplicates="$((generated_count - generated_unique))"
non_200="$(wc -l <"$final_dir/14-non-200-generated-requests.tsv" | tr -d ' ')"
scan_time_csv="$(paste -sd, "$final_dir/13-generated-scan-times.txt")"

sql="SELECT CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED), original_barcode, internal_barcode_id, device_id FROM barcodes WHERE CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED) IN ($scan_time_csv) ORDER BY scan_time, id"
"${compose[@]}" exec -T mysql sh -lc \
  'mysql -N -B -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh "$sql" \
  >"$final_dir/15-run-scoped-mysql-rows.tsv" 2>"$final_dir/15-run-scoped-mysql-stderr.txt"

cut -f1 "$final_dir/15-run-scoped-mysql-rows.tsv" | sort -n >"$final_dir/16-persisted-scan-times.txt"
comm -23 "$final_dir/13-generated-scan-times.txt" "$final_dir/16-persisted-scan-times.txt" \
  >"$final_dir/17-missing-scan-times.txt"
comm -13 "$final_dir/13-generated-scan-times.txt" "$final_dir/16-persisted-scan-times.txt" \
  >"$final_dir/18-extra-scan-times.txt"
cut -f1 "$final_dir/15-run-scoped-mysql-rows.tsv" | sort | uniq -d \
  >"$final_dir/19-business-duplicate-scan-times.txt"
cut -f2 "$final_dir/15-run-scoped-mysql-rows.tsv" | sort | uniq -d \
  >"$final_dir/20-business-duplicate-barcodes.txt"

mysql_rows="$(wc -l <"$final_dir/15-run-scoped-mysql-rows.tsv" | tr -d ' ')"
mysql_unique_scan_times="$(cut -f1 "$final_dir/15-run-scoped-mysql-rows.tsv" | sort -u | wc -l | tr -d ' ')"
mysql_unique_barcodes="$(cut -f2 "$final_dir/15-run-scoped-mysql-rows.tsv" | sort -u | wc -l | tr -d ' ')"
missing="$(wc -l <"$final_dir/17-missing-scan-times.txt" | tr -d ' ')"
extra="$(wc -l <"$final_dir/18-extra-scan-times.txt" | tr -d ' ')"
business_duplicate_scan_times="$(wc -l <"$final_dir/19-business-duplicate-scan-times.txt" | tr -d ' ')"
business_duplicate_barcodes="$(wc -l <"$final_dir/20-business-duplicate-barcodes.txt" | tr -d ' ')"

target_partition="$(awk -F= '$1 == "target_partition" {print $2; exit}' "$evidence_dir/06-runtime-target-mapping.txt")"
mapping_ack_offset="$(sed -nE 's/.*producer_ack_evidence=.*Offset: ([0-9]+).*/\1/p' "$evidence_dir/06-runtime-target-mapping.txt")"
final_offsets="$("${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events)"
final_target_end_offset="$(printf '%s\n' "$final_offsets" | awk -F: -v partition="$target_partition" '$2 == partition {print $3}')"
transport_delta="$((final_target_end_offset - mapping_ack_offset))"
transport_duplicates="$((transport_delta - generated_unique))"

dlt_offsets="$("${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events-dlt)"
dlt_count="$(printf '%s\n' "$dlt_offsets" | awk -F: '{sum += $3} END {print sum+0}')"
redis_dlq="$("${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq)"
redis_pending="$("${compose[@]}" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group | sed -n '1p')"
redis_group="$("${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream)"
redis_lag="$(printf '%s\n' "$redis_group" | awk 'previous == "lag" {print; exit} {previous=$0}')"
consumer_group="$("${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group)"
partition_lag="$(printf '%s\n' "$consumer_group" | awk -v partition="$target_partition" '$2 == "barcode-events" && $3 == partition {print $6}')"

dlq="$redis_dlq"
dlt="$dlt_count"
pending="$redis_pending"
unaccounted="$missing"
accounted_total="$((mysql_unique_scan_times + dlq + dlt + pending + unaccounted))"

{
  printf 'reconciled_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'generated_count=%s\n' "$generated_count"
  printf 'generated_unique=%s\n' "$generated_unique"
  printf 'generated_duplicate_scan_times=%s\n' "$generated_duplicates"
  printf 'manifest_non_200_scanner_responses=%s\n' "$non_200"
  printf 'mysql_run_scoped_rows=%s\n' "$mysql_rows"
  printf 'mysql_unique_scan_times=%s\n' "$mysql_unique_scan_times"
  printf 'mysql_unique_barcodes=%s\n' "$mysql_unique_barcodes"
  printf 'dlq=%s\n' "$dlq"
  printf 'dlt=%s\n' "$dlt"
  printf 'pending=%s\n' "$pending"
  printf 'unaccounted=%s\n' "$unaccounted"
  printf 'accounting_equation_generated=%s\n' "$generated_unique"
  printf 'accounting_equation_rhs=%s\n' "$accounted_total"
  printf 'missing_scan_times=%s\n' "$missing"
  printf 'extra_scan_times=%s\n' "$extra"
  printf 'business_duplicate_scan_times=%s\n' "$business_duplicate_scan_times"
  printf 'business_duplicate_barcodes=%s\n' "$business_duplicate_barcodes"
  printf 'transport_baseline_target_offset=%s\n' "$mapping_ack_offset"
  printf 'transport_final_target_end_offset=%s\n' "$final_target_end_offset"
  printf 'transport_record_delta=%s\n' "$transport_delta"
  printf 'transport_duplicates=%s\n' "$transport_duplicates"
  printf 'kafka_target_partition_lag=%s\n' "$partition_lag"
  printf 'redis_group_lag=%s\n' "$redis_lag"
  printf '[kafka_offsets_final]\n%s\n' "$final_offsets"
  printf '[kafka_dlt_offsets_final]\n%s\n' "$dlt_offsets"
  printf '[kafka_consumer_group_final]\n%s\n' "$consumer_group"
  printf '[redis_group_final]\n%s\n' "$redis_group"
} >"$final_dir/21-run-scoped-reconciliation-summary.txt"

sleep 5
{
  printf 'terminal_sample_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[container_states]\n'
  "${compose[@]}" ps --all
  printf '[topic]\n'
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --topic barcode-events
  printf '[under_replicated]\n'
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --under-replicated-partitions
  printf '[unavailable]\n'
  "${compose[@]}" exec -T broker-1 kafka-topics --bootstrap-server "$bootstrap" --describe --unavailable-partitions
  printf '[kafka_group]\n'
  "${compose[@]}" exec -T broker-1 kafka-consumer-groups --bootstrap-server "$bootstrap" --describe --group barcode-processing-group
  printf '[dlt_offsets]\n'
  "${compose[@]}" exec -T broker-1 kafka-get-offsets --bootstrap-server "$bootstrap" --topic barcode-events-dlt
  printf '[redis]\n'
  "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream
  "${compose[@]}" exec -T redis redis-cli XINFO GROUPS barcode:stream
  "${compose[@]}" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group
  "${compose[@]}" exec -T redis redis-cli XLEN barcode:stream:dlq
  printf '[application_health]\n'
  for url in http://127.0.0.1:18081/actuator/health http://127.0.0.1:18082/actuator/health \
    http://127.0.0.1:18084/actuator/health http://127.0.0.1:18085/actuator/health \
    http://127.0.0.1:18086/actuator/health; do
    printf '%s ' "$url"
    curl --silent --show-error --fail "$url"
    printf '\n'
  done
} >"$final_dir/22-terminal-convergence-sample.txt" 2>&1

if [ "$generated_count" -ne "$generated_unique" ] || [ "$non_200" -ne 0 ] \
  || [ "$mysql_rows" -ne "$generated_unique" ] || [ "$mysql_unique_scan_times" -ne "$generated_unique" ] \
  || [ "$missing" -ne 0 ] || [ "$extra" -ne 0 ] || [ "$dlq" -ne 0 ] || [ "$dlt" -ne 0 ] \
  || [ "$pending" -ne 0 ] || [ "$unaccounted" -ne 0 ] \
  || [ "$business_duplicate_scan_times" -ne 0 ] || [ "$business_duplicate_barcodes" -ne 0 ] \
  || [ "$accounted_total" -ne "$generated_unique" ] || [ "$partition_lag" -ne 0 ] || [ "$redis_lag" -ne 0 ]; then
  echo "Run-scoped reconciliation failed" >&2
  exit 7
fi

printf 'generated_unique=%s\nmysql_unique=%s\ndlq=%s\ndlt=%s\npending=%s\nunaccounted=%s\ntransport_duplicates=%s\n' \
  "$generated_unique" "$mysql_unique_scan_times" "$dlq" "$dlt" "$pending" "$unaccounted" "$transport_duplicates"
