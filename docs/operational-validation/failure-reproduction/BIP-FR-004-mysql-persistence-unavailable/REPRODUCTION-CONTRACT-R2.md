# BIP-FR-004 MySQL persistence unavailable 재현 계약 R2

## 1. 계약 식별과 개정 이력

- Contract ID: `BIP-FR-004-RC`
- Contract Revision: `BIP-FR-004-RC-R2`
- Previous Revision: `BIP-FR-004-RC-R1`
- Scenario: `BIP-FR-004 — MySQL Persistence Unavailability During Active Scan`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`)
- Contract Status: `FROZEN`
- Effective Point: 이 파일을 최초로 포함하는 RC-R2 canonicalization commit
- Revision Reason: R1 실행에서 확인된 pending reclaim 결함과 수동 단계 전이의 증거 공백을 닫고, 수정된 application-owned reclaim 및 단계 controller를 판정 대상 실행(Material Run) 전에 고정
- 기존 사람 승인 관문(Human Gate) 경계 안의 변경 여부: `YES`
- Material Run Authorization: `SUSPENDED` — `00J`의 readiness 검토와 별도 복원 결정 전에는 실행하지 않음

R1은 [R1 Contract](./REPRODUCTION-CONTRACT.md)와 [Reproduction Record](./REPRODUCTION-RECORD.md)에 역사적으로 보존한다. R2는 R1의 Scope, 의도적 장애 대상, 위험/영향 반경(Risk/Blast Radius), 수락 기준과 주장 경계를 확대하지 않는다. 변경 책임은 실제 구현에 맞는 reclaim 의미, versioned runtime identity, 실행 단계·Evidence 전이의 결정성에 한정된다.

정확한 R2 승인 시각이나 별도 approval ID는 repository Evidence에서 독립적으로 확인되지 않으므로 만들지 않는다. 추적 가능한 승인 참조는 `00I — 2026-09-04 Human approval`과, 승인 경계가 유지된다는 `00J` Control Plane 결정이다.

## 2. Source와 runtime release 결속

| 역할 | 식별자 | 의미 |
|---|---|---|
| Application source baseline | `fc36250cf9b90d0e59780ae26e0c6399fc3494c2` | explicit pending ID, bounded pagination, DB 성공 후 ACK semantics를 구현·검증한 source revision |
| Runtime release revision | `1ed4675e0d39c05a9656f46c44a76e520cf2c8c1` | versioned container delivery와 release identity를 추가한 revision |
| Git relationship | `parent(1ed4675...) = fc36250...` | runtime release가 reclaim source baseline을 직접 포함함 |
| Worker image reference | `bip/persistence-worker:1ed4675e0d39c05a9656f46c44a76e520cf2c8c1` | R2 실행에서 두 Worker가 함께 사용해야 하는 image |
| Worker image ID | `sha256:b1183529237795e3b92945e21c097224d4246a2ef0e6ac93cb33d748ee8719ec` | release manifest와 runtime에서 다시 확인할 local image identity |

Repository checkout의 canonicalization HEAD와 runtime release revision은 역할이 다르다. 미래 Run은 E0에서 계약·Record가 포함된 approved HEAD, 위 source/release ancestry, release manifest, 두 container의 image reference/ID와 `org.opencontainers.image.revision`을 각각 기록한다. 서로를 동일 revision으로 표현하지 않는다.

## 3. 관찰된 실패와 정의된 실패 시나리오

### 3.1 관찰된 실패(Observed Failure)

R1의 세 번째 Run은 MySQL unavailable 중 Worker의 device mapping 조회가 `DataAccessException`으로 종료되는 현상과 PEL 형성을 직접 관측했다. Repository code는 이 outer failure 경로에서 XACK하지 않는 책임 경계를 보여 주지만, Run의 raw Evidence만으로 모든 실패 record의 identity-level no-XACK 관계를 직접 입증하지는 못했다. 이후 기존 reclaim 구현은 pending ID 없이 claim을 호출해 `MessageIds must not be empty`로 실패했으며 application-owned recovery가 진행되지 않았다.

이 관측은 R1의 성공 Outcome이 아니다. R1은 실험 유효성과 Evidence 완결성이 부족하여 `INCONCLUSIVE`로 보존한다.

### 3.2 정의된 실패 시나리오(Defined Failure Scenario)

승인된 local/dev full pipeline과 bounded active Scanner traffic에서 기존 MySQL container 하나만 일시 중단한다. Upstream ingress를 유지한 채 run-scoped record의 DB 접근 실패, 조기 XACK 부재와 PEL retention을 연결한다. 같은 container를 복구한 뒤 Worker restart나 설정 완화 없이 new-flow persistence와 다음 application-owned reclaim을 검증한다.

```text
mapping lookup failure
→ original XACK 없음
→ PEL retention
→ 동일 MySQL container recovery
→ pending idle >= 5분
→ 60초 scheduler
→ explicit RecordId 기반 XCLAIM
→ 기존 persistence path
→ MySQL persistence 성공
→ XACK
```

`MySQL down → 반드시 3 Retry → DLQ`는 R2의 expected path가 아니다. `saveWithRetry()`보다 앞선 mapping lookup이 실패할 수 있기 때문이다. `Retry → DLQ → XACK`은 실제로 해당 code path에 진입한 record에만 조건부로 평가한다.

## 4. 정확한 Engineering Question

> 승인된 source/release와 local full pipeline에서 active scan 중 기존 MySQL container 하나만 중단했을 때, fault-window record의 mapping lookup DB failure가 MySQL persistence 부재·조기 XACK 부재·PEL retention으로 이어지는가? 같은 container를 복구하면 Worker restart나 설정 완화 없이 new flow가 저장되고, 5분 minimum idle 뒤 scheduler가 explicit pending ID로 record를 claim하여 기존 persistence path로 처리한 후에만 XACK하며, 최종 accepted identity가 충돌이나 미확인 상태 없이 reconcile되는가?

## 5. Scope, Preconditions와 Conditions

### 5.1 포함 Scope와 minimum topology

- Scanner → Ingest → Kafka → Processing → Redis Streams → `worker-1`/`worker-2` → MySQL 실제 경로
- 전용 KRaft controller 1개, broker-only Kafka 3개, `barcode-events` 전체 ISR 정상, URP 0, unavailable partition 0
- Redis Stream `barcode:stream`, consumer group `barcode-persistence-group`, DLQ `barcode:stream:dlq`
- 동일 release image를 사용하는 Worker 2개와 기존 MySQL container/volume
- active traffic, MySQL unavailable, DB failure, PEL ownership, same-container recovery, explicit-ID reclaim, persistence, XACK와 identity reconciliation

### 5.2 Preconditions

1. branch가 `validation/bip-fr-004-mysql-persistence-unavailable`이고 R2 canonicalization commit이 approved HEAD로 고정돼 있다.
2. working tree가 clean하며 Material Run은 정확히 `BIP-FR-004-RC-R2` 하나를 직접 참조한다.
3. 기존 사람 승인 관문 경계가 유효하고 `00J`가 `NEW MATERIAL RUN AUTHORIZATION`을 복원했다.
4. Resource Preflight가 PASS이며 MySQL, Redis, Kafka와 모든 application component가 healthy다.
5. Redis PEL=0, group lag=0, Redis DLQ=0, Kafka DLT=0에서 시작한다.
6. 두 Worker가 2절의 동일 image reference/ID/revision으로 running이며 actuator health가 `UP`이다.
7. R2 phase controller가 Run ID, approved HEAD, gate reference와 이 Contract hash를 register할 수 있다.

### 5.3 Controlled conditions

- repository source, runtime image/config, Worker 수와 consumer identity
- Kafka topology/topic/config/offset, Redis data/group/config, MySQL volume/schema/data
- Scanner/Ingest/Processing/Worker process lifecycle
- retry/Hikari/batch/poll, pending 5분 minimum idle와 60초 scheduler 설정
- traffic driver retry 비활성화와 run-scoped logical identity

### 5.4 Intentionally varied condition

의도적으로 바꾸는 조건은 **기존 Compose project의 MySQL availability 하나뿐**이다. Fault는 exact existing MySQL container의 stop, recovery는 동일 container의 start다. Container ID와 `/var/lib/mysql` volume source가 전후 동일해야 한다.

## 6. 시간 술어(Temporal Predicate)와 fault 경계

```text
t_scan_before
< t_mysql_stop
< t_scan_during
< t_mysql_start
< t_scan_after
< t_reclaim_eligible
<= t_xclaim
< t_persistence
< t_xack
```

- fault 직전, fault interval, recovery 이후에 각각 accepted run-scoped identity가 있어야 한다.
- fault interval에도 Processing → Redis ingress 증가와 Worker의 run-scoped record read가 확인돼야 한다.
- MySQL stop 직전 traffic process와 log freshness를 재검증하고, traffic overlap이 없으면 stop을 수행하지 않는다.
- MySQL stop/start는 각각 승인된 exact container에 한 번만 수행한다.
- `t_xclaim`은 pending record의 idle이 5분 이상인 뒤여야 하며, scheduler 주기를 존중한다.

## 7. 실패 징후(Failure Signature)

### FS-1 — Fault authenticity

Fault 전 MySQL healthy, exact container ID/volume을 기록한다. Stop 뒤 container stopped와 readiness failure, start 뒤 동일 container/volume과 readiness 회복을 확인한다.

### FS-2 — Upstream isolation

MySQL unavailable 중 accepted scan, Kafka/Processing availability와 Redis Stream ingress 증가를 확인한다. 다른 component failure가 결과를 지배하면 유효한 실험이 아니다.

### FS-3 — Persistence failure와 ownership retention

```text
run-scoped Redis record R을 Worker가 읽음
→ mapping lookup DB failure
→ R의 MySQL persistence 부재
→ premature XACK 부재
→ PEL에서 R과 consumer ownership 유지
```

Worker count log만으로 R을 식별하지 않고 `XPENDING` stream ID, `XRANGE` payload, business identity와 MySQL 조회를 연결한다.

### FS-4 — Application-owned reclaim과 ACK 경계

MySQL recovery 뒤 idle 5분 이상인 명시적 `RecordId`를 bounded page로 조회하고 non-empty ID만 XCLAIM한다. Claim된 record는 기존 persistence path를 사용하며 MySQL 성공 뒤에만 원본을 XACK한다. DB failure면 XACK하지 않는다.

실제로 `saveWithRetry()`에 진입한 record만 bounded Retry와 DLQ XADD 성공 뒤 XACK 순서를 조건부 평가한다. 미진입은 `NOT OBSERVED / CODE PATH NOT REACHED`로 기록한다.

### FS-5 — Recovery와 accountability

- Worker restart 없이 post-recovery new-flow persistence가 성공한다.
- PEL이 application scheduler에 의해 0으로 수렴하고 group lag, Redis DLQ, Kafka DLT가 설명된 terminal 값으로 수렴한다.
- `unaccounted=0`, `multi_state_conflict=0`, `pending=0`이다.

## 8. 검증 기준(Verification Criteria)

다음 순서를 바꾸지 않는다.

### 8.1 실험 유효성(Experiment Validity)

- approved R2 HEAD/branch/clean tree, PASS Resource Preflight와 minimum topology에서 시작한다.
- full pipeline, 두 Worker와 exact runtime release identity를 유지한다.
- MySQL availability만 변경하고 same-container recovery를 수행한다.
- 6절 temporal predicate와 phase controller 전이가 모두 충족된다.
- 금지 action, unrelated OOM/restart 또는 다른 infrastructure failure가 결과를 지배하지 않는다.

### 8.2 증거 충분성(Evidence Sufficiency)

- E0~E8과 검증되는 `MANIFEST.sha256`이 존재한다.
- run identity를 traffic, Redis record ID, Worker DB failure/PEL, explicit-ID XCLAIM, MySQL persistence와 XACK에 연결할 수 있다.
- stop/start, post-recovery new flow, reclaim eligibility와 final reconciliation의 인과 순서를 재구성할 수 있다.

### 8.3 실패 징후 평가

- FS-1~FS-5를 record 단위 Evidence로 평가한다.
- conditional Retry/DLQ path의 미발생을 실패로 바꾸지 않는다.
- 일부만 입증되면 `Directly Proven`, `Strongly Inferred`, `Unresolved`로 구분한다.

### 8.4 Outcome

앞선 세 평가 뒤 `REPRODUCED`, `PARTIALLY_REPRODUCED`, `NOT_REPRODUCED`, `INCONCLUSIVE` 중 하나만 사용한다. HTTP 오류나 PEL 감소만으로 Outcome을 정하지 않는다.

## 9. Evidence 요구사항

| Group | Required Evidence |
|---|---|
| E0 Environment | Run→R2 mapping, approved HEAD/status, Contract/controller/traffic hash, source→release ancestry, manifest, image reference/ID/revision label, Resource Preflight |
| E1 Baseline | container state/ID/volume, MySQL read, Kafka/Redis/application health, PEL/lag/DLQ/DLT와 run-specific MySQL baseline |
| E2 Traffic | attempted/accepted/rejected, run-scoped identity range, driver start/end와 pre/during/post timestamps |
| E3 Fault | traffic overlap revalidation, MySQL stop/start time/exit, stopped/readiness failure, same-container/volume recovery |
| E4 Worker | run record read, mapping lookup DB error, no-ACK evidence, scheduler/candidate IDs, XCLAIM, persistence와 ACK logs |
| E5 Redis | XLEN, XINFO GROUPS/CONSUMERS, XPENDING summary/detail, XRANGE payload, ownership/delivery count, DLQ와 `originalRecordId` |
| E6 MySQL | run identity absence/presence, unique count, post-recovery new flow, duplicate/conflict query |
| E7 Recovery | readiness, Worker restart 부재, reclaim eligibility/deadline, PEL progression과 terminal health |
| E8 Reconciliation | identity별 mutually exclusive final state, accepted/mysql/dlq/dlt/pending/unaccounted/conflict cardinality |

Raw Evidence는 사후 수정하지 않는다. Run-scoped directory의 모든 파일을 상대 경로로 열거한 SHA-256 manifest를 생성하고 다시 검증한다. Credential 값은 캡처하지 않는다.

## 10. Recovery Complete와 reconciliation

MySQL이 running이거나 PEL이 감소한 사실만으로 복구 완료(Recovery Complete)를 선언하지 않는다. 다음이 모두 필요하다.

1. 같은 MySQL container/volume의 readiness와 실제 read가 회복된다.
2. Worker restart 없이 post-recovery identity가 MySQL에 저장된다.
3. eligible pending이 explicit-ID XCLAIM을 거쳐 저장되고 XACK된다.
4. PEL=0, group lag=0, Redis DLQ=0, Kafka DLT=0 또는 사전 정의된 설명 가능한 terminal 값으로 수렴한다.
5. 아래 reconciliation에서 `unaccounted=0`, `multi_state_conflict=0`, `pending=0`이다.

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

`pending ≠ unaccounted`를 유지한다. 동일 identity가 여러 상태에 있으면 단순 중복 합산하지 않고 `MULTI_STATE_CONFLICT`로 분리한다.

## 11. 실행 경계, 금지 action과 Stop Conditions

### 11.1 Authorization 복원 뒤 허용되는 bounded action

- read-only preflight, runtime/Evidence capture와 phase controller 기록
- bounded Scanner traffic
- exact existing MySQL container의 단일 stop과 동일 container의 단일 start
- application-owned pending reclaim 관찰
- run-scoped read-only reconciliation과 manifest 생성·검증

### 11.2 금지 action

- `00J`의 명시적 authorization 복원 전 register, traffic, MySQL stop/start 또는 Material Run
- `docker compose down`, `down -v`, container remove/recreate, volume 삭제
- schema/data 수동 변경, Redis PEL/Stream/DLQ 수동 mutation, manual XCLAIM/XACK
- Kafka topic/offset/config mutation, Kafka/Redis/Worker/application restart 또는 fault
- Worker 수/consumer identity, retry/Hikari/batch/poll/pending timing 변경
- Docker daemon restart, network-wide fault, production/non-local 실행
- source/config 변경, remediation, Framework 변경 또는 별도 failure scenario 추가

### 11.3 Stop Conditions

- branch/approved HEAD/clean tree/Contract hash/gate reference 불일치
- Resource Preflight 또는 minimum runtime baseline 불충족
- traffic process/log freshness 또는 temporal overlap 불충족
- MySQL target ID/volume 불일치, recreate 필요 또는 MySQL 외 component failure
- explicit pending ID, record payload, DB failure, persistence, XACK correlation 불가
- reclaim deadline 초과, PEL 미수렴, DLQ/DLT 증가 또는 identity reconciliation 불가
- unrelated restart/OOM/resource pressure가 결과를 지배
- destructive action, Scope/Risk/Blast Radius/claim boundary 확대 또는 Authority conflict

Stop Condition이 활성화되면 후속 state-changing phase를 시작하지 않는다. MySQL이 이미 stopped이면 계약에 정한 same-container safety recovery만 수행하고 Deviation을 보존한다.

## 12. 주장 경계(Claim Boundary)

가능한 최대 주장은 다음 local bounded scenario로 제한한다.

> 승인된 R2 source/release와 local full pipeline에서 active Scanner traffic 중 기존 MySQL container 하나만 일시 중단했을 때, run-scoped record의 mapping lookup DB failure가 조기 XACK 없이 PEL ownership retention으로 이어지고, 같은 MySQL container를 복구한 뒤 application restart나 설정 완화 없이 new flow가 저장되며, 5분 이상 idle인 explicit pending ID가 application scheduler에 의해 XCLAIM되어 persistence 성공 후 XACK되고 최종 identity reconciliation이 완료됐다는 주장.

실제 Evidence가 일부만 지지하면 검증된 재현 주장(Verified Reproduction Claim)을 그 범위까지 축소한다.

## 13. 명시적 비주장(Explicit Non-claims)

- 모든 MySQL outage가 같은 예외·지연·Retry/DLQ 경로를 만든다는 보장
- `3 Retry → DLQ`의 필수 발생 또는 DLQ가 primary recovery라는 주장
- production HA/SLA/RTO/RPO, data durability, capacity 또는 일반 recovery latency 보장
- exactly-once, duplicate-free transport 또는 일반적인 loss-free recovery
- MySQL crash/corruption/storage-full/network-partition 동작
- Worker restart, Redis/Kafka failure 또는 결합 장애 복구
- 다른 version, topology, workload 또는 infrastructure의 동일 동작
- 과거 broker OOM의 근본 원인(Root Cause)
- R1 후속 baseline recovery 검증을 R2 Material Run Outcome으로 재분류하는 주장

## 14. 사람 승인 관문(Human Gate)과 Run mapping

- Existing Approval Reference: `00I — 2026-09-04 Human approval`
- Boundary Continuity Reference: `00J — RC-R2 freeze 및 기존 approval 유지 결정`
- Authorized Approver: 이 repository와 local validation fault 실행에 권한 있는 Human
- Approved boundary: bounded traffic, existing MySQL container 단일 stop/start, application-owned reclaim 관찰, E0~E8과 reconciliation
- New Human Gate required: `NO`, 단 승인 경계가 material하게 바뀌지 않는 조건
- Current execution authority: `NEW MATERIAL RUN AUTHORIZATION = SUSPENDED`

미래 Run은 authorization 복원 뒤 register 시점에 다음 관계를 실제 Run ID로 한 번만 확정한다.

```text
BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R2
```

Placeholder는 Run 등록이 아니다. 모든 Material Run은 정확히 하나의 Revision만 참조한다. R2의 procedure, Failure Signature, Verification Criteria, Evidence 요구사항 또는 승인 경계를 material하게 바꿔야 하면 R2를 덮어쓰지 않고 새 Revision과 필요한 Human Gate 판단을 사용한다.
