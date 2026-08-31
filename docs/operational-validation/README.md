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

`REPRODUCED`는 승인된 장애가 관측 가능한 영향과 함께 재현되었다는 Workflow Outcome이고, `RECONCILED`는 해당 bounded run에서 백로그 소진과 identity-level end-to-end reconciliation이 완료되었다는 결과를 뜻합니다. 이후 시나리오는 이 catalog에 항목을 추가하는 방식으로 확장합니다.

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

## Claim Boundary

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

[Project README로 돌아가기](../../README.md)
