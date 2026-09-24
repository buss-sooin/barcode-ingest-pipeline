#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: $0 EVIDENCE_DIR RUN_ID PHASE ENDPOINT START_SEQUENCE COUNT" >&2
  exit 2
fi

evidence_dir="$1"
run_id="$2"
phase="$3"
endpoint="$4"
start_sequence="$5"
count="$6"
manifest="$evidence_dir/traffic-manifest.tsv"
device_id="SEOUL-CENTER-PC-001"
interval_seconds="${TRAFFIC_INTERVAL_SECONDS:-0}"

mkdir -p "$evidence_dir"
if [ ! -f "$manifest" ]; then
  printf 'requested_at_utc\tcompleted_at_utc\tphase\tsequence\tidentity\tscan_time_ms\tendpoint\tcurl_exit\thttp_status\ttime_total_seconds\tresponse\n' >"$manifest"
fi

for ((i = 0; i < count; i++)); do
  sequence=$((start_sequence + i))
  identity="${run_id}-${phase}-$(printf '%03d' "$sequence")"
  scan_time_ms="$(($(date -u +%s) * 1000 + sequence))"
  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  response_file="$(mktemp)"

  set +e
  metrics="$(curl --silent --show-error --output "$response_file" \
    --write-out '%{http_code}\t%{time_total}' \
    --connect-timeout 2 --max-time 10 \
    --header 'Content-Type: application/json' \
    --data "{\"barcode\":\"${identity}\",\"scanTime\":${scan_time_ms},\"deviceId\":\"${device_id}\"}" \
    "$endpoint" 2>&1)"
  curl_exit=$?
  set -e

  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$curl_exit" -eq 0 ]; then
    http_status="${metrics%%$'\t'*}"
    time_total="${metrics#*$'\t'}"
  else
    http_status="transport-error"
    time_total="n/a"
  fi
  response="$(tr '\r\n\t' '   ' <"$response_file")"
  rm -f "$response_file"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$requested_at" "$completed_at" "$phase" "$sequence" "$identity" "$scan_time_ms" \
    "$endpoint" "$curl_exit" "$http_status" "$time_total" "$response" | tee -a "$manifest"
  if [ "$i" -lt "$((count - 1))" ] && [ "$interval_seconds" != "0" ]; then
    sleep "$interval_seconds"
  fi
done
