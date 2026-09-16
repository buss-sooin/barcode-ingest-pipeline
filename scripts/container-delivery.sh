#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
docker_command="${BIP_DOCKER_COMMAND:-docker}"
runtime_env_input="${BIP_RUNTIME_ENV:-$repo_root/.env}"
case "$runtime_env_input" in
  /*) runtime_env="$runtime_env_input" ;;
  *) runtime_env="$repo_root/$runtime_env_input" ;;
esac
compose_files="${BIP_COMPOSE_FILES:-docker-compose.yml:docker-compose.apps.yml}"
reclaim_fix_base="adee5001a0112a4d27d2da13ac9cb0391039c24c"
release_dir="$repo_root/deploy/releases"

usage() {
  cat >&2 <<'USAGE'
usage:
  container-delivery.sh release-build <full-sha> [service ...]
  container-delivery.sh dev-build [service ...]
  container-delivery.sh deploy <release-env> [service ...]
  container-delivery.sh verify <release-env> [service ...]
  container-delivery.sh rollback <previous-release-env> [service ...]

services:
  ingest processing scanner persistence-worker worker-pair

worker-pair, worker-1, worker-2는 항상 worker-1과 worker-2를 함께 선택한다.
USAGE
  exit 2
}

fail() {
  printf 'DELIVERY_RESULT=FAIL reason=%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing_command:$1"
}

is_full_sha() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

contains() {
  needle="$1"
  shift
  for item in "$@"; do
    test "$item" = "$needle" && return 0
  done
  return 1
}

build_targets=()
select_build_targets() {
  build_targets=()
  if [ "$#" -eq 0 ]; then
    set -- ingest processing scanner persistence-worker
  fi
  for requested in "$@"; do
    case "$requested" in
      ingest|processing|scanner) target="$requested" ;;
      persistence-worker|worker-pair|worker-1|worker-2) target="persistence-worker" ;;
      *) fail "unknown_service:$requested" ;;
    esac
    contains "$target" "${build_targets[@]:-}" || build_targets+=("$target")
  done
}

compose_services=()
select_compose_services() {
  compose_services=()
  if [ "$#" -eq 0 ]; then
    set -- ingest processing scanner worker-pair
  fi
  for requested in "$@"; do
    case "$requested" in
      ingest|processing|scanner)
        contains "$requested" "${compose_services[@]:-}" || compose_services+=("$requested")
        ;;
      persistence-worker|worker-pair|worker-1|worker-2)
        contains worker-1 "${compose_services[@]:-}" || compose_services+=(worker-1)
        contains worker-2 "${compose_services[@]:-}" || compose_services+=(worker-2)
        ;;
      *) fail "unknown_service:$requested" ;;
    esac
  done
}

module_for() {
  case "$1" in
    ingest) printf 'barcode-ingest-service\n' ;;
    processing) printf 'barcode-processing-service\n' ;;
    scanner) printf 'barcode-scanner-service\n' ;;
    persistence-worker) printf 'barcode-persistence-worker\n' ;;
  esac
}

image_name_for() {
  printf 'bip/%s\n' "$1"
}

image_key_for() {
  case "$1" in
    ingest) printf 'BIP_INGEST_IMAGE\n' ;;
    processing) printf 'BIP_PROCESSING_IMAGE\n' ;;
    scanner) printf 'BIP_SCANNER_IMAGE\n' ;;
    persistence-worker|worker-1|worker-2) printf 'BIP_PERSISTENCE_WORKER_IMAGE\n' ;;
  esac
}

manifest_value() {
  manifest="$1"
  key="$2"
  matches="$(grep -E "^${key}=" "$manifest" || true)"
  count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "$count" -eq 1 || fail "manifest_key_count_${key}:$count"
  printf '%s\n' "${matches#*=}"
}

resolve_manifest() {
  supplied="$1"
  case "$supplied" in
    /*) manifest="$supplied" ;;
    *) manifest="$repo_root/$supplied" ;;
  esac
  case "$manifest" in
    "$release_dir"/*.env) ;;
    *) fail "release_manifest_outside_deploy_releases:$manifest" ;;
  esac
  test -f "$manifest" || fail "release_manifest_missing:$manifest"
  release_revision="$(manifest_value "$manifest" BIP_RELEASE_REVISION)"
  is_full_sha "$release_revision" || fail "invalid_manifest_revision"
  test "$(basename "$manifest")" = "$release_revision.env" || fail "manifest_filename_revision_mismatch"
}

compose_command=()
prepare_compose_command() {
  test -f "$runtime_env" || fail "runtime_env_missing:$runtime_env"
  compose_command=("$docker_command" compose --env-file "$runtime_env")
  if [ -n "${manifest:-}" ]; then
    compose_command+=(--env-file "$manifest")
  fi
  old_ifs="$IFS"
  IFS=':'
  set -- $compose_files
  IFS="$old_ifs"
  for compose_file in "$@"; do
    case "$compose_file" in
      /*) resolved_compose="$compose_file" ;;
      *) resolved_compose="$repo_root/$compose_file" ;;
    esac
    test -f "$resolved_compose" || fail "compose_file_missing:$resolved_compose"
    compose_command+=(-f "$resolved_compose")
  done
}

verify_image_identity() {
  reference="$1"
  expected_id="$2"
  expected_revision="$3"
  actual_id="$($docker_command image inspect "$reference" --format '{{.Id}}' 2>/dev/null || true)"
  test -n "$actual_id" || fail "local_image_missing:$reference"
  test "$actual_id" = "$expected_id" || fail "image_id_mismatch:$reference"
  actual_revision="$($docker_command image inspect "$reference" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  test "$actual_revision" = "$expected_revision" || fail "image_revision_mismatch:$reference"
}

manifest_identity_for_service() {
  service="$1"
  image_key="$(image_key_for "$service")"
  expected_reference="$(manifest_value "$manifest" "$image_key")"
  expected_image_id="$(manifest_value "$manifest" "${image_key}_ID")"
  expected_image_revision="$(manifest_value "$manifest" "${image_key}_REVISION")"
  test "$expected_image_revision" = "$release_revision" || fail "service_revision_mismatch:$service"
  case "$expected_reference" in
    bip/*:"$release_revision") ;;
    *) fail "service_image_reference_not_versioned:$service" ;;
  esac
}

run_gradle_tests() {
  for service in "${build_targets[@]}"; do
    module="$(module_for "$service")"
    printf 'DELIVERY_STEP=test service=%s module=%s\n' "$service" "$module"
    (cd "$repo_root/$module" && ./gradlew clean test)
  done
}

release_build() {
  test "$#" -ge 1 || usage
  revision="$1"
  shift
  is_full_sha "$revision" || fail "release_revision_must_be_full_sha"
  test "$(git -C "$repo_root" rev-parse HEAD)" = "$revision" || fail "head_revision_mismatch"
  test -z "$(git -C "$repo_root" status --porcelain=v1)" || fail "working_tree_not_clean"
  git -C "$repo_root" merge-base --is-ancestor "$reclaim_fix_base" "$revision" \
    || fail "reclaim_fix_base_not_ancestor"
  select_build_targets "$@"
  run_gradle_tests

  mkdir -p "$release_dir"
  manifest="$release_dir/$revision.env"
  if [ -f "$manifest" ]; then
    release_revision="$(manifest_value "$manifest" BIP_RELEASE_REVISION)"
    test "$release_revision" = "$revision" || fail "existing_manifest_revision_mismatch"
    for service in "${build_targets[@]}"; do
      manifest_identity_for_service "$service"
      verify_image_identity "$expected_reference" "$expected_image_id" "$revision"
    done
    printf 'DELIVERY_RESULT=PASS action=release-build revision=%s reuse=true manifest=%s\n' \
      "$revision" "$manifest"
    return
  fi

  for service in "${build_targets[@]}"; do
    reference="$(image_name_for "$service"):$revision"
    if "$docker_command" image inspect "$reference" >/dev/null 2>&1; then
      fail "release_tag_exists_without_manifest:$reference"
    fi
  done

  release_lock="$release_dir/.$revision.lock"
  mkdir "$release_lock" 2>/dev/null || fail "release_build_already_in_progress_or_stale_lock:$release_lock"
  temporary_manifest="$(mktemp "$release_dir/.${revision}.XXXXXX")"
  built_references=()
  release_complete=false
  cleanup_incomplete_release() {
    status=$?
    trap - EXIT INT TERM
    rm -f "$temporary_manifest"
    rmdir "$release_lock" 2>/dev/null || true
    if [ "$release_complete" != true ]; then
      for built_reference in "${built_references[@]:-}"; do
        test -n "$built_reference" && "$docker_command" image rm "$built_reference" >/dev/null 2>&1 || true
      done
    fi
    return "$status"
  }
  trap cleanup_incomplete_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  {
    printf 'BIP_RELEASE_REVISION=%s\n' "$revision"
    printf 'BIP_RELEASE_CREATED_AT_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'BIP_RECLAIM_FIX_BASE=%s\n' "$reclaim_fix_base"
    printf 'BIP_RECLAIM_FIX_BASE_ANCESTOR=true\n'
  } >"$temporary_manifest"

  for service in "${build_targets[@]}"; do
    module="$(module_for "$service")"
    reference="$(image_name_for "$service"):$revision"
    printf 'DELIVERY_STEP=image-build service=%s reference=%s\n' "$service" "$reference"
    "$docker_command" build \
      --build-arg "BIP_IMAGE_REVISION=$revision" \
      --tag "$reference" \
      "$repo_root/$module"
    built_references+=("$reference")
    image_id="$($docker_command image inspect "$reference" --format '{{.Id}}')"
    test -n "$image_id" || fail "built_image_id_missing:$service"
    image_revision="$($docker_command image inspect "$reference" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
    test "$image_revision" = "$revision" || fail "built_image_revision_mismatch:$service"
    image_key="$(image_key_for "$service")"
    {
      printf '%s=%s\n' "$image_key" "$reference"
      printf '%s_ID=%s\n' "$image_key" "$image_id"
      printf '%s_REVISION=%s\n' "$image_key" "$image_revision"
    } >>"$temporary_manifest"
  done

  test ! -e "$manifest" || fail "release_manifest_created_concurrently"
  mv "$temporary_manifest" "$manifest"
  release_complete=true
  rmdir "$release_lock"
  trap - EXIT INT TERM
  printf 'DELIVERY_RESULT=PASS action=release-build revision=%s reuse=false manifest=%s\n' \
    "$revision" "$manifest"
}

dev_build() {
  select_build_targets "$@"
  manifest="$repo_root/deploy/images.dev.env"
  test -f "$manifest" || fail "dev_image_env_missing"
  grep -E '=.*:latest$' "$manifest" >/dev/null && fail "latest_tag_forbidden"
  prepare_compose_command
  compose_command+=(-f "$repo_root/docker-compose.build.yml")
  dev_services=()
  for service in "${build_targets[@]}"; do
    case "$service" in persistence-worker) dev_services+=(worker-1) ;; *) dev_services+=("$service") ;; esac
  done
  "${compose_command[@]}" build "${dev_services[@]}"
  printf 'DELIVERY_RESULT=PASS action=dev-build revision=dev\n'
}

deploy_release() {
  action="$1"
  shift
  test "$#" -ge 1 || usage
  resolve_manifest "$1"
  shift
  select_compose_services "$@"
  prepare_compose_command
  for service in "${compose_services[@]}"; do
    manifest_identity_for_service "$service"
    verify_image_identity "$expected_reference" "$expected_image_id" "$release_revision"
  done
  "${compose_command[@]}" config >/dev/null
  "${compose_command[@]}" up -d --no-build --pull never --no-deps "${compose_services[@]}"
  printf 'DELIVERY_RESULT=PASS action=%s revision=%s services=%s\n' \
    "$action" "$release_revision" "${compose_services[*]}"
}

verify_health() {
  service="$1"
  container_id="$2"
  published_port="$("${compose_command[@]}" port "$service" | awk -F: 'NR == 1 {print $NF}')"
  test -n "$published_port" || fail "health_port_missing:$service"
  attempt=1
  while [ "$attempt" -le 30 ]; do
    body="$(curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$published_port/actuator/health" 2>/dev/null || true)"
    if printf '%s\n' "$body" | grep -q '"status":"UP"'; then
      return
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  fail "application_health_not_up:$service:$container_id"
}

verify_release() {
  test "$#" -ge 1 || usage
  resolve_manifest "$1"
  shift
  select_compose_services "$@"
  prepare_compose_command
  worker_1_image_id=""
  worker_2_image_id=""

  for service in "${compose_services[@]}"; do
    manifest_identity_for_service "$service"
    verify_image_identity "$expected_reference" "$expected_image_id" "$release_revision"
    container_id="$("${compose_command[@]}" ps -q "$service")"
    test -n "$container_id" || fail "container_missing:$service"
    container_reference="$($docker_command inspect --format '{{.Config.Image}}' "$container_id")"
    container_image_id="$($docker_command inspect --format '{{.Image}}' "$container_id")"
    container_status="$($docker_command inspect --format '{{.State.Status}}' "$container_id")"
    container_oom="$($docker_command inspect --format '{{.State.OOMKilled}}' "$container_id")"
    test "$container_reference" = "$expected_reference" || fail "container_reference_mismatch:$service"
    test "$container_image_id" = "$expected_image_id" || fail "container_image_id_mismatch:$service"
    test "$container_status" = running || fail "container_not_running:$service"
    test "$container_oom" = false || fail "container_oom_killed:$service"
    verify_health "$service" "$container_id"
    case "$service" in
      worker-1) worker_1_image_id="$container_image_id" ;;
      worker-2) worker_2_image_id="$container_image_id" ;;
    esac
    printf 'DELIVERY_VERIFY=PASS service=%s reference=%s image_id=%s revision=%s\n' \
      "$service" "$expected_reference" "$container_image_id" "$release_revision"
  done

  if contains worker-1 "${compose_services[@]}" || contains worker-2 "${compose_services[@]}"; then
    test -n "$worker_1_image_id" && test -n "$worker_2_image_id" || fail "worker_pair_incomplete"
    test "$worker_1_image_id" = "$worker_2_image_id" || fail "worker_pair_image_id_mismatch"
  fi
  printf 'DELIVERY_RESULT=PASS action=verify revision=%s services=%s\n' \
    "$release_revision" "${compose_services[*]}"
}

main() {
  for required in git "$docker_command" curl awk grep sed shasum; do
    require_command "$required"
  done

  action="${1:-}"
  test -n "$action" || usage
  shift
  case "$action" in
    release-build) release_build "$@" ;;
    dev-build) dev_build "$@" ;;
    deploy) deploy_release deploy "$@" ;;
    verify) verify_release "$@" ;;
    rollback)
      deploy_release rollback "$@"
      verify_release "$@"
      ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
