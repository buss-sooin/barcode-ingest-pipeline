#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
delivery_script="$script_dir/container-delivery.sh"
test_tmp="$(mktemp -d)"
test_revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
test_manifest="$repo_root/deploy/releases/$test_revision.env"

cleanup() {
  rm -rf "$test_tmp"
  rm -f "$test_manifest"
}
trap cleanup EXIT INT TERM

fail_test() {
  printf 'TEST_RESULT=FAIL reason=%s\n' "$*" >&2
  exit 1
}

assert_equal() {
  expected="$1"
  actual="$2"
  label="$3"
  test "$actual" = "$expected" || fail_test "$label expected=$expected actual=$actual"
}

bash -n "$delivery_script"

# shellcheck source=container-delivery.sh
source "$delivery_script"

is_full_sha "$test_revision" || fail_test full_sha_rejected
if is_full_sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
  fail_test short_sha_accepted
fi

select_build_targets worker-1 worker-2 worker-pair persistence-worker
assert_equal "persistence-worker" "${build_targets[*]}" worker_build_deduplication

select_compose_services worker-1
assert_equal "worker-1 worker-2" "${compose_services[*]}" worker_pair_expansion

select_compose_services ingest processing scanner
assert_equal "ingest processing scanner" "${compose_services[*]}" application_selection

mkdir -p "$repo_root/deploy/releases" "$test_tmp/bin"
cat >"$test_manifest" <<EOF
BIP_RELEASE_REVISION=$test_revision
BIP_RELEASE_CREATED_AT_UTC=2026-09-07T00:00:00Z
BIP_RECLAIM_FIX_BASE=$reclaim_fix_base
BIP_RECLAIM_FIX_BASE_ANCESTOR=true
BIP_PERSISTENCE_WORKER_IMAGE=bip/persistence-worker:$test_revision
BIP_PERSISTENCE_WORKER_IMAGE_ID=sha256:worker-test-id
BIP_PERSISTENCE_WORKER_IMAGE_REVISION=$test_revision
EOF
printf 'placeholder=true\n' >"$test_tmp/runtime.env"

cat >"$test_tmp/bin/docker-fake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "$1" = image ] && [ "$2" = inspect ]; then
  if [ "${4:-}" = --format ]; then
    case "${5:-}" in
      *'.Id'*) printf 'sha256:worker-test-id\n' ;;
      *org.opencontainers.image.revision*) printf '%s\n' "$FAKE_REVISION" ;;
    esac
  fi
  exit 0
fi
if [ "$1" = inspect ]; then
  format="${3:-}"
  container_id="${4:-}"
  case "$format" in
    *Config.Image*) printf 'bip/persistence-worker:%s\n' "$FAKE_REVISION" ;;
    *"{{.Image}}"*) printf 'sha256:worker-test-id\n' ;;
    *State.Status*) printf 'running\n' ;;
    *State.OOMKilled*) printf 'false\n' ;;
    *) printf 'unknown inspect format for %s\n' "$container_id" >&2; exit 1 ;;
  esac
  exit 0
fi
if [ "$1" = compose ]; then
  operation=""
  service=""
  for argument in "$@"; do
    case "$argument" in
      build|config|up|ps|port) operation="$argument" ;;
      worker-1|worker-2) service="$argument" ;;
    esac
  done
  case "$operation" in
    build|config|up) exit 0 ;;
    ps) printf 'cid-%s\n' "$service" ;;
    port) printf '0.0.0.0:18085\n' ;;
    *) printf 'unsupported fake compose operation\n' >&2; exit 1 ;;
  esac
  exit 0
fi
printf 'unsupported fake docker call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$test_tmp/bin/docker-fake"

cat >"$test_tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"UP"}\n'
EOF
chmod +x "$test_tmp/bin/curl"

export FAKE_DOCKER_LOG="$test_tmp/docker.log"
export FAKE_REVISION="$test_revision"
PATH="$test_tmp/bin:$PATH"
export PATH
docker_command="$test_tmp/bin/docker-fake"
runtime_env="$test_tmp/runtime.env"
compose_files="docker-compose.yml:docker-compose.apps.yml"

deploy_release deploy "deploy/releases/$test_revision.env" worker-pair >"$test_tmp/deploy.out"
grep -q 'up -d --no-build --pull never --no-deps worker-1 worker-2' "$FAKE_DOCKER_LOG" \
  || fail_test no_build_deploy_flags_missing

verify_release "deploy/releases/$test_revision.env" worker-pair >"$test_tmp/verify.out"
grep -q 'DELIVERY_VERIFY=PASS service=worker-1' "$test_tmp/verify.out" \
  || fail_test worker_1_verify_missing
grep -q 'DELIVERY_VERIFY=PASS service=worker-2' "$test_tmp/verify.out" \
  || fail_test worker_2_verify_missing
grep -q 'DELIVERY_RESULT=PASS action=verify' "$test_tmp/verify.out" \
  || fail_test verify_result_missing

: >"$FAKE_DOCKER_LOG"
dev_build persistence-worker >"$test_tmp/dev-build.out"
grep -q 'build worker-1' "$FAKE_DOCKER_LOG" || fail_test dev_worker_build_missing
if grep -q 'build worker-1 worker-2' "$FAKE_DOCKER_LOG"; then
  fail_test dev_worker_image_built_twice
fi

: >"$FAKE_DOCKER_LOG"
main rollback "deploy/releases/$test_revision.env" worker-pair >"$test_tmp/rollback.out"
grep -q 'DELIVERY_RESULT=PASS action=rollback' "$test_tmp/rollback.out" \
  || fail_test rollback_deploy_missing
grep -q 'DELIVERY_RESULT=PASS action=verify' "$test_tmp/rollback.out" \
  || fail_test rollback_verify_missing

if (resolve_manifest "$test_tmp/runtime.env") >/dev/null 2>&1; then
  fail_test outside_manifest_accepted
fi

printf 'TEST_RESULT=PASS suite=container-delivery\n'
