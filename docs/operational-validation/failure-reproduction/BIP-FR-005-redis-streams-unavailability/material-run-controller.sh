#!/usr/bin/env bash

set -euo pipefail

run_id="${1:-}"
transition="${2:-}"
apply="${3:-}"

if [ "$transition" != enter-redis-fault ] || [ "$apply" != --apply ]; then
  echo "usage: $0 <BIP-FR-005-MR-YYYYMMDDThhmmssZ> enter-redis-fault --apply" >&2
  exit 2
fi

scenario_dir="$(cd "$(dirname "$0")" && pwd)"

if ! gate_output="$("$scenario_dir/pre-fault-gate.sh" "$run_id" 2>&1)"; then
  printf '%s\n' "$gate_output" >&2
  printf 'run_id=%s\ntransition=ENTER_REDIS_FAULT_REJECTED\nexecution_state=ABORTED\nredis_fault_action=NOT_EXECUTED\n' \
    "$run_id" >&2
  exit 1
fi

printf '%s\n' "$gate_output"
printf 'run_id=%s\ntransition=ENTER_REDIS_FAULT_PERMITTED\n' "$run_id"

if ! docker stop --timeout 10 bip-fr-002-redis; then
  printf 'run_id=%s\nredis_fault_action=FAILED\n' "$run_id" >&2
  exit 1
fi

printf 'run_id=%s\nredis_fault_action=EXECUTED\n' "$run_id"
