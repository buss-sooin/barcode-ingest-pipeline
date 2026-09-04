#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <phase> <base-scan-time-ms> <request-count> <requests-per-second>" >&2
  exit 2
fi

phase="$1"
base_scan_time_ms="$2"
request_count="$3"
requests_per_second="$4"
endpoint="${BIP_FR_004_SCANNER_URL:-http://127.0.0.1:18084/scan/barcode}"

printf '%s\n' "$base_scan_time_ms" | grep -Eq '^[0-9]{13}$'
printf '%s\n' "$request_count" | grep -Eq '^[0-9]+$'
printf '%s\n' "$requests_per_second" | grep -Eq '^[0-9]+$'
test "$request_count" -ge 1
test "$request_count" -le 750
test "$requests_per_second" -ge 1
test "$requests_per_second" -le 5

interval="$(awk -v rate="$requests_per_second" 'BEGIN {printf "%.6f", 1 / rate}')"
sequence=0
http_200=0
http_other=0
transport_error=0
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf 'DRIVER_START phase=%s started_at=%s base_scan_time_ms=%s request_count=%s requests_per_second=%s endpoint=%s curl_retry=0\n' \
  "$phase" "$started_at" "$base_scan_time_ms" "$request_count" "$requests_per_second" "$endpoint"

while [ "$sequence" -lt "$request_count" ]; do
  scan_time_ms="$((base_scan_time_ms + sequence))"
  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  set +e
  result="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code} %{time_total}' \
    --connect-timeout 2 --max-time 10 --retry 0 \
    --header 'Content-Type: application/json' \
    --data "{\"scanTime\":$scan_time_ms}" \
    "$endpoint" 2>&1)"
  curl_status=$?
  set -e

  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  http_code="000"
  time_total="NA"

  if [ "$curl_status" -ne 0 ]; then
    transport_error="$((transport_error + 1))"
    detail="$result"
  else
    http_code="${result%% *}"
    time_total="${result#* }"
    detail="none"
    if [ "$http_code" = "200" ]; then
      http_200="$((http_200 + 1))"
    else
      http_other="$((http_other + 1))"
    fi
  fi

  printf 'DRIVER_EVENT phase=%s sequence=%s scan_time_ms=%s requested_at=%s completed_at=%s curl_status=%s http_status=%s time_total_seconds=%s detail=%s\n' \
    "$phase" "$sequence" "$scan_time_ms" "$requested_at" "$completed_at" "$curl_status" "$http_code" "$time_total" "$detail"

  sequence="$((sequence + 1))"
  if [ "$sequence" -lt "$request_count" ]; then
    sleep "$interval"
  fi
done

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'DRIVER_END phase=%s finished_at=%s attempted=%s http_200=%s http_other=%s transport_error=%s first_scan_time_ms=%s last_scan_time_ms=%s\n' \
  "$phase" "$finished_at" "$request_count" "$http_200" "$http_other" "$transport_error" \
  "$base_scan_time_ms" "$((base_scan_time_ms + request_count - 1))"
