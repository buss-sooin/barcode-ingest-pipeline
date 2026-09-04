# BIP-FR-004 Human Gate Package

## 1. Approval Target

- Approval Target: `BIP-FR-004-RC R1 Material Run`
- Contract ID / Revision: `BIP-FR-004-RC / BIP-FR-004-RC-R1`
- Gate Status: `PENDING`
- Material Run Authorization: `NONE`
- Repository: `/Users/sooinlee/Documents/CodexProjects/barcode-ingest-pipeline`
- Branch: `validation/bip-fr-004-mysql-persistence-unavailable`
- Source Revision under test: `3c405c1911d171c00e92b6be9e589c06a320ada1`
- Contract freeze commit: `18e059a0ab57a5052e3096dd6558285a18c797db`
- Gate candidate HEAD: 이 package와 모든 preparation artifact를 포함하며 Control Plane 반환 보고에 기록되는 exact local HEAD
- Working tree requirement: Material Run 직전 clean

Gate reviewer는 반환 보고의 exact HEAD를 approval에 결속하고, operator는 [`preflight.sh`](./preflight.sh)에 그 SHA를 전달해야 한다. 존재하지 않는 approval ID나 시각은 기록하지 않는다.

## 2. Decision requested

다음 bounded action을 승인할지 판단한다.

```text
real Scanner active traffic
→ 기존 MySQL container 하나 stop
→ DB failure / XACK withheld / PEL retained 관찰
→ 정확히 같은 MySQL container start
→ new-flow persistence / natural pending reclaim 관찰
→ final reconciliation
```

Codex는 승인자가 아니다. Gate PASS 전 traffic, MySQL stop/start와 Material Run은 금지된다.

## 3. Preparation readiness

| 항목 | 상태 | 근거 |
|---|---|---|
| Repository traceability | PASS | branch/source/Contract commit/origin 확인 |
| R1 Contract freeze | PASS | [REPRODUCTION-CONTRACT.md](./REPRODUCTION-CONTRACT.md) |
| Implementation fidelity | PASS | lookup-before-save, outer XACK withholding, conditional DLQ/ACK, pending reclaim을 actual code/config에서 확인 |
| Resource Preflight | PASS / rerun required | Session 60 baseline과 준비 세션의 [preflight.sh](./preflight.sh) PASS; Material Run 직전 재실행 필수 |
| Operational structural fidelity | PASS | Scanner→Ingest→Kafka→Processing→Redis→Workers 2개→MySQL 유지 |
| Evidence/correlation | READY | [EXECUTION-PREPARATION.md](./EXECUTION-PREPARATION.md) E0~E8 |
| Human path | READY | [HUMAN-EXECUTABLE-OPERATIONAL-PATH.md](./HUMAN-EXECUTABLE-OPERATIONAL-PATH.md) |
| Run traceability | READY | [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md), Material Run 아직 없음 |

준비 세션의 read-only baseline에서는 Kafka 3-broker의 모든 대상 ISR이 정상이고 URP/unavailable partition은 없었다. MySQL, Redis와 application components는 정상이며 Redis PEL/group lag/DLQ, Kafka DLT와 Processing lag는 0이었다. Host 8 logical CPU/16 GiB, Docker 8 CPU/약 5.8 GiB이고 preflight가 PASS했다.

과거 broker-2 `OOMKilled=true / ExitCode=137`의 정확한 Root Cause는 검증되지 않았고 FR-004 Claim에 포함하지 않는다. 현재 baseline의 restart count는 0, OOMKilled는 false였다.

## 4. Proposed bounded envelope

| 항목 | 제안 |
|---|---:|
| Traffic | 약 5 logical requests/s, 최대 750개, client retry 0 |
| Warm-up | 최소 30초 |
| MySQL unavailable | 약 60초 |
| Readiness 후 traffic | 최소 30초 |
| Pending observation | 최대 약 7분 |

Resource Preflight 결과로 rate/count는 낮출 수 있지만 full path, warm-up/fault/post-recovery temporal predicate와 Worker 2개를 유지한다. 이 envelope는 performance benchmark가 아니다.

## 5. Topology와 exact commands

Topology:

```text
Scanner → Ingest → Kafka(controller 1 + broker 3, RF=3)
→ Processing → Redis Streams(barcode:stream)
→ barcode-persistence-group(worker-1 + worker-2)
→ MySQL(existing container + persistent volume)
```

Material Run 직전 preflight:

```bash
docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/preflight.sh \
  <HUMAN_GATE_APPROVED_HEAD>
```

Proposed traffic:

```bash
BASE_SCAN_TIME_MS=$(($(date +%s) * 1000))
BIP_FR_004_SCANNER_URL=http://127.0.0.1:18084/scan/barcode \
  docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/traffic-driver.sh \
  fr004-active "$BASE_SCAN_TIME_MS" 750 5
```

Proposed fault — PASS 뒤 existing MySQL service만:

```bash
COMPOSE_FILE="docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml"
docker compose --env-file .env -f "$COMPOSE_FILE" stop mysql
```

Proposed recovery — 정확히 같은 stopped container:

```bash
docker compose --env-file .env -f "$COMPOSE_FILE" start mysql
```

## 6. Risk / Blast Radius

- 환경: 이 Mac의 기존 local/dev validation Compose project만
- 의도적 장애 영역(Failure Domain): 기존 MySQL container 한 개의 일시적 availability
- 예상 영향: Worker DB access failure, PEL 증가, persistence backlog, Scanner-to-Redis 흐름과 terminal latency 증가
- 보존 자산: MySQL persistent volume, Kafka/Redis data, topic/offset, application config와 source
- 복구: 같은 container의 start와 natural application recovery
- 물리적 상한: 750 logical requests, 약 60초 MySQL unavailable, 최대 7분 pending 관찰

Material risk는 Worker 2개가 공유하는 MySQL persistence가 동시에 unavailable해지는 것이다. production이나 다른 repository/service는 scope에 포함되지 않는다.

## 7. Frozen Failure Signature

- FS-01 Fault Authenticity: healthy MySQL → intended stopped/unavailable interval → same service/container/volume readiness recovery
- FS-02 Upstream Failure Isolation: outage 중 accepted scan과 Kafka/Processing availability, Redis ingress 증가
- FS-03 Primary: run record read → DB access failure → MySQL absence → premature XACK absence → PEL ownership retained
- FS-04 Conditional: `saveWithRetry()` 진입 시에만 Retry exhaustion → DLQ XADD(`originalRecordId`) → original XACK; 미진입은 `NOT OBSERVED / CODE PATH NOT REACHED`
- FS-05 Recovery: Worker restart/config relaxation 없이 new-flow persistence와 natural pending reclaim
- FS-06 Accountability: `unaccounted=0`, `multi-state conflict=0`; Recovery Complete에는 `pending=0`

`MySQL unavailable → 반드시 3 Retry → DLQ`는 승인 기준이 아니다.

## 8. Frozen Verification Criteria

판정 순서:

```text
Experiment Validity → Evidence Sufficiency → Failure Signature → Outcome
```

Temporal predicate는 timestamp만이 아니라 identity/state Evidence로 TP-1~4를 모두 연결한다.

```text
t_scan_before < t_mysql_stop < t_scan_during < t_mysql_start < t_scan_after
```

- TP-1: fault 직전 accepted scan
- TP-2: unavailable 중 신규 accepted identity
- TP-3: fault 중 Processing→Redis ingress 증가
- TP-4: Worker가 fault-window run record를 읽고 DB failure 기록

Outcome은 `REPRODUCED`, `PARTIALLY_REPRODUCED`, `NOT_REPRODUCED`, `INCONCLUSIVE`만 사용한다. HTTP error 또는 DLQ count만으로 Outcome을 결정하지 않는다.

## 9. Evidence와 reconciliation

E0~E8은 environment, baseline, traffic, fault, Worker, Redis, MySQL, recovery, final reconciliation을 각각 보존한다. 핵심 correlation은 다음과 같다.

```text
driver scanTime cohort
→ Redis XPENDING record ID / XRANGE payload
→ Worker read + DB error
→ fault-window MySQL absence
→ recovery claim/reprocess
→ MySQL / Redis DLQ / Kafka DLT / Redis pending final state
```

Conditional DLQ는 `originalRecordId`로 원본 stream ID와 연결한다. 실행 뒤 다음 수식을 accepted identity별 상호 배타적 집합으로 검증한다.

```text
N_attempted = N_accepted + N_explicit_rejected

N_accepted
= N_mysql + N_redis_dlq + N_kafka_dlt
+ N_redis_pending + N_unaccounted + N_multi_state_conflict
```

목표는 `unaccounted=0`, `multi-state conflict=0`; Recovery Complete에는 `pending=0`도 필요하다. 생성·검증된 `MANIFEST.sha256` 뒤 Raw Evidence를 수정하지 않는다.

## 10. Prohibited actions

- Gate PASS 전 traffic, MySQL stop/start 또는 Material Run
- `docker compose down`, `down -v`, force-recreate, container remove/recreate
- volume 삭제, schema/data 수동 변경
- Redis Stream/PEL/DLQ 수동 mutation
- Kafka topic/offset/config mutation
- Kafka/Redis/Worker/Scanner/Ingest/Processing 또는 Docker daemon restart/fault
- Worker 수/identity, retry/Hikari/batch/poll/pending timing 변경
- network-wide fault, production/non-local 실행
- remediation, application behavior 변경, Framework 수정 또는 Candidate promotion

## 11. Stop Conditions

- approved branch/HEAD/Gate/status 불일치 또는 preflight FAIL
- topology/readiness/backlog baseline drift
- Design 58과 implementation material mismatch
- Failure Signature, Verification Criteria, Claim Boundary 변경 필요
- MySQL 외 failure 또는 resource anomaly가 결과를 지배
- same container/volume recovery 불가
- TP-1~4 또는 identity↔Redis record↔PEL↔MySQL correlation 불가
- destructive/high-impact action, fault scope 또는 approval boundary 확대 필요

MySQL stop 뒤 Stop Condition이 발생하면 same-container `start mysql`만 안전 복구로 수행하고 Deviation을 남긴다. Run을 PASS로 단순화하지 않는다.

## 12. Claim Boundary와 Non-claims

최대 가능한 주장은 승인된 exact source/R1/local topology와 bounded cohort에서 MySQL 한 개를 일시 중단했을 때 직접 관측된 Worker DB failure, XACK 보류·PEL retention, same-container recovery, new-flow persistence, natural pending reclaim과 reconciliation으로 제한한다. Evidence가 일부만 지지하면 Claim을 축소한다.

다음을 주장하지 않는다.

- 모든 outage의 동일 예외·retry/DLQ 경로 또는 필수 3회 Retry
- production HA/SLA/RTO/RPO, capacity/durability 보장
- exactly-once, duplicate-free transport 또는 일반 loss-free recovery
- crash/corruption/storage-full/network partition 또는 결합 장애
- 다른 version/topology/workload/infrastructure의 동일 동작
- performance/soak/general recovery latency
- 과거 broker-2 OOM의 Root Cause

## 13. Reviewer decision fields

- Decision: `PENDING`
- Approval Reference: 미발급
- Approved exact HEAD: 미지정
- Approved envelope: 미지정
- Additional conditions: 없음

PASS라면 위 항목을 검증 가능한 Human context로 Run Record에 남긴다. Scope, Engineering Intent, authority/access, Risk, Blast Radius, acceptance criteria 또는 Claim Boundary가 바뀌면 이 package로 승인하지 않는다.
