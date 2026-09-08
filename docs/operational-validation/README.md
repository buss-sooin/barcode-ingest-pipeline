# Operational Validation

이 문서 영역은 `barcode-ingest-pipeline`에서 실제 장애 시나리오를 제한된 범위에서 재현하고, 장애 영향·진단·통제된 복구·백로그 수렴·종단 간 조정(End-to-end Reconciliation)을 Evidence 기반으로 검증한 결과를 관리합니다. 정상 상태의 처리 성능을 비교하는 benchmark와 달리, 구성 요소 장애가 시스템 경계에 미치는 영향과 복구 완료 조건을 다룹니다.

## System Context

검증 대상의 최소 처리 흐름은 다음과 같습니다.

```text
Scanner
→ Ingest
→ Kafka
→ Processing
→ Redis Streams
→ Persistence Worker
→ MySQL
```

- Kafka는 Ingest와 Processing 사이에서 유입을 완충하는 경계입니다.
- Redis Streams는 Processing과 Persistence Worker 사이에서 저장 측 처리를 완충하는 경계입니다.
- MySQL은 논리 이벤트가 최종 비즈니스 데이터로 영속화되는 경계입니다.

각 경계의 성공은 서로 다른 의미를 가집니다. 예를 들어 broker가 응답하는 상태, 메시지 흐름의 재개, 백로그 소진, MySQL까지의 최종 수렴은 별도로 확인해야 합니다.

## Validation Scope / Model

운영 장애 검증은 다음 lifecycle을 따라 장애 주입부터 최종 데이터 조정까지 확인합니다.

```text
Failure Injection
→ Observable Impact
→ Controlled Recovery
→ Flow Recovery
→ Backlog Convergence
→ End-to-end Reconciliation
```

Broker 또는 container가 다시 실행된 사실만으로 복구 완료(Recovery Complete)를 선언하지 않습니다. 실제 흐름이 재개되고, retry와 각 계층의 백로그가 수렴하며, 생성된 logical identity 전체가 설명 가능한 terminal state에 도달해야 합니다.

## Scenario Index

| Scenario | Failure Boundary | Result | Primary Report |
|---|---|---|---|
| BIP-FR-001 — Kafka Broker Unavailable During Active Scan | Active synthetic scan 중 local single Kafka broker unavailable | `REPRODUCED / RECONCILED` | [Technical Report](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/TECHNICAL-REPORT.md) |
| BIP-FR-002 — Kafka HA Single Broker Failure | Active scan 중 RF=3 Kafka의 partition leader broker 1개 SIGKILL | `STRICT PASS` | [Technical Report](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/TECHNICAL-REPORT.md) |
| BIP-FR-003 — Kafka Insufficient ISR Write Unavailability | Leader가 살아 있는 target partition에서 두 broker를 순차 중단해 ISR=1 < minISR=2 | `REPRODUCED` | [Technical Report](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/TECHNICAL-REPORT.md) |
| BIP-FR-004 — MySQL Persistence Unavailability | Active scan 중 MySQL만 중단해 Worker DB failure, Redis PEL ownership과 application reclaim 검증 | `PARTIALLY_REPRODUCED` | [Technical Report](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/TECHNICAL-REPORT.md) |

`REPRODUCED`는 승인된 장애가 관측 가능한 영향과 함께 재현되었다는 Workflow Outcome이고, `PARTIALLY_REPRODUCED`는 핵심 failure/recovery lifecycle은 검증됐지만 명시된 Evidence gap 때문에 최대 주장을 축소한 Outcome입니다. `RECONCILED`는 해당 bounded run에서 백로그 소진과 identity-level end-to-end reconciliation이 완료되었다는 결과를 뜻합니다. `STRICT PASS`는 사전 계약의 시간 조건을 포함한 성공 기준과 최종 정합성 기준을 모두 충족했다는 BIP-FR-002 판정입니다.

## BIP-FR-001 Highlight

### Scenario Boundary

- 격리된 로컬 Docker 환경
- 단일 Kafka broker
- active synthetic scan traffic
- Kafka unavailable: `57초`
- 보존된 동일 Kafka broker의 availability만 복원
- 다른 구성 요소 재시작, state 조작 또는 관련 없는 상태 복구 없음

### Observed Lifecycle

```text
Kafka unavailable
→ Ingest delivery confirmation failure
→ Scanner fallback / retry
→ downstream progression interruption
→ Kafka recovery
→ processing resumed
→ retry / backlog drain
→ end-to-end reconciliation
```

Kafka를 사용할 수 없는 동안 Ingest의 delivery confirmation failure와 Scanner의 fallback·retry가 활성화되고 Processing 이하의 신규 진행이 중단되었습니다. 동일 broker 복구 뒤 publish와 consume이 다시 시작되었고, retry와 백로그가 소진된 후 생성된 logical identity 전체가 MySQL의 unique persisted set으로 수렴했습니다.

### Quantitative Highlight

| Boundary | Result |
|---|---:|
| Logical events | `820` |
| Kafka transport records | `1,235` |
| Retry-induced transport duplicates | `415` |
| MySQL unique persisted | `820` |
| Final business duplicate rows | `0` |

Transport 경계의 수치는 다음 관계를 가집니다.

```text
1,235 Kafka transport records
= 820 logical events
+ 415 retry-induced transport duplicates
```

`1,235`는 logical event 수가 아니며, `415`는 최종 비즈니스 중복 행 수가 아닙니다. Retry로 동일 logical identity가 transport에서 반복 전달되었지만, Processing의 deduplication과 persistence 경계에서 `820`개의 unique identity로 수렴했습니다.

최종 조정 결과는 다음과 같습니다.

```text
Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

## BIP-FR-002 Highlight

### Scenario Boundary

- 격리된 로컬 Docker 환경
- 전용 KRaft controller 1개와 broker-only 3개
- `barcode-events`: partitions 3, 복제 계수(Replication Factor, RF) 3, `min.insync.replicas=2`
- producer `acks=all`, unclean leader election 비활성화
- active traffic과 시간적으로 겹친 partition 1 leader broker 2 SIGKILL
- broker 2만 같은 container와 volume으로 복구

### Observed Lifecycle

```text
active traffic
→ leader broker 2 SIGKILL / fencing
→ clean leader 2 → 3 / ISR 3 → 2
→ broker 2 DOWN 상태의 새 쓰기와 downstream 진행
→ 같은 volume의 broker 2 복구
→ ISR 3 / URP 0 / unavailable 0
→ 실행 범위 정합성 확인
```

주 검증 실행 `BIP-FR-002-MR-20260902T053228Z`는 `STRICT PASS`다. 장애 전 ISR member였던 broker 3이 새 leader가 됐고, 남은 ISR 두 개가 `min.insync.replicas=2`를 충족해 `acks=all` 새 쓰기와 downstream 처리가 재개됐다. 최초 실행 `BIP-FR-002-MR-20260902T043510Z`는 active traffic이 SIGKILL 201초 전에 끝난 편차 때문에 `Partial / Inconclusive Evidence`로 보존되며, Kafka HA·저하 상태 쓰기·복구 관측은 유효하다.

### Quantitative Highlight

```text
66 logical events
→ 75 Kafka records
→ 9 duplicate detections
→ 66 unique business results
```

추가 record 9개는 Scanner의 명시적 단건 폴백 7회와 HTTP client의 503 자동 재실행 2회에서 발생했다. Kafka leader election이 저장된 record를 독립적으로 다시 보냈다는 뜻이 아니다. Processing의 중복 제거(Deduplication) 뒤 MySQL unique 66, DLQ 0, DLT 0, pending 0, unaccounted 0, missing 0, extra 0, business duplicate 0으로 수렴했다.

## BIP-FR-003 Highlight

`BIP-FR-003-MR-20260902T114420Z`는 runtime에서 `P=1`, 최초 leader `L0=2`, 새 leader `L1=3`, 남은 follower `F1=1`을 발견했다. L0 중단 뒤 ISR=2에서 write가 성공했고, active traffic 중 F1을 중단해 leader 3은 살린 채 ISR size를 1로 낮췄다. 이때 고유 application witness는 HTTP 503과 `NotEnoughReplicasException`을 남기고 target offset을 증가시키지 않았다. F1 same-volume 복구로 ISR=2가 되자 새 write가 다시 성공했으며 L0 복구 뒤 ISR=3, URP=0, unavailable=0으로 수렴했다.

```text
54 logical identities
→ 53 Kafka unique + 1 expected rejection
→ 54 Kafka records(transport duplicate 1)
→ 53 MySQL unique + business duplicate 0 + unaccounted 0
```

R1 실행 2건은 각각 preflight inspection 오류와 ISR=2 안정화 절차 편차 때문에 `INCONCLUSIVE`로 보존했다. Material procedure redesign은 R2로 추적하며 승인된 Risk/Blast Radius는 바꾸지 않았다.

## BIP-FR-004 Highlight

`BIP-FR-004-MR-20260908T055225Z`는 active traffic 중 MySQL만 중단했을 때 Worker DB access failure와 Redis PEL 증가를 관찰했다. 같은 MySQL container/volume을 복구하자 Worker restart 없이 신규 persistence가 재개됐고, application-owned reclaim 뒤 PEL `132 → 0`, MySQL cohort `618 → 750`으로 수렴했다.

```text
MySQL availability failure
→ Worker DB access failure
→ PEL unfinished ownership 증가
→ MySQL availability recovery
→ new-flow persistence
→ application-owned reclaim
→ PEL drain
→ 750/750 terminal reconciliation
→ Recovery Complete
```

핵심 운영 교훈은 **`MySQL healthy ≠ Persistence Pipeline Recovery Complete`**다. MySQL readiness가 돌아온 뒤에도 이미 Worker에 전달된 unfinished work가 PEL에 남을 수 있다. `group lag=0`도 새 delivery backlog가 없다는 뜻일 뿐 PEL completion을 보장하지 않는다. Recovery Complete는 Worker processing, application reclaim, pending/group lag 수렴과 terminal reconciliation까지 확인한 뒤 판단한다.

Outcome은 `PARTIALLY_REPRODUCED`다. MySQL failure, Worker DB failure, PEL accumulation, same-container recovery, application reclaim activity, PEL drain과 accepted `750`건의 MySQL reconciliation은 검증됐다. 그러나 동일 Redis `RecordId` 하나를 `DB failure → no XACK → PEL → XCLAIM → persistence → XACK` 전체 사슬로 직접 연결하지 못했다. 이 Known Limitation은 closure blocker가 아니며 RC-R3나 추가 Material Run은 요구되지 않는다.

## Scenario Claim Boundaries

### BIP-FR-001

이 검증이 지지하는 최대 결론은 다음 범위입니다.

```text
bounded Kafka failure
→ observable impact
→ controlled recovery
→ backlog convergence
→ end-to-end reconciliation
```

이는 격리된 로컬 단일 broker 환경의 특정 Material Run 결과입니다. 다음을 주장하거나 보장하지 않습니다.

- exactly-once guarantee
- Kafka HA 또는 replicated availability
- production availability
- production RTO/RPO
- enterprise-grade Kafka availability
- storage-loss durability
- 다른 Kafka failure mode에서도 동일한 결과가 발생한다는 보장

### BIP-FR-002

BIP-FR-002는 승인된 로컬 토폴로지와 bounded traffic run에서 단일 controller가 유지되는 동안 partition 1 leader broker 2의 SIGKILL, pre-failure ISR member의 clean leader 선출, broker DOWN 중 새 쓰기·downstream 진행, 같은 volume 복구와 최종 identity reconciliation을 검증했다.

이는 일반적인 정확히 한 번 처리(exactly-once), 중복 없는 transport, production 고가용성(High Availability, HA)·서비스 수준 협약(Service Level Agreement, SLA)·복구 시간/시점 목표(RTO/RPO), controller HA, broker 2개 동시 장애, 네트워크·storage 장애, 임의 topic/partition, 결합 장애, 성능·장시간 soak 또는 다른 Kafka/client/인프라에서의 동일 동작을 보장하지 않는다. 정확한 최대 주장과 전체 비주장은 [BIP-FR-002 Technical Report](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/TECHNICAL-REPORT.md#17-최대-검증-주장)를 따른다.

### BIP-FR-003

BIP-FR-003는 승인된 로컬 R2 run에서 leader가 존재해도 ISR size 1이 topic minISR 2보다 작으면 `acks=all` application write가 성공 확인을 받지 못하고, follower 복구로 ISR size 2가 되면 설정 완화나 application restart 없이 write acceptance가 회복되는 경계를 검증했다.

이는 production HA/SLA/RTO/RPO, controller HA, 세 broker 동시 장애, network/storage failure, 일반 exactly-once, duplicate-free transport, 모든 topic/version/infra, 특정 SIGKILL 순간의 in-flight request, 성능·장시간 soak를 보장하지 않는다. 정확한 최대 주장과 비주장은 [BIP-FR-003 Technical Report](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/TECHNICAL-REPORT.md#16-maximum-verified-claim)를 따른다.

### BIP-FR-004

BIP-FR-004는 승인된 로컬 R2 run에서 active traffic 중 MySQL persistence unavailable 상태, Worker DB access failure와 PEL unfinished ownership 증가를 관찰했다. 동일 MySQL container/volume 복구 뒤 Worker restart나 설정 완화 없이 신규 persistence와 application-owned reclaim activity가 나타났고, PEL `0`, group lag `0`, MySQL unique `750`, DLQ/DLT/unaccounted/conflict `0`으로 수렴했다.

동일 Redis `RecordId`의 DB failure부터 최종 XACK까지의 전체 lifecycle을 직접 증명하지 않았으므로 Outcome은 `PARTIALLY_REPRODUCED`다. 이는 일반적인 exactly-once, production availability/SLA/RTO/RPO, 다른 DB·storage·network·복합 장애 또는 모든 retry/DLQ path를 보장하지 않는다. 정확한 최대 주장과 비주장은 [BIP-FR-004 Technical Report](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/TECHNICAL-REPORT.md#13-outcome-정밀도와-최대-검증-주장)를 따른다.

또한 이 영역은 문서의 의미·탐색·책임을 분리하지만, Artifact가 별도 Repository로 물리적으로 이동해도 수정 없이 동작한다는 portability를 검증하지 않습니다.

## BIP-FR-001 Artifact Navigation

| Artifact | Responsibility |
|---|---|
| [Technical Report](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/TECHNICAL-REPORT.md) | 전체 Engineering synthesis와 최대 검증 결론 |
| [Reproduction Record](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/REPRODUCTION-RECORD.md) | 실행 이력, Evidence, 유효성 판정과 claim boundary |
| [Operational Diagnostic Guide](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/OPERATIONAL-DIAGNOSTIC-GUIDE.md) | 최초로 끊어진 경계(First Broken Boundary)와 진단 reasoning |
| [Kafka Failure Learning Note](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/KAFKA-FAILURE-LEARNING-NOTE.md) | 장애 메커니즘, retry와 duplicate semantics |
| [Runbook](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/RUNBOOK.md) | 장애 진단과 통제된 운영 복구 절차 |
| [AI ↔ Human Resolution Mapping](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/AI-HUMAN-RESOLUTION-MAPPING.md) | 책임, escalation과 resolution boundary |

## BIP-FR-002 Artifact Navigation

| Artifact | Responsibility |
|---|---|
| [Technical Report](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/TECHNICAL-REPORT.md) | Kafka HA 전이, 중복 책임, 복구·정합성과 최대 검증 결론 |
| [Reproduction Record](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/REPRODUCTION-RECORD.md) | 두 Material Run의 역할, 편차, 시간선과 Evidence → Claim mapping |
| [Reproduction Contract](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/REPRODUCTION-CONTRACT.md) | 실행 전에 승인된 조건·판정 기준과 lifecycle 결과 navigation |
| [First Material Run Evidence](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/evidence/BIP-FR-002-MR-20260902T043510Z/) | `Partial / Inconclusive Evidence`와 SHA-256 manifest |
| [Strict Material Run Evidence](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/evidence/BIP-FR-002-MR-20260902T053228Z/) | `STRICT PASS` 주 실행 증거와 SHA-256 manifest |

## BIP-FR-003 Artifact Navigation

| Artifact | Responsibility |
|---|---|
| [Technical Report](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/TECHNICAL-REPORT.md) | insufficient ISR 의미, application failure, recovery·retry·정합성과 최대 검증 주장 |
| [Reproduction Record](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/REPRODUCTION-RECORD.md) | R1/R2 lineage, 세 Material Run, 편차, Verification과 Evidence mapping |
| [Reproduction Contract](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/REPRODUCTION-CONTRACT.md) | 승인된 사전 조건·실패 징후·안전·판정 경계 |
| [R1 Preflight Evidence](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/evidence/BIP-FR-003-MR-20260902T112532Z/) | 주입 전 `INCONCLUSIVE` 이력과 manifest |
| [R1 Stabilization Evidence](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/evidence/BIP-FR-003-MR-20260902T113950Z/) | ISR=2 절차 편차 `INCONCLUSIVE` 이력과 manifest |
| [R2 Material Run Evidence](./failure-reproduction/BIP-FR-003-kafka-insufficient-isr/evidence/BIP-FR-003-MR-20260902T114420Z/) | `REPRODUCED` 주 실행 증거와 manifest |

## BIP-FR-004 Artifact Navigation

| Artifact | Responsibility |
|---|---|
| [Technical Report](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/TECHNICAL-REPORT.md) | MySQL persistence failure 진단, PEL/reclaim 의미, 복구·정합성과 최대 검증 주장 |
| [Reproduction Record](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/REPRODUCTION-RECORD.md) | R1/R2 lineage, 일곱 Material Run, 편차, closure와 Evidence mapping |
| [Reproduction Contract R2](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/REPRODUCTION-CONTRACT-R2.md) | 승인된 R2 조건, failure signature, Evidence·Recovery Complete 판정 경계 |
| [R2 Material Run Evidence](./failure-reproduction/BIP-FR-004-mysql-persistence-unavailable/evidence/BIP-FR-004-MR-20260908T055225Z/) | `PARTIALLY_REPRODUCED` 주 실행 증거와 manifest |

[Project README로 돌아가기](../../README.md)
