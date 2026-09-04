# BIP-FR-004 실행·Evidence 준비

## 1. Routing Header

| 항목 | 값 |
|---|---|
| Project / Workspace | `AI-Native Enterprise Resilience Engineering Lab` / `barcode-ingest-pipeline` |
| Destination Session Role | BIP-FR-004 Human Gate reviewer와, 승인 시 Human Material Run operator |
| Execution Surface | local macOS terminal, 이 repository, Docker Desktop의 기존 validation Compose project |
| Engineering Objective | `BIP-FR-004-RC-R1`의 bounded Material Run 사전 검토와 실행 준비 |
| Current State / Gate | Contract `FROZEN`, Material Run Human Gate `PENDING` |
| Canonical Authority | Effective AI Engineering Guidelines, Failure Reproduction Workflow v0.1, Design 58, [R1 Contract](./REPRODUCTION-CONTRACT.md) |
| Approved Execution Boundary | 현재는 read-only 검증과 preparation artifact만 허용. Fault/traffic/Material Run은 미승인 |
| Required Responsibility | R1 의미를 바꾸지 않고 preflight, Evidence, Human path와 Gate package를 검토 |
| Prohibited | MySQL/Kafka/Redis/application 상태 변경, traffic, destructive action, boundary 확대 |
| Verification / Expected Result | V59-01~08 모두 충족 후에만 Gate package `READY` |
| Return / Closure Destination | `00I — AI-Native Enterprise Resilience Engineering Control Plane` |

## 2. 상태와 고정 참조

- Contract ID / Revision: `BIP-FR-004-RC / BIP-FR-004-RC-R1`
- Contract freeze commit: `18e059a0ab57a5052e3096dd6558285a18c797db`
- Application/source revision: `3c405c1911d171c00e92b6be9e589c06a320ada1`
- Scenario branch: `validation/bip-fr-004-mysql-persistence-unavailable`
- Compose asset: `../BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml`
- Read-only preflight: [`preflight.sh`](./preflight.sh)
- Run-scoped traffic: [`traffic-driver.sh`](./traffic-driver.sh)
- Human execution path: [`HUMAN-EXECUTABLE-OPERATIONAL-PATH.md`](./HUMAN-EXECUTABLE-OPERATIONAL-PATH.md)
- Human Gate package: [`HUMAN-GATE-PACKAGE.md`](./HUMAN-GATE-PACKAGE.md)

이 문서는 실행 절차와 Evidence mechanism을 고정한다. Failure Signature, Verification Criteria와 Claim Boundary의 정본은 R1 Contract다.

## 3. Implementation fidelity

| Design requirement | Actual implementation | 판정 |
|---|---|---|
| Worker 2개 유지 | Compose의 `worker-1`, `worker-2`, 서로 다른 고정 consumer name | PASS |
| 실제 full pipeline | Scanner → Ingest → Kafka → Processing → Redis → Workers → MySQL | PASS |
| Stream/group/DLQ | `barcode:stream` / `barcode-persistence-group` / `barcode:stream:dlq` | PASS |
| Worker read 설정 | batch 100, poll 1000ms, block 5000ms | PASS |
| DB pool | Hikari max 20, min idle 5, connection timeout 30000ms | PASS |
| Pending reclaim | 60000ms scheduler, minimum idle 5분, 두 Worker의 claim path | PASS |
| Retry upper bound | `MAX_SAVE_ATTEMPTS=3` | PASS |
| Lookup-before-save | device mapping bulk lookup 뒤 entity mapping과 `saveWithRetry()` | PASS |
| DB failure ownership | outer `DataAccessException` catch가 XACK하지 않음 | PASS |
| DLQ then ACK | DLQ XADD 성공 ID만 `acknowledge()` | PASS |
| Identity correlation | stream ID, internal/original barcode, deviceId, scanTime; DLQ `originalRecordId`; MySQL 동일 identity | PASS |

검토 source:

- [`RedisStreamConsumer.java`](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/service/RedisStreamConsumer.java)
- [`Worker application.yaml`](../../../../barcode-persistence-worker/src/main/resources/application.yaml)
- [`BarcodeRepositoryImpl.java`](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/repository/BarcodeRepositoryImpl.java)
- [`Processing Redis publisher`](../../../../barcode-processing-service/src/main/java/com/barcode/barcode_processing_service/service/BarcodeEventConsumer.java)
- [`dedupe-and-publish.lua`](../../../../barcode-processing-service/src/main/resources/scripts/dedupe-and-publish.lua)
- [`Validation Compose`](../BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml)

Material mismatch는 발견되지 않았다. Primary path는 mapping lookup을 포함한 DB access failure가 `saveWithRetry()` 전에 발생할 수 있음을 반영한다. Retry/DLQ/XACK은 해당 code path가 실제로 관측될 때만 조건부로 평가한다.

## 4. Resource Preflight

### 4.1 준비 세션 결과

`2026-09-04T06:52:53Z`에 clean preparation HEAD에서 [`preflight.sh`](./preflight.sh)를 실행해 `RESOURCE_PREFLIGHT=PASS`를 확인했다.

| 항목 | 관측 |
|---|---|
| Host | logical CPU 8, memory 16 GiB, system-wide free memory 70% |
| Repository disk | 61,897,228 KiB available |
| Docker Desktop | CPU 8, memory 6,212,071,424 bytes, overlay2 |
| Required topology | controller, broker 1·2·3, MySQL, Redis, Scanner, Ingest, Processing, Worker 2개 running |
| Required health | broker 3개, MySQL, Redis healthy; application actuator 모두 UP |
| Kafka | partitions 3/RF3, 모든 ISR size 3, URP none, unavailable none |
| Baseline backlog | Redis group lag 0, PEL 0, DLQ 0, Kafka DLT 0, processing target lag 0 |
| Runtime anomalies | 현재 restart count 0, OOMKilled false |

첫 `docker stats` sample에서 broker CPU가 약 150%로 일시 관측됐으나, 이어진 세 표본에서는 broker 1·3이 약 2%, broker 2가 약 2–7%로 안정됐다. 이는 지속 resource pressure로 판정하지 않았다. Docker memory headroom이 넓지는 않으므로 Material Run 직전 preflight를 다시 실행하고 OOM/restart, critical memory pressure 또는 비정상 CPU가 지속되면 시작하지 않는다.

과거 broker-2 `OOMKilled=true / ExitCode=137`의 정확한 Root Cause는 미해결이며 FR-004 Failure Signature나 Claim에 포함하지 않는다.

### 4.2 실행 직전 명령

Human Gate가 승인한 exact HEAD를 인자로 전달한다.

```bash
docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/preflight.sh \
  <HUMAN_GATE_APPROVED_HEAD>
```

Exit code 0과 마지막 `RESOURCE_PREFLIGHT=PASS`가 모두 필요하다. 출력은 E0에 원문 그대로 보존한다.

## 5. Proposed test envelope

| 항목 | 제안 값 | 이유 |
|---|---:|---|
| Driver rate | 약 5 requests/s | 기존 Scanner buffer path를 사용하면서 benchmark가 아닌 failure semantics를 관측 |
| 최대 logical requests | 750 | 약 150초의 연속 traffic으로 warm-up/outage/readiness/post-recovery를 포함 |
| Pre-fault warm-up | 최소 30초 | fault 직전 accepted identity와 stable flow 확보 |
| MySQL unavailable | 약 60초 | 다수 Worker read/DB failure/PEL entry 관측 기회 확보 |
| Readiness 후 traffic | 최소 30초 | new-flow persistence 회복 분리 |
| Pending observation | 최대 7분 | 5분 idle + 60초 scheduler + 관측 margin |

750은 상한이며 Resource Preflight 때문에 축소할 수 있다. 단, warm-up·fault·post-recovery 시간 술어와 full pipeline 구조를 보존해야 한다. Driver 출력의 measured timestamps로 실효 rate를 계산하고 정확한 5 requests/s 성능을 주장하지 않는다.

## 6. Material Run identity와 디렉터리

승인 후 실행 직전에 UTC Run ID를 한 번 생성한다.

```bash
RUN_ID="BIP-FR-004-MR-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/evidence/$RUN_ID"
```

생성 전에 해당 경로가 존재하지 않음을 확인한다. Run Record 첫 항목에 다음 mapping을 먼저 기록한다.

```text
BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R1
```

Evidence layout:

```text
00-environment/
01-baseline/
02-traffic/
03-fault/
04-worker/
05-redis/
06-mysql/
07-recovery/
08-reconciliation/
MANIFEST.sha256
```

## 7. Evidence capture freeze

### E0 — Environment

- preflight 전체 stdout/stderr와 exit code
- `git rev-parse --show-toplevel`, branch, HEAD, `git status --porcelain=v1`, origin
- Contract/Revision/Run mapping과 Human Gate approval reference
- Compose file, Contract, preflight, traffic driver의 SHA-256
- UTC run/preflight/fault/recovery/finish boundaries

### E1 — Baseline

- `docker compose ps`, required container inspect, MySQL container ID/image/mount
- MySQL readiness와 application actuator health
- Kafka topic/ISR/URP/unavailable와 consumer group lag
- Redis `XLEN`, `XINFO GROUPS`, `XINFO CONSUMERS`, `XPENDING` summary/detail, DLQ baseline
- MySQL run scanTime range count 0과 전체 row/unique baseline
- Worker container start time/restart count

### E2 — Traffic

- one driver invocation, base scanTime, request count/rate와 stdout
- `DRIVER_START`, 각 non-200/transport failure, `DRIVER_END`
- pre/during/post-fault accepted scanTime witness
- Scanner HTTP 200은 buffer acceptance로만 분류

### E3 — Fault

- MySQL stop requested/completed UTC, exact command와 exit code
- pre/post container ID·mount 비교 자료
- stopped state, host port refusal, Worker readiness/DB error
- MySQL start requested/completed UTC, exact command/exit code, readiness restored UTC

### E4 — Worker

- 양 Worker material-window logs
- `Read N messages`, mapping lookup 또는 save DB exception, ack/DLQ/reclaim logs
- Worker container ID/start time/restart count의 전후 불변
- FS-04가 발생한 경우 attempt, DLQ와 ACK를 record ID별 연결

### E5 — Redis

- phase별 stream XLEN, group/consumer state와 PEL summary/detail
- PEL detail의 `record ID / consumer / idle / delivery count`
- 각 run-related pending ID의 exact `XRANGE R R` payload
- DLQ baseline 이후 entry와 `originalRecordId`
- fault interval stream growth와 pending retention, recovery 뒤 pending drain

### E6 — MySQL

- base scanTime부터 마지막 scanTime까지 run-scoped rows
- fault-window pending identity의 DB absence sample
- readiness 복원 후 post-recovery new-flow row
- final internal/original barcode/scanTime uniqueness와 duplicate query

### E7 — Recovery

- same container ID/image/volume, readiness 복원
- application/Worker restart 또는 config relaxation 부재
- post-recovery new flow 저장 시각
- natural pending claim/reprocess log와 PEL 감소 sequence

### E8 — Final Reconciliation

- attempted/accepted/explicit rejected totals
- accepted identity별 Redis record ID와 final state
- MySQL/DLQ/DLT/PEL/unaccounted/multi-state-conflict 집합
- `pending ≠ unaccounted`, terminal counts와 Recovery Complete 여부
- Directly Proven / Strongly Inferred / Unresolved 구분

## 8. Correlation procedure

### 8.1 Cohort key

Driver의 `base_scan_time_ms ... base+count-1`을 primary cohort로 사용한다. Scanner가 만든 `originalBarcode`와 Processing이 만든 `internalBarcodeId`는 application/Redis/MySQL 로그·payload에서 scanTime과 함께 연결한다.

### 8.2 PEL record 연결

1. `XPENDING barcode:stream barcode-persistence-group - + 1000`에서 record ID, consumer, idle, delivery count를 얻는다.
2. 각 record ID에 `XRANGE barcode:stream R R`을 실행해 payload의 scanTime을 확인한다.
3. scanTime이 cohort 범위인 record만 run-related pending으로 분류한다.
4. 같은 identity가 fault 시점 MySQL에 없는지 read-only query로 확인한다.
5. recovery 뒤 동일 record ID의 PEL 소멸, claim/reprocess log와 MySQL row를 연결한다.

### 8.3 Conditional DLQ 연결

DLQ baseline stream ID 이후 entry만 검사한다. `originalRecordId=R`과 원본 stream `XRANGE R R`을 연결하고, Worker log에서 DLQ XADD 성공 뒤 ACK가 있었는지 확인한다. 이 연결이 없으면 단순 DLQ 증가를 FS-04 충족으로 판정하지 않는다.

### 8.4 Final-state exclusivity

각 accepted scanTime에 대해 여섯 state membership을 계산한다. MySQL, Redis DLQ, Kafka DLT, Redis pending 중 둘 이상에 동시에 속하면 해당 identity를 `MULTI_STATE_CONFLICT`로 옮기고 중복 합산하지 않는다. 어느 집합에도 없으면 `UNACCOUNTED`다.

## 9. Frozen operational commands

모든 명령은 repository root에서 실행하고 `COMPOSE_FILE`을 임의로 바꾸지 않는다.

```bash
COMPOSE_FILE="docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
```

Traffic:

```bash
BASE_SCAN_TIME_MS=$(($(date +%s) * 1000))
BIP_FR_004_SCANNER_URL=http://127.0.0.1:18084/scan/barcode \
  docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/traffic-driver.sh \
  fr004-active "$BASE_SCAN_TIME_MS" 750 5
```

Fault — Human Gate PASS 뒤 한 번만:

```bash
docker compose --env-file .env -f "$COMPOSE_FILE" stop mysql
```

Recovery — 같은 existing container 한 번만:

```bash
docker compose --env-file .env -f "$COMPOSE_FILE" start mysql
```

`down`, `up`, recreate, remove 또는 다른 service target은 이 명령과 동등하지 않다.

## 10. Manifest

모든 state-changing action과 capture가 끝난 뒤 Evidence root에서 생성한다.

```bash
find . -type f ! -name MANIFEST.sha256 -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > MANIFEST.sha256

shasum -a 256 -c MANIFEST.sha256
```

Manifest 생성 뒤 Evidence를 수정하지 않는다. 수정이 불가피하면 이전 Evidence를 보존하고 이유와 새로운 integrity 정보를 별도 기록한다.

## 11. Preparation verification

| Verification | Result | Basis |
|---|---|---|
| V59-01 Repository Traceability | PASS | exact branch/source, Contract commit과 origin 식별 |
| V59-02 R1 Contract Freeze | PASS | `BIP-FR-004-RC-R1`, Contract commit `18e059a...` |
| V59-03 Implementation Fidelity | PASS | 3절 source/code/config 대조 |
| V59-04 Resource Preflight Ready | PASS | executable read-only script와 실제 PASS run |
| V59-05 Structural Fidelity Ready | PASS | full path/두 Worker 보존, traffic scale만 bounded |
| V59-06 Evidence Capture Ready | PASS | E0~E8와 identity/record correlation freeze |
| V59-07 Human-Executable Path Ready | PASS | 별도 단계별 운영 문서 |
| V59-08 Human Gate Package Ready | PASS | 별도 package에 review inputs 집약 |

이 PASS는 preparation 완료를 뜻하며 Material Run Outcome이나 실행 승인이 아니다.
