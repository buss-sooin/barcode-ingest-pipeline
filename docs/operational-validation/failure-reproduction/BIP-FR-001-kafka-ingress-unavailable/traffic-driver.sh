#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <phase> <base-scan-time-ms> <request-count> <requests-per-second>" >&2
  exit 2
fi

phase=$1
base_scan_time_ms=$2
request_count=$3
requests_per_second=$4
endpoint=${BIP_FR_001_SCANNER_URL:-http://localhost:8084/scan/barcode}

if [ "$requests_per_second" -lt 1 ] || [ "$requests_per_second" -gt 10 ]; then
  echo "requests_per_second must be between 1 and 10" >&2
  exit 2
fi

interval=$(awk -v rate="$requests_per_second" 'BEGIN { printf "%.6f", 1 / rate }')
sequence=0
http_200=0
http_other=0
transport_error=0
started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "DRIVER_START phase=$phase started_at=$started_at base_scan_time_ms=$base_scan_time_ms request_count=$request_count requests_per_second=$requests_per_second endpoint=$endpoint"

while [ "$sequence" -lt "$request_count" ]; do
  scan_time_ms=$((base_scan_time_ms + sequence))
  set +e
  result=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code} %{time_total}' \
    --connect-timeout 2 --max-time 10 \
    --header 'Content-Type: application/json' \
    --data "{\"scanTime\":$scan_time_ms}" \
    "$endpoint" 2>&1)
  curl_status=$?
  set -e

  if [ "$curl_status" -ne 0 ]; then
    transport_error=$((transport_error + 1))
    echo "DRIVER_FAILURE phase=$phase sequence=$sequence scan_time_ms=$scan_time_ms curl_status=$curl_status detail=$result"
  else
    http_code=${result%% *}
    if [ "$http_code" = "200" ]; then
      http_200=$((http_200 + 1))
    else
      http_other=$((http_other + 1))
      echo "DRIVER_FAILURE phase=$phase sequence=$sequence scan_time_ms=$scan_time_ms detail=$result"
    fi
  fi

  sequence=$((sequence + 1))
  sleep "$interval"
done

finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "DRIVER_END phase=$phase finished_at=$finished_at generated=$request_count http_200=$http_200 http_other=$http_other transport_error=$transport_error first_scan_time_ms=$base_scan_time_ms last_scan_time_ms=$((base_scan_time_ms + request_count - 1))"
