# BIP-FR-004 MySQL persistence unavailable 재현 계약

## 1. 계약 식별과 상태

- Contract ID: `BIP-FR-004-RC`
- Contract Revision: `BIP-FR-004-RC-R1`
- Previous Revision: 없음 — Initial Revision
- Scenario: `BIP-FR-004 — MySQL Persistence Unavailability During Active Scan`
- Source Revision: `3c405c1911d171c00e92b6be9e589c06a320ada1`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`, 2026-08-28)
- Revision Reason: Design 58의 승인 전 실행 의도, 실패 징후, 검증·Evidence·복구·안전 경계를 최초 Material Run 전에 고정
- Effective Point: 이 문서를 최초로 포함하는 R1 freeze commit. exact SHA는 Human Gate Package에서 식별한다.
- Contract Status: `FROZEN`
- Human Gate: `PENDING`
- Material Run Authorization: `NONE`

이 계약은 판정 대상 실행(Material Run) 전에 고정하는 실행·검증 경계다. 실행 결과에 맞춰 실패 징후(Failure Signature), 검증 기준(Verification Criteria), 정합성 또는 주장 경계(Claim Boundary)를 사후 완화하지 않는다. Material procedure redesign이 필요하면 R1을 덮어쓰지 않고 새 계약 개정(Contract Revision)을 만든다.

## 2. 관찰된 실패와 정의된 시나리오

### 2.1 관찰된 실패(Observed Failure)

MySQL이 unavailable한 동안 Persistence Worker가 Redis Stream record를 읽은 뒤 DB 접근에 실패할 수 있다. 성공 persistence나 승인된 terminal routing이 끝나지 않은 record를 조기에 XACK하면 소유권과 복구 가능성을 잃을 수 있으므로, 현재 구현이 원본 XACK을 보류하고 Redis 소비자 그룹의 보류 항목 목록(Pending Entries List, PEL)에 ownership을 유지하는지 검증한다.

이는 production incident의 재현 선언이 아니라 actual repository 구현에서 도출한 검증 대상 조건이다.

### 2.2 정의된 실패 시나리오(Defined Failure Scenario)

승인된 local/dev validation topology와 bounded active scan에서 기존 MySQL container만 일시 중단한다. Kafka, Processing과 Redis ingress를 유지한 채 Worker의 DB 접근 실패, XACK 보류와 PEL retention을 확인하고, 같은 MySQL container를 시작한 뒤 application restart 없이 new-flow persistence와 pending reclaim/reprocessing, 최종 identity reconciliation을 검증한다.

## 3. 정확한 Engineering Question

> 승인된 local/dev full pipeline에서 active scan 중 기존 MySQL container만 중단했을 때 Scanner에서 Redis Stream까지의 upstream 흐름은 계속되고, Worker가 fault interval record를 읽어 DB 접근에 실패한 경우 MySQL persistence와 조기 XACK 없이 해당 record가 PEL에 유지되는가? 같은 MySQL container의 availability를 복원하면 Worker restart나 설정 완화 없이 새 record persistence가 재개되고, 5분 minimum idle과 60초 pending scheduler 경계 안에서 기존 pending record가 reclaim/reprocessing되어 모든 accepted logical identity가 상호 배타적인 final state로 귀속되는가?

## 4. Scope와 Non-goals

### 4.1 포함 Scope

- 기존 전용 KRaft controller와 broker-only Kafka 3개
- Scanner → Ingest → Kafka → Processing → Redis Streams → worker-1/worker-2 → MySQL 전체 실제 경로
- 기존 MySQL service/container와 persistent volume
- Redis Stream `barcode:stream`, consumer group `barcode-persistence-group`, DLQ `barcode:stream:dlq`
- active traffic, MySQL unavailable, Worker DB failure, PEL ownership, same-container recovery, new flow, pending reclaim와 reconciliation
- logical identity, HTTP acceptance, Kafka/Redis/MySQL/DLT/DLQ/PEL final state 계량

### 4.2 Non-goals

- production availability, 서비스 수준 협약(Service Level Agreement, SLA), RTO/RPO 또는 capacity 보장
- MySQL HA, replication, failover, data corruption/loss/full 또는 schema migration 검증
- Kafka, Redis, Worker, Scanner, Ingest, Processing 또는 Docker daemon failure
- network partition, host failure, multi-component failure, 장시간 soak 또는 performance benchmark
- Worker retry 횟수, Hikari, pending idle/scheduler 설정 변경
- remediation, architecture 변경 또는 application behavior 변경
- 일반적인 exactly-once, duplicate-free transport 또는 loss-free guarantee
- 과거 broker-2 `OOMKilled=true / ExitCode=137`의 근본 원인(Root Cause) 판정

## 5. 승인 topology와 actual implementation

### 5.1 Minimum valid topology

| Component | 최소 조건 |
|---|---|
| Kafka | controller 1, broker 3 모두 UP; `barcode-events` 모든 partition ISR=3; URP 0; unavailable 0 |
| Applications | Scanner, Ingest, Processing, worker-1, worker-2 모두 기존 instance로 실행 |
| Redis | 기존 service UP; `barcode:stream`과 `barcode-persistence-group` 접근 가능 |
| MySQL | 기존 service/container healthy; 기존 volume과 schema 유지 |
| Terminal state | pre-run Kafka/Redis lag, PEL, DLQ, DLT가 baseline 판정에 적합 |

Worker 수를 줄이거나 Redis에 직접 record를 넣어 실행 규모를 줄이지 않는다. Traffic rate와 count만 Resource Preflight 결과에 따라 조절할 수 있다.

### 5.2 Frozen implementation facts

| 항목 | actual value / behavior |
|---|---|
| Worker instances | `worker-1`, `worker-2` |
| Worker batch / poll / block | `100` / `1000ms` / `5000ms` |
| Hikari | max pool `20`, min idle `5`, connection timeout `30000ms` |
| Pending scheduler | fixed delay `60000ms` |
| Pending minimum idle | `5분` |
| Save attempt ceiling | `MAX_SAVE_ATTEMPTS=3` |
| Mapping lookup | `deviceMappingRepository.findByDeviceIdIn()`이 `saveWithRetry()`보다 먼저 실행 |
| Outer DB failure | `processBatch()`와 `processPendingMessages()`의 `DataAccessException` catch는 원본 XACK을 수행하지 않음 |
| DLQ / ACK | DLQ XADD가 성공한 `originalRecordId`만 원본 XACK |
| Pending recovery | 양 Worker가 60초 주기로 5분 이상 idle인 pending을 claim하여 동일 처리 경로 재실행 |

따라서 `MySQL unavailable → 반드시 3 Retry → DLQ`를 expected path로 고정하지 않는다. Mapping lookup이 먼저 실패하면 `saveWithRetry()`에 진입하지 않고 바깥 catch로 빠져 PEL에 남을 수 있다.

## 6. Preconditions와 Resource Preflight

### 6.1 Repository / authority

1. branch가 `validation/bip-fr-004-mysql-persistence-unavailable`이다.
2. 실행 HEAD가 R1 Contract와 Human Gate가 승인한 exact revision이다.
3. working tree가 clean이고 unexpected local commit이 없다.
4. Material Run ID가 `BIP-FR-004-MR-<UTC>` 형식이며 정확히 `BIP-FR-004-RC-R1` 하나에 할당된다.
5. 권한 있는 Human의 Material Run Gate가 `PASS`이고 approval reference가 Run Record에 남는다.

### 6.2 Resource Preflight

Material Run 직전에 host CPU/memory pressure/disk, Docker CPU/memory/disk, container CPU/memory, health/restart/OOM, minimum topology를 read-only로 다시 확인한다. 다음이면 `FAIL`이며 MySQL을 중단하지 않는다.

- memory pressure가 critical이거나 swap/thrashing 징후가 실행 안전성을 설명할 수 없음
- repository filesystem available space가 `20 GiB` 미만
- Docker memory가 `5 GiB` 미만 또는 daemon 정보 조회 실패
- 필수 container가 running/required health 상태가 아님
- restart/OOM anomaly가 미해결 상태로 현재 baseline을 지배함
- Kafka ISR, URP, unavailable, application/Redis/MySQL readiness 또는 terminal backlog baseline 불충족

위 임계값은 production capacity 요구가 아니라 이 local Material Run을 시작하지 않기 위한 보수적인 안전 기준이다.

## 7. Controlled / intentionally changed conditions

### 7.1 Controlled conditions

- repository source, application image/config, Worker 수와 consumer name
- Kafka topology/topic/config/offset, Redis data/group/config, MySQL volume/schema/data
- Scanner/Ingest/Processing/Worker process lifecycle
- Hikari, retry, batch, poll, pending idle/scheduler 설정
- traffic driver retry 비활성화와 run-scoped logical identity 범위

### 7.2 Intentionally changed condition

유일한 의도적 상태 변경은 기존 Compose project의 `mysql` service를 stop하고 동일 container를 start하는 것이다. Container ID와 `/var/lib/mysql` volume source가 전후 동일해야 한다.

## 8. Proposed bounded envelope

Resource Preflight PASS를 전제로 다음 값을 Human Gate에 제안한다.

- traffic rate: 약 `5 logical scan requests/s`
- total traffic: `750 requests` 이내
- pre-fault warm-up: 최소 `30초`
- MySQL unavailable target: 약 `60초`
- readiness 복원 후 new traffic: 최소 `30초`
- pending observation: readiness 복원 후 최대 `7분`

실효 rate는 measured request timestamps로 판정하며 명목 5 requests/s를 performance claim으로 사용하지 않는다. Traffic은 fault 전·중·후를 하나의 연속 cohort로 유지한다.

## 9. 시간 술어(Temporal Predicate)

Material Run은 다음 네 조건을 timestamp와 identity/state Evidence로 함께 입증해야 한다.

- TP-1: `t_mysql_stop` 직전에 accepted scan이 존재한다.
- TP-2: MySQL unavailable interval에 신규 accepted logical identity가 존재한다.
- TP-3: fault interval에도 Processing → Redis Stream ingress가 증가한다.
- TP-4: 적어도 한 Worker가 fault interval의 run-scoped record를 실제 읽고 DB failure를 기록한다.

```text
t_scan_before
< t_mysql_stop
< t_scan_during
< t_mysql_start
< t_scan_after
```

Scanner HTTP 200은 buffer acceptance이며 MySQL persistence 성공을 뜻하지 않는다. Timestamp 순서만으로 충분하지 않고 run identity, Redis record ID, Worker log, PEL과 MySQL row를 연결한다.

## 10. 실패 징후(Failure Signature)

### FS-01 — Fault Authenticity

- fault 전 MySQL healthy와 exact container ID/volume을 캡처한다.
- stop 명령 이후 container stopped, MySQL ping/readiness failure와 unavailable interval을 확인한다.
- start 명령 이후 같은 container ID/volume과 readiness 회복을 확인한다.

### FS-02 — Upstream Failure Isolation

MySQL unavailable 동안 accepted scan, Kafka/Processing availability와 Redis Stream ingress 증가를 확인한다. 다른 component failure가 결과를 지배하면 유효한 실험으로 처리하지 않는다.

### FS-03 — Persistence Failure / Ownership Retention

주 실패 징후는 다음 전체 연결이다.

```text
run-scoped Redis record R read by Worker
→ DB access failure
→ R의 MySQL persistence 부재
→ R의 premature XACK 부재
→ PEL에서 R과 consumer ownership 유지
```

Worker의 count log만으로 R을 식별하지 않는다. `XPENDING` 상세의 stream ID와 `XRANGE` payload를 연결한다.

### FS-04 — Retry / DLQ / XACK

조건부 징후다. 실제로 `saveWithRetry()`에 진입한 run record만 다음 관계를 평가한다.

```text
PEL(R) → bounded Retry → exhausted
→ DLQ entry(originalRecordId=R) XADD success
→ original XACK(R)
```

해당 code path가 발생하지 않으면 `NOT OBSERVED / CODE PATH NOT REACHED`로 기록하며 R1 실패로 판정하지 않는다. DLQ count 증가만으로 correlation을 주장하지 않는다.

### FS-05 — Recovery

- MySQL readiness 복원 후 Worker restart 없이 post-recovery new-flow persistence가 성공한다.
- configuration relaxation이나 manual DB/Redis mutation이 없다.
- 5분 idle·60초 scheduler 경계 안에서 pending reclaim/reprocessing이 관측된다.

### FS-06 — Accountability

- accepted logical identity별 final state가 상호 배타적으로 귀속된다.
- `unaccounted=0`, `multi-state conflict=0`이다.
- 복구 완료(Recovery Complete)를 주장하려면 Redis pending이 0이다.

## 11. Verification Criteria

검증 순서는 바꾸지 않는다.

### 11.1 실험 유효성(Experiment Validity)

- exact approved branch/HEAD/R1, clean tree와 PASS Resource Preflight에서 시작했다.
- minimum topology와 실제 full pipeline을 유지했다.
- fault target은 기존 MySQL container 하나뿐이며 same-container recovery를 수행했다.
- temporal predicate TP-1~TP-4가 모두 충족됐다.
- prohibited action, unrelated failure 또는 unapproved mutation이 없다.

### 11.2 증거 충분성(Evidence Sufficiency)

- E0~E8 Evidence와 SHA-256 manifest가 존재한다.
- run-scoped logical identity를 Redis record ID, Worker DB error/PEL, MySQL/DLQ/DLT와 연결할 수 있다.
- stop/start와 readiness, new flow, pending reclaim, terminal reconciliation의 causal ordering을 재구성할 수 있다.

### 11.3 실패 징후 평가

- FS-01, FS-02, FS-03, FS-05, FS-06을 필수 평가한다.
- FS-04는 code path가 실제 발생한 record에만 평가하고 미발생을 실패로 바꾸지 않는다.
- 일부만 입증되면 그 제한을 숨기지 않는다.

### 11.4 Outcome

앞선 세 검증 뒤 다음 값 중 하나만 사용한다.

- `REPRODUCED`
- `PARTIALLY_REPRODUCED`
- `NOT_REPRODUCED`
- `INCONCLUSIVE`

## 12. Evidence requirements

| Group | Required Evidence |
|---|---|
| E0 Environment | Run/Contract identity, branch/HEAD/status, UTC boundaries, Resource Preflight, Compose/source hashes |
| E1 Baseline | container ID/state/volume, MySQL readiness, Kafka/application/Redis health, stream/group/PEL/DLQ, run-specific MySQL baseline |
| E2 Traffic | attempted/accepted/rejected, scanTime range, driver timestamps, pre/during/post-fault accepted identities |
| E3 Fault | MySQL stop/start command/time/exit, stopped/unavailable/readiness failure, same-container recovery/readiness |
| E4 Worker | Redis read, DB failure, PEL retention, conditional retry/DLQ/XACK, pending reclaim, new-flow persistence logs |
| E5 Redis | XLEN, XINFO GROUPS/CONSUMERS, XPENDING summary/detail, run-related XRANGE payload, DLQ entries and `originalRecordId` |
| E6 MySQL | run-scoped identity rows, unique count, absence during fault, post-recovery new flow, duplicate/conflict query |
| E7 Recovery | readiness, same identity/volume, Worker restart absence, new persistence, PEL drain and backlog convergence |
| E8 Reconciliation | identity별 mutually exclusive final-state table, totals, unaccounted/conflict/pending and claim limitations |

각 Evidence 디렉터리는 `BIP-FR-004-MR-<UTC>`이며 해당 Run은 R1 하나만 직접 참조한다. Raw output을 정규화하거나 사후 수정하지 않고 `MANIFEST.sha256`을 생성·검증한다. Credential 값은 캡처하지 않는다.

## 13. Recovery boundary

1. fault 전 MySQL container ID와 `/var/lib/mysql` volume source를 기록한다.
2. 승인된 한 번의 `stop mysql` 뒤 다른 component를 재시작하지 않는다.
3. 약 60초 fault window 뒤 같은 Compose context에서 `start mysql`을 한 번 실행한다.
4. container ID/volume 동일성과 `mysqladmin ping`, Worker readiness를 확인한다.
5. 새 post-recovery scan이 MySQL에 저장되는지 확인한다.
6. pending은 수동 ACK/claim하지 않고 application scheduler의 reclaim을 최대 7분 관찰한다.
7. PEL 0과 final reconciliation 전에는 `Recovery Complete`를 선언하지 않는다.

## 14. Reconciliation model

```text
N_attempted = N_accepted + N_explicit_rejected

N_accepted
= N_mysql
+ N_redis_dlq
+ N_kafka_dlt
+ N_redis_pending
+ N_unaccounted
+ N_multi_state_conflict
```

Final state는 `MYSQL_PERSISTED`, `REDIS_DLQ`, `KAFKA_DLT`, `REDIS_PENDING`, `UNACCOUNTED`, `MULTI_STATE_CONFLICT`로 구분한다. 같은 identity가 둘 이상의 terminal state에 있으면 각각 단순 합산하지 않고 `MULTI_STATE_CONFLICT`로 분리한다. `pending ≠ unaccounted`를 유지한다.

목표는 `N_unaccounted=0`, `N_multi_state_conflict=0`이다. `Recovery Complete`에는 추가로 `N_redis_pending=0`이 필요하다.

## 15. Authorized execution boundary

### 15.1 Human Gate PASS 후 허용 후보

- read-only preflight, state/log/query/Evidence capture
- bounded Scanner traffic
- 기존 MySQL service/container의 단일 stop
- 동일 MySQL service/container의 단일 start
- natural Worker pending reclaim 관찰
- run-scoped read-only reconciliation과 manifest 생성·검증

### 15.2 금지 action

- Human Gate PASS 전 MySQL stop/start 또는 Material Run
- `docker compose down`, `down -v`, `up --force-recreate`, container remove/recreate
- volume 삭제, schema/data 수동 변경, Redis Stream/PEL/DLQ 수동 mutation
- Kafka topic/offset/config mutation, Kafka/Redis/Worker/Scanner/Ingest/Processing restart 또는 fault
- Worker 수·consumer identity, retry/Hikari/batch/poll/pending timing 변경
- Docker daemon restart, network-wide fault, production/non-local 실행
- remediation, application code/config behavior 변경, Framework 변경 또는 Candidate promotion

## 16. Stop Conditions

- repository/branch/HEAD/working tree 또는 approval reference 불일치
- Resource Preflight FAIL 또는 minimum topology/readiness/backlog baseline 불충족
- Design 58과 actual implementation 사이 material mismatch
- Failure Signature/Verification Criteria/Claim Boundary 변경 필요
- MySQL 외 component failure 또는 unexpected restart/OOM이 결과를 지배
- same MySQL container/volume identity 불일치 또는 recreate 필요
- TP-1~TP-4, run identity, Redis record ID/PEL/MySQL correlation 확립 불가
- retry queue/consumer backlog/resource pressure가 safe envelope를 벗어남
- destructive/high-impact action, fault scope 또는 승인 경계 확대 필요
- 정본 Authority conflict 또는 Human-executable path와 runtime 불일치

Stop Condition이 활성화되면 추가 state-changing action을 하지 않는다. MySQL이 이미 stopped 상태라면 계약에 정한 same-container safety recovery만 수행하고, 해당 Run의 Deviation과 Outcome 가능 범위를 기록한다.

## 17. Claim Boundary

가능한 최대 주장은 다음 local bounded 조건으로 제한한다.

> 승인된 exact source와 R1 topology에서 active Scanner traffic 중 기존 MySQL container 하나만 일시 중단했을 때, run-scoped Redis record의 Worker DB 접근 실패와 XACK 보류·PEL retention을 직접 연결하고, 동일 MySQL container를 복구한 뒤 application restart나 설정 완화 없이 new-flow persistence와 natural pending reclaim/reprocessing, final reconciliation이 관측됐다는 주장.

실제 Material Run Evidence가 위 문장 일부만 지지하면 검증된 재현 주장(Verified Reproduction Claim)을 그 범위까지 축소한다.

## 18. Explicit Non-claims

- 모든 MySQL outage가 같은 예외·지연·retry/DLQ 경로를 만든다는 보장
- `3 Retry → DLQ`의 필수 발생 또는 DLQ가 primary recovery라는 주장
- production HA/SLA/RTO/RPO, data durability 또는 capacity 보장
- exactly-once, duplicate-free transport 또는 일반적인 loss-free recovery
- MySQL crash/corruption/storage-full/network-partition 동작
- Worker restart, Redis/Kafka failure 또는 결합 장애 복구
- 다른 version, topology, workload 또는 infrastructure의 동일 동작
- 5 requests/s 성능, 최대 backlog 또는 일반 recovery latency 보장
- 과거 broker-2 OOM 종료의 Root Cause

## 19. Human Gate

- Approval Target: `BIP-FR-004-RC R1 Material Run`
- Gate Status: `PENDING`
- Approval Reference: 아직 없음
- Authorized Approver: 이 repository와 local validation fault 실행에 권한 있는 Human
- 승인 대상: 8절 envelope 안의 bounded traffic, 기존 MySQL container 단일 stop/start, E0~E8 capture와 reconciliation
- 현재 허용 상태: Contract freeze와 execution preparation만 완료 가능

권한 있는 Human의 명시적 PASS 전에는 Material Run ID를 실행에 사용하거나 MySQL을 중단하지 않는다. 승인된 Intent, Scope, authority/access, Risk, Blast Radius, irreversible/high-impact action 또는 execution boundary가 material하게 바뀌면 R1 실행을 중단하고 새 Human Gate 판단을 요청한다.

## 20. Contract Revision과 Run 규칙

- 모든 Material Run은 정확히 하나의 식별 가능한 Contract Revision을 직접 참조한다.
- 최초 Material Run은 `BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R1`로 실행 전에 할당한다.
- 조건, 절차, Failure Signature, Verification Criteria 또는 Evidence 요구사항의 material redesign은 새 Revision으로 기록한다.
- 후속 Revision은 predecessor, effective point, reason, 정확한 변경과 기존 Human Gate 경계 안인지 여부를 기록한다.
- approval boundary를 바꾸지 않는 Revision은 새 Human Gate를 자동 요구하지 않지만, boundary 변경 여부가 불명확하면 실행을 중단한다.
