#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 RUN_ID SNAPSHOT_DIR OUTPUT_DIR" >&2
  exit 2
fi

run_id="$1"
snapshot_dir="$2"
output_dir="$3"
mkdir -p "$output_dir"

grep -o "${run_id}[-A-Za-z0-9]*" "$snapshot_dir/16-b-events.txt" | sort -u >"$output_dir/b-identities.txt" || true
grep -o "${run_id}[-A-Za-z0-9]*" "$snapshot_dir/17-b-dlt.txt" | sort -u >"$output_dir/dlt-identities.txt" || true
grep -o "${run_id}[-A-Za-z0-9]*" "$snapshot_dir/32-mysql.txt" | sort -u >"$output_dir/mysql-identities.txt" || true

printf 'b=%s\ndlt=%s\nmysql=%s\n' \
  "$(wc -l <"$output_dir/b-identities.txt" | tr -d ' ')" \
  "$(wc -l <"$output_dir/dlt-identities.txt" | tr -d ' ')" \
  "$(wc -l <"$output_dir/mysql-identities.txt" | tr -d ' ')"
