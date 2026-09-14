# BIP-FR-005 Redis Streams 불가 재현 계약 R1

## 1. 정본 책임과 계약 식별

이 문서는 `BIP-FR-005 — Redis Streams Unavailability`의 판정 대상 실행(Material Run) 전에 동결된 실행·검증 경계를 보존하는 정본 재현 계약(Reproduction Contract)이다. 실행 결과에 맞춰 실패 징후(Failure Signature), 검증 기준(Verification Criteria), Evidence 요구사항 또는 주장 경계를 사후 변경하지 않는다.

| 항목 | 값 |
|---|---|
| Scenario ID | `BIP-FR-005` |
| Contract ID | `BIP-FR-005-RC` |
| Contract Revision | `R1` |
| Full Identifier | `BIP-FR-005-RC-R1` |
| Status | `FROZEN` |
| Material Run | `NOT EXECUTED` |
| Outcome | 미배정 |
| Verified Reproduction Claim | 없음 |
| Workflow | Failure Reproduction Workflow v0.1 (`Effective`, 2026-08-28) |

`BIP-FR-005-RC-R1`은 하나의 식별 가능한 계약 개정(Contract Revision)이다. 아직 Material Run과 Run ID는 존재하지 않으며 이 문서의 placeholder나 향후 실행 예시는 Run 등록으로 간주하지 않는다.

## 2. 구현 기준선(Implementation Baseline)

- Independent As-Built Review: `PASS WITH LIMITATION`
- 등록 시 관찰한 repository branch: `validation/bip-fr-004-mysql-persistence-unavailable`
- 등록 시 관찰한 repository HEAD: `57b59577ac856d664fd69f5a6c4867f1f583be8c`
- 등록 시 working tree: `DIRTY` — 선행 FR-005 구현으로 보이는 source, configuration, test 변경이 존재함
- 정확한 immutable implementation/release identity: `NOT YET REGISTERED`

위 HEAD는 등록 시 checkout의 base commit을 식별할 뿐, uncommitted working-tree 구현 전체의 identity라고 주장하지 않는다. 기존 repository/Evidence에서 독립 검토 대상 구현을 정확히 하나의 commit, tree 또는 release로 연결하는 locator는 확인되지 않았으므로 추측하여 만들지 않는다.

후속 Material Run 등록·실행 준비는 실행 대상의 정확한 branch, HEAD, working-tree 상태, source-to-release 또는 image identity와 이 계약의 의미적 동일성을 Evidence로 고정해야 한다. 기준선 드리프트가 확인되거나 동일성을 입증할 수 없으면 해당 실행을 R1 판정 Evidence로 사용하지 않는다.

## 3. 시나리오와 동결된 lifecycle

### 3.1 실패 시나리오

Active traffic 중 Redis가 실제로 unavailable인 상태를 만들고, `barcode-events` 소비 이후 Redis Streams handoff가 실패할 때 source retry, Kafka DLT, 제한된 disposition과 Redis 복구 이후의 source 재처리를 관찰한다. 의도적으로 변화시키는 장애 영역은 Redis availability뿐이다.

### 3.2 Primary lifecycle

```text
barcode-events
→ Redis handoff failure
→ source retry
→ barcode-events-dlt
→ bounded disposition
```

### 3.3 Transient lifecycle

```text
TRANSIENT_REDIS
→ generation 0
→ replay once
→ barcode-events
→ Redis handoff recovery
```

### 3.4 Permanent lifecycle

```text
PERMANENT_VALIDATION
→ quarantine
→ barcode-events-quarantine
```

### 3.5 Unknown 또는 malformed metadata

```text
UNKNOWN
or malformed disposition metadata
→ fail closed
→ quarantine
```

## 4. 분류와 재생 한계

- 허용된 failure classification vocabulary는 `TRANSIENT_REDIS`, `PERMANENT_VALIDATION`, `UNKNOWN`뿐이다.
- `PermanentEventValidationException`은 재시도로 의미가 바뀌지 않는 validation failure이며 source retry를 우회한다.
- Redis 연결 실패는 `TRANSIENT_REDIS`로 분류한다.
- 인식할 수 없는 예외, 누락되거나 인식할 수 없는 classification은 `UNKNOWN`으로 취급한다.
- 누락된 replay count는 generation `0`으로 정규화한다.
- 음수, 숫자가 아닌 값 또는 해석 불가능한 replay count는 malformed metadata이며 fail closed로 quarantine한다.
- `MAX_DLT_REPLAY_ATTEMPTS = 1`이다.
- `TRANSIENT_REDIS` generation `0`만 generation `1`로 한 번 replay할 수 있다.
- replay count가 이미 `1` 이상이면 다시 replay하지 않고 quarantine한다.
- quarantine record는 replay하지 않는다.

## 5. One-shot disposition과 DLT offset 정산

DLT disposition은 한 번의 제한된 실행(one-shot bounded execution)이다. 실행 시작 시 소유한 모든 DLT partition의 end offset snapshot을 partition별로 고정하고, 같은 execution에서는 다음 조건을 만족하는 record만 처리한다.

```text
offset < startup snapshot end
```

시작 snapshot 이후 DLT에 append된 record를 같은 execution의 backlog에 재귀적으로 포함하지 않는다. disposition 중 partition ownership이 바뀌거나 모든 partition을 배타적으로 소유하지 못하면 부분 완료를 성공으로 간주하지 않는다.

각 DLT record의 offset 정산 순서는 다음과 같다.

```text
classify
→ publish replay/quarantine
→ publication success
→ commitSync(DLT offset + 1)
```

publication failure 이전에는 해당 DLT offset을 성공 처리로 commit하지 않는다.

Kafka output publication과 DLT offset commit은 transactional하지 않다. publication 성공 뒤 commit이 실패하면 같은 generation의 duplicate output이 생길 수 있으므로 정확히 한 번 재생(exactly-once replay)을 주장하지 않는다. Material Run은 이 duplicate 가능성을 숨기지 않고 실제 관측 결과를 기록한다.

## 6. 실패 징후(Failure Signature)

Signature의 수, 이름과 판정 강도는 R1에서 고정한다.

| ID | 동결된 의미 | 필수 연결 |
|---|---|---|
| `FS-01 — Transient Redis failure reaches DLT` | Active traffic과 겹친 Redis unavailable 상태에서 Redis handoff가 실패하고 source retry 소진 뒤 해당 record가 `barcode-events-dlt`에 도달한다. | source identity → retry Evidence → DLT partition/offset |
| `FS-02 — Permanent validation bypasses retry` | deterministic invalid source record가 `PermanentEventValidationException`으로 식별되고 transient source retry 없이 DLT로 전달된다. | invalid source identity → exception → DLT record |
| `FS-03 — Correct DLT classification` | DLT record가 원인에 따라 `TRANSIENT_REDIS` 또는 `PERMANENT_VALIDATION`으로 분류되며 unknown이나 malformed metadata는 fail closed로 처리된다. | DLT partition/offset → classification metadata |
| `FS-04 — Correct disposition` | generation 0 `TRANSIENT_REDIS`는 replay output으로, `PERMANENT_VALIDATION`, `UNKNOWN`과 malformed metadata는 quarantine output으로 발행된다. | classification → publication success → replay/quarantine identity |
| `FS-05 — Replay recovery` | Redis recovery 뒤 replay output이 `barcode-events`에서 다시 처리되어 Redis handoff에 성공한다. | replay output → source reprocessing → successful Redis handoff |
| `FS-06 — Bounded replay` | generation 0 transient record의 replay count가 `1`로 정규화되어 한 번만 replay되고, count `1` 이상은 추가 replay되지 않는다. | root identity → normalized replay count → terminal disposition |
| `FS-07 — Snapshot boundedness` | disposition 시작 시 partition별 DLT end offset이 고정되고 `offset < startup snapshot end`인 record만 같은 execution에서 처리된다. | partition snapshot → processed DLT offsets → post-snapshot exclusion |
| `FS-08 — Quarantine terminality` | permanent, unknown, malformed 또는 replay-exhausted record가 `barcode-events-quarantine`에 도달하고 quarantine replay가 수행되지 않는다. | root identity → quarantine output → terminal state |
| `FS-09 — Responsibility accountability` | transient와 permanent cohort의 각 root source identity가 DLT, classification, disposition과 최종 상태까지 설명 가능하다. aggregate count만으로 책임 보존을 판정하지 않는다. | root identity reconciliation과 중복·미정 상태 계량 |

## 7. 실험 유효성(Experiment Validity)

R1 Material Run은 다음 조건을 모두 충족해야 한다.

1. Material Run이 정확히 `BIP-FR-005-RC-R1` 하나를 직접 참조한다.
2. 실행 implementation이 independent as-built reviewed baseline과 의미적으로 동일하며 정확한 runtime identity로 고정된다.
3. Active traffic 중 Redis unavailable 상태가 실제로 존재한다.
4. 다른 failure domain을 의도적으로 동시에 주입하지 않는다.
5. Redis recovery 이후에 DLT disposition을 수행한다.
6. transient cohort와 permanent cohort를 root identity로 구분할 수 있다.
7. DLT offset을 수동 조작하지 않는다.
8. disposition 실행 전에 partition별 startup snapshot boundary를 고정한다.
9. Material Run 중 Failure Signature 또는 Verification Criteria를 변경하지 않는다.

기준선 드리프트가 확인되면 해당 실행을 R1 판정 Evidence로 사용하지 않는다.

## 8. Evidence 요구사항

### 8.1 실행과 장애 identity

- Material Run ID와 `BIP-FR-005-RC-R1`의 일대일 연결
- branch, HEAD, working-tree 상태, source-to-release 또는 image identity
- Redis fault 시작, 실제 unavailable 관측, recovery와 readiness의 시간선
- active traffic과 Redis unavailable의 시간적 중첩
- 다른 failure domain이 결과를 지배하지 않았다는 Evidence

### 8.2 Transient identity chain

```text
source record
→ retry exhaustion
→ DLT record
→ TRANSIENT_REDIS
→ replay output
→ source reprocessing
→ successful Redis handoff
```

### 8.3 Permanent identity chain

```text
source invalid record
→ PermanentEventValidationException
→ DLT record
→ PERMANENT_VALIDATION
→ quarantine output
```

### 8.4 Disposition과 정합성 Evidence

- source retry Evidence
- DLT topic, partition과 offset
- disposition 시작 시 partition별 end offset snapshot
- failure classification과 normalized replay count
- replay 또는 quarantine publication 결과
- root source identity와 output identity의 연결
- publication 성공 이후의 DLT consumer committed offset
- quarantine Evidence와 quarantine replay 부재
- replay 이후 source reprocessing과 Redis handoff 성공
- same-generation duplicate output 관측 결과
- transient/permanent cohort별 terminal state와 unaccounted identity

Aggregate count만으로 책임 보존을 판정하지 않는다. root identity reconciliation을 우선하며 duplicate, pending 또는 미정 상태를 별도로 설명한다.

## 9. 검증 기준(Verification Criteria)

검증은 반드시 다음 순서로 수행한다.

```text
Experiment Validity
→ Evidence Sufficiency
→ Failure Signature Evaluation
→ Outcome
```

### 9.1 Experiment Validity

7절의 frozen condition, authorized execution boundary, baseline identity와 금지 action 준수 여부를 먼저 평가한다.

### 9.2 Evidence Sufficiency

8절의 Evidence로 fault/recovery timeline, 두 cohort의 identity chain, disposition snapshot과 DLT offset settlement를 재구성할 수 있는지 평가한다. 필수 chain이 aggregate count로만 남거나 root identity를 연결할 수 없으면 그 제한을 숨기지 않는다.

### 9.3 Failure Signature Evaluation

`FS-01`부터 `FS-09`까지 추가·삭제 없이 각각 Evidence에 연결해 평가한다. 일부만 입증되면 직접 확인된 사실, 강한 추론과 미해결 항목을 구분한다.

### 9.4 Outcome

앞선 세 평가가 끝난 뒤 다음 네 값 중 하나만 사용한다.

```text
REPRODUCED
PARTIALLY_REPRODUCED
NOT_REPRODUCED
INCONCLUSIVE
```

현재는 Material Run이 없으므로 Outcome을 배정하지 않는다.

## 10. 승인된 실행 경계와 금지 action

### 10.1 향후 R1 Material Run에 허용되는 범위

- normal `barcode-events` traffic
- deterministic permanent-validation record
- controlled Redis unavailability
- Redis recovery
- bounded one-shot DLT disposition
- read-only Evidence collection

### 10.2 포함하지 않는 범위

- repository implementation 또는 runtime configuration 변경
- 다른 component fault injection
- recursive 또는 unlimited replay
- quarantine replay
- DLT manual deletion
- DLT offset manual correction
- manual Kafka publication을 통한 결과 보정
- alerting system
- production deployment
- exactly-once replay claim

Material Run 준비 중 implementation 또는 configuration 변경이 필요해지면 R1 실행으로 진행하지 않고 별도 구현·검토 책임과 계약 개정 필요성을 판정한다.

## 11. Artifact와 Run 등록 경계

| Artifact | 현재 상태 | 책임 |
|---|---|---|
| Contract `BIP-FR-005-RC-R1` | `FROZEN` | 사전 실행·검증 경계의 정본 |
| Material Run | `NOT EXECUTED` | 아직 Run ID, Evidence 또는 Run registration 없음 |
| Outcome | 미배정 | Material Run 검증 전에는 작성하지 않음 |
| Verified Reproduction Claim | 없음 | 검증된 Evidence 범위에서만 후속 작성 |

후속 Material Run은 실제 Run ID를 생성하는 등록 시점에 다음 관계를 정확히 한 번 확정한다.

```text
BIP-FR-005-MR-<UTC> → BIP-FR-005-RC-R1
```

위 표현은 naming rule 예시이며 현재 Run 등록이 아니다. Run registration과 Evidence locator는 후속 재현 기록(Reproduction Record)에 보존한다.

## 12. Revision과 의미 변경 금지

R1에서 다음을 변경하지 않는다.

- Revision, Failure Signature의 수·이름·판정 강도
- source retry와 최대 DLT replay `1`의 의미
- classification vocabulary
- one-shot snapshot semantics
- publication 성공 후 DLT offset commit invariant
- quarantine terminality
- non-transactional publication/commit limitation과 exactly-once non-claim
- Verification Criteria, Evidence requirements와 authorized execution boundary

조건, 절차, Failure Signature, Verification Criteria, Evidence 요구사항 또는 승인 경계에 material redesign이 필요하면 R1을 덮어쓰지 않는다. 기존 승인 경계 안인지 판정하고 필요한 후속 Contract Revision과 사람 승인 관문(Human Gate)을 별도로 처리한다.

## 13. 현재 gate

```text
BIP-FR-005-RC-R1
= FROZEN / CANONICALLY REGISTERED

Material Run
= NOT EXECUTED

NEXT
= MATERIAL RUN REGISTRATION / EXECUTION PREPARATION
```
