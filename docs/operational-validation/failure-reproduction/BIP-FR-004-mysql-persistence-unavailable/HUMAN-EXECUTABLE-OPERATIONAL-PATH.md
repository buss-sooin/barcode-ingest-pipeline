# BIP-FR-004 사람 실행 운영 경로

## 1. 목적과 권한 경계

이 문서는 AI 서비스가 없어도 Human operator가 `BIP-FR-004-RC-R1`을 같은 판단 경계로 실행·중단·복구·검증할 수 있게 한다. 현재 Human Gate는 `PENDING`이며 이 문서의 fault·traffic 명령은 아직 실행 권한이 아니다.

Material Run 전에는 [R1 Contract](./REPRODUCTION-CONTRACT.md), [Execution Preparation](./EXECUTION-PREPARATION.md), [Human Gate Package](./HUMAN-GATE-PACKAGE.md)를 함께 확인한다. 명령은 repository root에서 실행한다.

## 2. 공통 shell context

Human Gate PASS 이후 새 terminal에서 다음 값만 설정한다.

```bash
SCENARIO_DIR="docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable"
COMPOSE_FILE="docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
RUN_ID="BIP-FR-004-MR-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="$SCENARIO_DIR/evidence/$RUN_ID"
TRAFFIC_REQUEST_COUNT=750
TRAFFIC_RATE=5
```

`RUN_ID`와 Evidence 경로가 기존 항목과 충돌하면 시작하지 않는다. 모든 capture 명령은 stdout와 stderr, UTC와 exit code가 보존되게 실행한다. Credential이나 `.env` 원문은 Evidence에 복사하지 않는다.

## 3. 판단 경로

### Step 0 — Gate와 repository 확인

| 판단 항목 | 내용 |
|---|---|
| 무엇 | Human Gate PASS reference, branch, exact approved HEAD, clean tree를 확인한다. |
| 왜 | 승인되지 않은 revision이나 수정된 절차에서 fault를 실행하지 않기 위해서다. |
| Evidence | Gate reference, `git branch --show-current`, `git rev-parse HEAD`, `git status --porcelain=v1`, origin URL. |
| 정상 | branch가 `validation/bip-fr-004-mysql-persistence-unavailable`, HEAD가 승인 SHA, status가 비어 있다. |
| 비정상/중단 | Gate가 없거나 branch/HEAD/status/origin이 다르면 traffic과 fault를 시작하지 않는다. |
| 다음 판단 | 모두 일치하면 Step 1로 간다. |
| 금지 | commit amend, history rewrite, 임의 checkout 후 실행, 변경 파일 은폐. |

### Step 1 — Resource Preflight

```bash
"$SCENARIO_DIR/preflight.sh" "$(git rev-parse HEAD)"
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | Host/Docker resource, topology, component health, Kafka ISR, Redis group/PEL/DLQ와 Kafka DLT baseline을 확인한다. |
| 왜 | MySQL fault가 아닌 자원 고갈이나 기존 backlog가 결과를 지배하지 않게 한다. |
| Evidence | E0의 preflight 원문과 exit code. |
| 정상 | exit 0과 마지막 `RESOURCE_PREFLIGHT=PASS`. |
| 비정상/중단 | 어느 하나라도 FAIL이면 Run ID를 Outcome으로 판정하지 않고 시작을 중단한다. |
| 다음 판단 | PASS면 Step 2로 간다. |
| 금지 | Docker daemon 재시작, 다른 container 재시작, resource limit 변경으로 preflight를 통과시키기. |

### Step 2 — Run 등록과 Evidence 디렉터리

| 판단 항목 | 내용 |
|---|---|
| 무엇 | `REPRODUCTION-RECORD.md`에 `RUN_ID → BIP-FR-004-RC-R1`과 Gate reference를 먼저 기록하고 E0~E8 디렉터리를 만든다. |
| 왜 | 모든 Material Run이 정확히 하나의 Revision에 귀속되게 한다. |
| Evidence | Record mapping, 디렉터리 목록, 시작 UTC. |
| 정상 | 신규 Run ID 하나와 R1 하나가 직접 연결된다. |
| 비정상/중단 | 기존 Run ID 재사용, Revision 불명, approval reference 불명확이면 fault를 시작하지 않는다. |
| 다음 판단 | Step 3 baseline capture. |
| 금지 | Run 완료 후 mapping 소급 생성, 기존 Evidence 덮어쓰기. |

### Step 3 — Healthy baseline과 동일 container 식별

```bash
docker compose --env-file .env -f "$COMPOSE_FILE" ps
MYSQL_CONTAINER_ID="$(docker compose --env-file .env -f "$COMPOSE_FILE" ps -q mysql)"
docker inspect "$MYSQL_CONTAINER_ID"
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T mysql \
  sh -lc 'mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent'
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XLEN barcode:stream
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XINFO GROUPS barcode:stream
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XINFO CONSUMERS barcode:stream barcode-persistence-group
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XLEN barcode:stream:dlq
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | MySQL health와 container ID/image/mount, Worker 2개, Redis stream/group/PEL/DLQ와 Kafka/app health를 캡처한다. |
| 왜 | fault authenticity와 same-container recovery를 비교할 기준이다. |
| Evidence | E1 container inspect, readiness, Redis/Kafka/application snapshot, Worker start/restart count, MySQL count. |
| 정상 | R1 minimum topology, MySQL healthy, PEL/DLQ/DLT/target lag baseline이 preflight와 일치한다. |
| 비정상/중단 | baseline drift, current OOM/restart, PEL/DLQ/DLT contamination 또는 container identity 불명확. |
| 다음 판단 | Step 4에서 traffic을 시작한다. |
| 금지 | PEL/DLQ/Stream 삭제, offset reset, 데이터 수동 정리. |

### Step 4 — 단일 bounded active traffic 시작

```bash
BASE_SCAN_TIME_MS=$(($(date +%s) * 1000))
BIP_FR_004_SCANNER_URL=http://127.0.0.1:18084/scan/barcode \
  "$SCENARIO_DIR/traffic-driver.sh" fr004-active "$BASE_SCAN_TIME_MS" \
  "$TRAFFIC_REQUEST_COUNT" "$TRAFFIC_RATE" \
  | tee "$EVIDENCE_DIR/02-traffic/traffic-driver.txt" &
TRAFFIC_PID=$!
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | Scanner 실제 ingress에 최대 750개의 unique `scanTime`을 약 5/s로 한 번 전송한다. |
| 왜 | fault 전·중·후가 동일 cohort에 속하고 client 재시도가 primary signature를 흐리지 않게 한다. |
| Evidence | `DRIVER_START/EVENT/END`, HTTP status, curl status, 요청·완료 UTC와 scanTime. |
| 정상 | warm-up 30초 동안 HTTP 200 accepted event가 지속되고 pipeline baseline이 유지된다. |
| 비정상/중단 | driver 중복 실행, 지속 transport failure, rate/count 범위 이탈 또는 다른 component failure. |
| 다음 판단 | traffic 종료 전에 Step 5를 수행한다. |
| 금지 | driver restart로 cohort 추가, `curl --retry`, Redis 직접 삽입, Worker 직접 호출. |

### Step 5 — Fault 직전 재검증과 MySQL stop

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
docker inspect --format '{{.Id}} {{.State.Status}} {{.RestartCount}} {{.State.OOMKilled}}' "$MYSQL_CONTAINER_ID"
docker compose --env-file .env -f "$COMPOSE_FILE" stop mysql
date -u +%Y-%m-%dT%H:%M:%SZ
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | fault 직전 accepted scan을 확인한 후 기존 `mysql` service만 stop한다. |
| 왜 | TP-1과 의도된 단일 failure domain을 고정한다. |
| Evidence | 마지막 pre-fault accepted event, stop 요청/완료 UTC와 exit code, pre/post inspect. |
| 정상 | traffic이 계속 실행 중이고 exact target ID가 확인되며 `mysql`만 stopped다. |
| 비정상/중단 | traffic 종료, target identity 변화, 다른 service unhealthy, 명령 target 불명확이면 stop하지 않는다. |
| 다음 판단 | Step 6에서 unavailable/PEL signature를 관찰한다. |
| 금지 | `down`, `down -v`, remove/recreate, 다른 service stop, volume/schema 변경. |

### Step 6 — Unavailable interval과 PEL ownership

```bash
docker inspect --format '{{.Id}} {{.State.Status}} {{.State.ExitCode}}' "$MYSQL_CONTAINER_ID"
nc -z 127.0.0.1 13306
docker compose --env-file .env -f "$COMPOSE_FILE" logs --since 2m worker-1 worker-2
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XLEN barcode:stream
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group - + 1000
```

각 pending record ID `R`은 다음으로 payload를 확인한다.

```bash
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XRANGE barcode:stream R R
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | MySQL unavailable, fault-window accepted identity, Redis ingress 증가, Worker read/DB error, PEL ID·consumer ownership을 연결한다. |
| 왜 | FS-01~03과 TP-2~4의 중심 인과관계다. |
| Evidence | E2 traffic, E3 readiness, E4 Worker logs, E5 phase snapshots·XPENDING detail·XRANGE. |
| 정상 | leaderless/upstream fault 없이 accepted scan/Redis ingress가 이어지고, run record R이 DB error 뒤 MySQL 없이 PEL에 유지된다. |
| 비정상/중단 | run identity↔R 연결 불가, PEL 없이 ACK된 정황, Kafka/Redis/Worker failure가 결과를 지배, resource envelope 이탈. |
| 다음 판단 | 약 60초 unavailable 목표 뒤 Step 7로 복구한다. |
| 금지 | XACK/XCLAIM, PEL clear, DLQ mutation, Worker/Redis/Kafka restart. |

### Step 7 — Same-container MySQL recovery

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
docker compose --env-file .env -f "$COMPOSE_FILE" start mysql
MYSQL_READINESS_RESTORED=0
for readiness_attempt in $(seq 1 120); do
  if docker compose --env-file .env -f "$COMPOSE_FILE" exec -T mysql \
    sh -lc 'mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent'; then
    MYSQL_READINESS_RESTORED=1
    break
  fi
  sleep 1
done
test "$MYSQL_READINESS_RESTORED" -eq 1
date -u +%Y-%m-%dT%H:%M:%SZ
MYSQL_CONTAINER_ID_AFTER="$(docker compose --env-file .env -f "$COMPOSE_FILE" ps -q mysql)"
docker inspect "$MYSQL_CONTAINER_ID_AFTER"
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | 정확히 같은 MySQL container와 volume을 start하고 readiness를 확인한다. |
| 왜 | recreate나 storage reset이 아닌 availability recovery를 검증한다. |
| Evidence | start UTC/exit, readiness restored UTC, before/after ID·image·mount. |
| 정상 | ID와 `/var/lib/mysql` mount source가 동일하고 readiness가 복원된다. |
| 비정상/중단 | start가 recreate를 요구하거나 ID/volume 불일치, 다른 component restart가 발생한다. |
| 다음 판단 | Step 8의 new-flow와 Step 9의 pending recovery를 관찰한다. |
| 금지 | `up`, force-recreate, volume 복원/삭제, DB 수동 수정, Worker restart. |

### Step 8 — New-flow persistence 회복

| 판단 항목 | 내용 |
|---|---|
| 무엇 | readiness 복원 뒤 최소 30초 동안의 accepted identity가 MySQL에 새로 저장되는지 확인한다. |
| 왜 | 오래된 pending reclaim과 분리해 현재 write path 회복을 증명한다. |
| Evidence | post-recovery `DRIVER_EVENT`, Worker log, run-scoped MySQL query. |
| 정상 | application/Worker restart 없이 post-recovery identity가 MySQL에 존재한다. |
| 비정상/중단 | readiness는 UP이나 new flow가 저장되지 않거나 다른 component 변경이 필요하다. |
| 다음 판단 | traffic 종료를 기다리고 Step 9로 간다. |
| 금지 | 별도 direct DB insert, application restart, 설정 완화. |

### Step 9 — Natural pending reclaim/reprocessing

```bash
wait "$TRAFFIC_PID"
docker compose --env-file .env -f "$COMPOSE_FILE" logs --since 10m worker-1 worker-2
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T redis redis-cli XPENDING barcode:stream barcode-persistence-group
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | readiness 뒤 최대 7분 동안 5분 minimum idle과 60초 scheduler에 의한 자연 claim/reprocessing을 관찰한다. |
| 왜 | 설정 변경이나 수동 개입 없이 ownership이 정상 처리로 수렴하는지 검증한다. |
| Evidence | 시간순 XPENDING detail, delivery count/consumer, pending-processing log, MySQL row. |
| 정상 | run-related pending ID가 claim/reprocessed되고 PEL이 0으로 수렴한다. |
| 비정상/중단 | 7분 뒤 pending이 남으면 `Recovery Complete`를 주장하지 않고 상태를 보존한다. |
| 다음 판단 | Step 10 reconciliation. |
| 금지 | XCLAIM/XACK 수동 실행, scheduler/idle threshold 변경, Worker restart. |

### Step 10 — Final reconciliation과 Outcome

MySQL cohort query는 `.env`를 출력하지 않고 container 환경을 사용한다.

```bash
LAST_SCAN_TIME_MS=$((BASE_SCAN_TIME_MS + TRAFFIC_REQUEST_COUNT - 1))
SQL="SELECT CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED), original_barcode, internal_barcode_id, device_id FROM barcodes WHERE CAST(ROUND(UNIX_TIMESTAMP(scan_time)*1000) AS UNSIGNED) BETWEEN $BASE_SCAN_TIME_MS AND $LAST_SCAN_TIME_MS ORDER BY scan_time, id"
docker compose --env-file .env -f "$COMPOSE_FILE" exec -T mysql \
  sh -lc 'mysql -N -B -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh "$SQL"
```

| 판단 항목 | 내용 |
|---|---|
| 무엇 | `N_attempted=N_accepted+N_explicit_rejected`와 accepted identity별 six-state exclusivity를 계산한다. |
| 왜 | pending을 loss로 오판하지 않고 unaccounted와 multi-state conflict를 분리한다. |
| Evidence | E8 identity matrix와 MySQL/DLQ/DLT/PEL source locators. |
| 정상 | `unaccounted=0`, `multi-state conflict=0`; Recovery Complete에는 추가로 `pending=0`. |
| 비정상/중단 | identity source 불충분, 집합 중복 또는 수식 불일치는 PASS로 단순화하지 않는다. |
| 다음 판단 | Experiment Validity → Evidence Sufficiency → Failure Signature → Outcome 순서로 판정한다. |
| 금지 | 미확인 identity를 MySQL로 간주, pending을 unaccounted 처리, HTTP error만으로 Outcome 결정. |

### Step 11 — Manifest와 handoff

Evidence root에서 실행한다.

```bash
find . -type f ! -name MANIFEST.sha256 -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > MANIFEST.sha256
shasum -a 256 -c MANIFEST.sha256
```

Manifest PASS 뒤 Raw Evidence를 수정하지 않는다. Record에 Outcome, Evidence locator, manifest locator와 `Directly Proven / Strongly Inferred / Unresolved`를 기록하고 Control Plane으로 반환한다.

## 4. 안전 복구 예외

Stop Condition이 MySQL stop 이후 발생하면 추가 실험 action은 중단하되, 기존 container가 stopped 상태로 남지 않도록 계약의 same-container `start mysql`만 안전 복구로 수행할 수 있다. 이 action과 원인을 Deviation으로 보존하며, 이를 정상 Material Run completion으로 해석하지 않는다.

## 5. 복구 완료 기준

다음 모두가 직접 확인될 때만 복구 완료(Recovery Complete)를 선언한다.

- same MySQL container/volume readiness 회복
- Worker restart와 configuration relaxation 없음
- post-recovery new-flow persistence
- run-related pending reclaim/reprocessing
- Redis pending `0`
- `unaccounted=0`
- `multi-state conflict=0`

`pending ≠ unaccounted`이며, pending이 남아 있으면 availability는 복구됐더라도 Recovery Complete는 아니다.
