#!/usr/bin/env bash
# 신구 아키텍처 측정 1회차 전체를 자동으로 수행한다 (항목 18).
# 사용법과 예시는 load-test/RUNBOOK.md 참고. 단계 자체의 근거·수동 절차는
# 저장소 루트의 TEST-PLAN.md 참고 — 이 스크립트는 그 문서의 단계를 그대로 옮긴 것이며
# 문서에 없는 단계를 추가하지 않는다.

set -euo pipefail

ORDER="${1:-old-first}"
shift || true
EXTRA_JMETER_ARGS=("$@")

if [[ "$ORDER" != "old-first" && "$ORDER" != "new-first" ]]; then
  echo "첫 인자는 old-first 또는 new-first여야 한다 (받은 값: $ORDER)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 기본값은 "이 저장소와 barcode-old-pipeline이 같은 부모 아래 형제로 있다"는 전제다.
# git worktree 안에서 돌리면 REPO_ROOT가 .claude/worktrees/<이름> 밑이라 이 전제가
#깨진다 — 그럴 땐 OLD_REPO_PATH 환경변수로 실제 경로를 넘긴다.
OLD_REPO="$(cd "${OLD_REPO_PATH:-$REPO_ROOT/../barcode-old-pipeline}" && pwd)"
# monitoring-compose.yml/prometheus//grafana/는 항목 7에서 gitignore 해제 후
# docker-compose.yml과 같은 위치(REPO_ROOT)에 있는 게 기본이다. 다른 위치에 두고
# 쓰는 경우에만 MONITORING_ROOT_PATH로 그 루트를 넘긴다.
MONITORING_ROOT="$(cd "${MONITORING_ROOT_PATH:-$REPO_ROOT}" && pwd)"
RESULTS_DIR="$REPO_ROOT/load-test/results"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="$RESULTS_DIR/${RUN_TS}-measure-summary.txt"
WAIT_TIMEOUT_SECONDS=180

mkdir -p "$RESULTS_DIR"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$SUMMARY_FILE"
}

require_docker() {
  docker info >/dev/null 2>&1 || {
    echo "Docker 데몬이 응답하지 않는다. 확인 후 다시 실행해라." >&2
    exit 1
  }
}

# 포트가 열릴 때까지 대기, WAIT_TIMEOUT_SECONDS 넘으면 실패시킨다.
wait_for_port() {
  local host=$1 port=$2 label=$3 waited=0
  until (echo > "/dev/tcp/$host/$port") 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $WAIT_TIMEOUT_SECONDS ]]; then
      echo "$label 준비 대기 시간 초과($WAIT_TIMEOUT_SECONDS 초): $host:$port" >&2
      exit 1
    fi
  done
  log "$label 준비됨 ($host:$port)"
}

wait_for_http() {
  local url=$1 label=$2 waited=0
  until curl -s -o /dev/null --max-time 2 "$url"; do
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $WAIT_TIMEOUT_SECONDS ]]; then
      echo "$label 준비 대기 시간 초과($WAIT_TIMEOUT_SECONDS 초): $url" >&2
      exit 1
    fi
  done
  log "$label 준비됨 ($url)"
}

# barcode-scheduler가 1초마다 batch-size(기본 100)만큼만 옮기므로, 부하가 끝난
# 직후 바로 세면 아직 안 옮겨진 건이 섞인다. 값이 두 번 연속(4초) 그대로일 때까지
# 기다린다. 최대 WAIT_TIMEOUT_SECONDS.
wait_for_stable_count() {
  local container=$1 user=$2 pass=$3 db=$4
  local prev="" cur waited=0 stable_checks=0
  while [[ $waited -lt $WAIT_TIMEOUT_SECONDS ]]; do
    cur=$(count_rows "$container" "$user" "$pass" "$db")
    if [[ "$cur" == "$prev" ]]; then
      stable_checks=$((stable_checks + 1))
      [[ $stable_checks -ge 2 ]] && { echo "$cur"; return 0; }
    else
      stable_checks=0
    fi
    prev="$cur"
    sleep 2
    waited=$((waited + 2))
  done
  echo "$cur"
}

count_rows() {
  # 호스트에 mysql 클라이언트가 없어도 되도록 DB 컨테이너 안의 mysql 클라이언트를 쓴다.
  local container=$1 user=$2 pass=$3 db=$4
  docker exec "$container" mysql -u"$user" -p"$pass" "$db" -N -e "SELECT COUNT(*) FROM barcodes;" 2>/dev/null
}

load_env() {
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    export "$key=$val"
  done < "$REPO_ROOT/.env"
}

start_infra() {
  require_docker
  log "관측 스택 기동"
  docker compose --project-directory "$MONITORING_ROOT" \
    -f "$REPO_ROOT/docker-compose.yml" \
    -f "$MONITORING_ROOT/monitoring-compose.yml" \
    -p barcode-pipeline up -d

  wait_for_port localhost 9092 kafka
  wait_for_port localhost 3306 mysql
  wait_for_port localhost 6379 redis

  # 알려진 문제: kafka-exporter가 kafka보다 먼저 뜨면 죽는다(재시도 없음).
  sleep 2
  if ! docker ps --filter name=kafka-exporter --format '{{.Status}}' | grep -q "^Up"; then
    docker start kafka-exporter >/dev/null
    log "kafka-exporter 재시작(레이스 컨디션 우회)"
  fi
}

stop_infra() {
  log "관측 스택 종료"
  docker compose --project-directory "$MONITORING_ROOT" \
    -f "$REPO_ROOT/docker-compose.yml" \
    -f "$MONITORING_ROOT/monitoring-compose.yml" \
    -p barcode-pipeline down
}

start_old() {
  log "구형 앱 5개 기동(컨테이너 — DB 2개 + 앱 3개, 항목 7에서 컨테이너화)"
  # docker-compose-legacy.yml의 depends_on(condition: service_healthy)이 DB 준비
  # 순서를 보장하므로 별도 wait_for_port 없이 한 번의 up으로 전부 기동한다.
  docker compose -f "$OLD_REPO/docker-compose-legacy.yml" -p barcode-old-pipeline up -d --build

  wait_for_http http://localhost:9091/actuator/health delivery-monolith
  wait_for_http http://localhost:9081/ barcode-input-simulator

  # barcode-scheduler가 local_barcode(simulator DB)를 1초마다 폴링해 HTTP로
  # delivery-monolith에 전달한다 — 이게 없으면 central_barcode에 아무것도 안 쌓인다.
  # actuator가 없는 모듈이라 포트 리스닝 여부로만 확인한다.
  wait_for_port localhost 9082 barcode-scheduler
}

stop_old() {
  log "구형 앱 종료"
  docker compose -f "$OLD_REPO/docker-compose-legacy.yml" -p barcode-old-pipeline down
}

start_new() {
  log "신규 앱 5개 기동(컨테이너 — worker는 2대, 항목 7에서 컨테이너화)"
  # WORKER_NAME/SERVER_PORT는 docker-compose.apps.yml이 .env의 WORKER1_*/WORKER2_*를
  # 그대로 읽는다(Compose가 REPO_ROOT/.env를 자동 로드). 재기동해도 고정값 유지(PEL 회수).
  docker compose --project-directory "$MONITORING_ROOT" \
    -f "$REPO_ROOT/docker-compose.yml" \
    -f "$REPO_ROOT/docker-compose.apps.yml" \
    -p barcode-pipeline up -d --build

  for p in 8081 8082 8084 8085 8086; do
    wait_for_http "http://localhost:$p/actuator/health" "포트 $p"
  done
}

stop_new() {
  log "신규 앱 종료"
  docker compose --project-directory "$MONITORING_ROOT" \
    -f "$REPO_ROOT/docker-compose.yml" \
    -f "$REPO_ROOT/docker-compose.apps.yml" \
    -p barcode-pipeline rm -sf ingest processing scanner worker-1 worker-2
}

measure_old() {
  local before after
  before=$(count_rows mysql-central central_user central_pass central_barcode)
  log "구형 부하 전 delivery.barcodes 행 수: $before"
  "$REPO_ROOT/load-test/run.sh" old "${EXTRA_JMETER_ARGS[@]+"${EXTRA_JMETER_ARGS[@]}"}"
  log "barcode-scheduler 배치 반영 대기 중"
  after=$(wait_for_stable_count mysql-central central_user central_pass central_barcode)
  log "구형 부하 후 central_barcode.barcodes 행 수: $after (증가 $((after - before)))"
}

measure_new() {
  local before after dlq_len dlt_val
  load_env
  before=$(count_rows mysql "$MYSQL_USER" "$MYSQL_PASSWORD" delivery)
  log "신규 부하 전 delivery.barcodes 행 수: $before"
  "$REPO_ROOT/load-test/run.sh" new "${EXTRA_JMETER_ARGS[@]+"${EXTRA_JMETER_ARGS[@]}"}"
  after=$(count_rows mysql "$MYSQL_USER" "$MYSQL_PASSWORD" delivery)
  dlq_len=$(docker exec redis redis-cli XLEN barcode:stream:dlq)
  dlt_val=$(curl -s http://localhost:8082/actuator/prometheus | awk '/^barcode_processing_dlt_sent_total /{print $2}')
  log "신규 부하 후 delivery.barcodes 행 수: $after (증가 $((after - before))), DLQ 스트림 길이: $dlq_len, DLT 카운터: ${dlt_val:-0}"
}

log "측정 시작 — 순서: $ORDER, jmeter 추가 인자: ${EXTRA_JMETER_ARGS[*]:-없음}"

start_infra

if [[ "$ORDER" == "old-first" ]]; then
  start_old; measure_old; stop_old
  start_new; measure_new; stop_new
else
  start_new; measure_new; stop_new
  start_old; measure_old; stop_old
fi

if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
  log "KEEP_INFRA=1 — 관측 스택을 내리지 않는다. Prometheus 쿼리를 마친 뒤 직접 내려라:"
  log "  docker compose --project-directory \"$MONITORING_ROOT\" -f \"$REPO_ROOT/docker-compose.yml\" -f \"$MONITORING_ROOT/monitoring-compose.yml\" -p barcode-pipeline down"
else
  stop_infra
fi

log "측정 완료. 요약: $SUMMARY_FILE"
log "load-test/results/ 안의 jtl·HTML 리포트와 이 요약을 참고해 docs/measurements/에 결과 요약 문서를 남겨라 (TEST-PLAN.md 12절)."
