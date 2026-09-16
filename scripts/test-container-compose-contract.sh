#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
docker_command="${BIP_DOCKER_COMMAND:-docker}"
apps_compose="$repo_root/docker-compose.apps.yml"
build_compose="$repo_root/docker-compose.build.yml"
test_tmp="$(mktemp -d)"
test_env="$test_tmp/compose.env"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup EXIT INT TERM

fail_test() {
  printf 'TEST_RESULT=FAIL reason=%s\n' "$*" >&2
  exit 1
}

for command_name in "$docker_command" jq grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail_test "missing_command:$command_name"
done

cat >"$test_env" <<'EOF'
MYSQL_ROOT_PASSWORD=test-root
MYSQL_DATABASE=barcode
MYSQL_USER=barcode
MYSQL_PASSWORD=test-password
MYSQL_EXPORTER_USER=exporter
MYSQL_EXPORTER_PASSWORD=test-exporter
WORKER1_NAME=worker-1
WORKER1_PORT=8085
WORKER2_NAME=worker-2
WORKER2_PORT=8086
BIP_RELEASE_REVISION=dev
BIP_INGEST_IMAGE=bip/ingest:dev
BIP_PROCESSING_IMAGE=bip/processing:dev
BIP_SCANNER_IMAGE=bip/scanner:dev
BIP_PERSISTENCE_WORKER_IMAGE=bip/persistence-worker:dev
EOF

if grep -n '^[[:space:]]*build:' "$apps_compose"; then
  fail_test deployment_compose_contains_build
fi

root_json="$test_tmp/root.json"
development_json="$test_tmp/development.json"

"$docker_command" compose --env-file "$test_env" \
  -f "$repo_root/docker-compose.yml" -f "$apps_compose" \
  config --format json >"$root_json"
"$docker_command" compose --env-file "$test_env" \
  -f "$repo_root/docker-compose.yml" -f "$apps_compose" -f "$build_compose" \
  config --format json >"$development_json"

for config_json in "$root_json"; do
  test "$(jq -r '.services["worker-1"].image' "$config_json")" = "bip/persistence-worker:dev" \
    || fail_test worker_1_image_mismatch
  test "$(jq -r '.services["worker-2"].image' "$config_json")" = "bip/persistence-worker:dev" \
    || fail_test worker_2_image_mismatch
  test "$(jq '[.services | to_entries[] | select(.key == "ingest" or .key == "processing" or .key == "scanner" or .key == "worker-1" or .key == "worker-2") | select(.value.build != null)] | length' "$config_json")" -eq 0 \
    || fail_test resolved_deployment_contains_build
done

test "$(jq '[.services | to_entries[] | select(.key == "ingest" or .key == "processing" or .key == "scanner" or .key == "worker-1" or .key == "worker-2") | select(.value.build != null)] | length' "$development_json")" -eq 5 \
  || fail_test development_overlay_missing_build

if grep -E '=.*:latest$' "$repo_root/deploy/images.dev.env" >/dev/null; then
  fail_test latest_tag_found
fi

printf 'TEST_RESULT=PASS suite=container-compose-contract\n'
