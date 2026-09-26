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

## Operational Validation Documentation Closure Contract

BIP는 앞으로 운영 검증 시나리오의 문서 완료에 이 Project-level 계약을 적용한다. 재현 종료와 문서 완료는 서로 다른 책임이며, Reproduction Closure 이후 다음 순서로 진행한다. FR-001~005의 과거 산출물은 이 계약이 명문화되기 전에 작성되어 파일 구성이 다를 수 있다.

`Reproduction Closure → Scenario Communication Artifacts → Human Review / Confirmation → Scenario Documentation Complete → README Integration PENDING → Separate README Integration Responsibility`

각 시나리오의 Communication Artifact는 아래 네 파일이다.

1. `AI-USAGE-EXPLANATION.md` — AI 사용과 사람·AI 책임 경계
2. `SCENARIO-EXPLANATION.md` — 장애 원리, 관측 결과와 주장 한계
3. `HUMAN-RESPONSE-GUIDE.md` — 운영자의 진단·복구 판단
4. `README-SECTION-DRAFT.md` — 별도 README 통합 작업을 위한 후보 문안

`README-SECTION-DRAFT.md` 작성은 루트 `README.md` 수정의 승인이나 수행을 뜻하지 않는다. 루트 README 반영은 별도의 책임으로 라우팅한다. 세 상태 축은 독립적으로 기록한다.

| 상태 축 | 프로젝트 추적 값 | 판정 책임 |
|---|---|---|
| Reproduction | `OPEN` → 계약별 실행·검증 → `CLOSED / VERIFIED / SYNCHRONIZED` | 재현 계약, Record와 Evidence의 종료 판정 |
| Documentation | `PENDING HUMAN REVIEW` → `HUMAN CONFIRMED` | 네 Communication Artifact의 내용 검토·확인 |
| README Integration | `PENDING` → `INTEGRATED`; 명시적으로 제외된 경우 `BRANCH-ONLY / NOT PLANNED` | 별도 루트 README 통합·검증 또는 승인된 제외 범위 |

재현이 종료돼도 네 문서와 Human 확인이 없으면 Documentation은 `PENDING HUMAN REVIEW`로 둔다. 문서가 확인돼도 루트 README 통합이 예정된 경우 별도 완료 전까지 README Integration은 `PENDING`이다. 기존 branch-only trial처럼 루트 반영 제외가 명시된 산출물은 그 결정을 보존하며, 과거 상태를 소급해서 완료로 표시하지 않는다.

## Scenario Index

| Scenario | Failure Boundary | Result | Primary Report |
|---|---|---|---|
| BIP-FR-001 — Kafka Broker Unavailable During Active Scan | Active synthetic scan 중 local single Kafka broker unavailable | `REPRODUCED / RECONCILED` | [Technical Report](./failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/TECHNICAL-REPORT.md) |
| BIP-FR-002 — Kafka HA Single Broker Failure | Active scan 중 RF=3 Kafka의 partition leader broker 1개 SIGKILL | `STRICT PASS` | [Technical Report](./failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/TECHNICAL-REPORT.md) |

`REPRODUCED`는 승인된 장애가 관측 가능한 영향과 함께 재현되었다는 Workflow Outcome이고, `RECONCILED`는 해당 bounded run에서 백로그 소진과 identity-level end-to-end reconciliation이 완료되었다는 결과를 뜻합니다. `STRICT PASS`는 사전 계약의 시간 조건을 포함한 성공 기준과 최종 정합성 기준을 모두 충족했다는 BIP-FR-002 판정입니다. 이후 시나리오는 이 catalog에 항목을 추가하는 방식으로 확장합니다.

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

[Project README로 돌아가기](../../README.md)
