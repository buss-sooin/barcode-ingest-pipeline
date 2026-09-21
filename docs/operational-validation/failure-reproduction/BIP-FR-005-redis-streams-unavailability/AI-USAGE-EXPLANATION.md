# BIP-FR-005 AI 활용 설명

> 문서 상태: `FINAL — HUMAN CONFIRMED`. 인간 친화적 문서화 Local Trial 결과이며, 새로운 실행 정본이나 Four-Artifact 표준은 아니다. 실행 상태는 [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)가 우선한다.

## 핵심

BIP-FR-005에서 AI와 자동화에 적합했던 책임은 실제 source/configuration과 Evidence를 반복 대조하고, Redis handoff 실패 이후 각 논리 식별자의 현재 소유권과 최종 귀속을 계산하는 일이었다. 인간에게 남은 책임은 어떤 실패를 재현할지, DLT를 언제 replay 또는 quarantine할지, 최대 replay 횟수와 fail-closed 경계를 어디에 둘지, 어떤 Evidence까지 최종 주장을 허용할지 결정하는 일이었다.

```text
AI·자동화
= inspection + 반복 수집 + deterministic check + identity reconciliation

Human
= Engineering Intent + 위험·권한 + 의미 결정 + Claim Boundary + final acceptance
```

AI의 설명은 실행 성공 근거가 아니다. 최종 상태는 Verified Material Run `BIP-FR-005-MR-20260915T031000Z`의 manifest와 Evidence, 구현 revision `83eaa799e2359a353e748e567a5fbfc0df0cf9c3`, 그리고 Reproduction Record의 독립 검증 결과로 확인했다.

## Source와 사실 경계

이 Trial은 다음 순서로 읽었다.

```text
REPRODUCTION-RECORD.md
→ REPRODUCTION-CONTRACT.md
→ BIP-FR-005-MR-20260915T031000Z Evidence
→ actual source/configuration
→ existing technical/diagnostic documents
→ Engineering Interpretation
```

동결된 Contract의 `Material Run = NOT EXECUTED`는 freeze 당시 snapshot이다. 현재 실행 상태는 Record의 `CLOSED / REPRODUCED / VERIFIED / SYNCHRONIZED`다. 두 상태를 섞지 않았다.

## Human–AI lifecycle

| Lifecycle | AI·자동화에 적합했던 책임 | 인간 판단·권한 책임 | 확인 상태 |
|---|---|---|---|
| Scenario Design | Redis와 Kafka failure domain 분리, 관측 가능한 Failure Signature 구조화 | Redis Streams handoff failure를 학습·검증 대상으로 선택, Scope와 금지 action 결정 | Contract로 직접 확인 |
| As-built implementation review | source/config inspection, retry와 exception classification 대조, test 결과 확인 | 구현이 Scenario 의미에 부합하는지 수용하고 잔여 한계를 판단 | Record와 source로 직접 확인. 최초 제안자까지는 확인 불가 |
| DLT disposition / bounded replay | classification, header, snapshot, publish/commit 순서와 최대 replay `1` 검증 | replay 허용 대상, quarantine terminality, fail-closed boundary 결정 | Contract와 구현으로 직접 확인 |
| Contract Freeze | 기준을 실행 전에 식별 가능한 문서·hash로 고정 | Failure Signature, Evidence Sufficiency, Claim Boundary 승인 | Contract로 직접 확인 |
| Material Run | preflight, 상태 수집, fault/recovery orchestration, manifest 생성, deterministic predicate 적용 | 승인된 fault·recovery 경계와 실행 위험 보유 | Run Evidence로 직접 확인. 개별 조작자의 신원은 추정하지 않음 |
| Identity reconciliation | source/DLT/quarantine/Redis/Worker DLQ/dedupe/MySQL 집합 대사 | 어떤 identity를 업무 완료와 terminal disposition으로 인정할지 결정 | Reconciliation Evidence로 직접 확인 |
| Verification / closure | Contract 순서로 validity, sufficiency, signature와 outcome 후보 계산 | 잔여 limitation을 포함한 최종 주장 수용 | Record로 직접 확인 |
| stale directive 차단 | repository preflight로 최신 Record와 branch state 검사 | 오래된 실행 지시를 폐기하고 현재 정본을 우선하도록 요구 | 이번 문서화 preflight에서 관찰. 기술 Outcome과 분리 |

AI 내부 chain-of-thought나 과거 대화의 숨은 판단은 복원하지 않는다. Git author나 문장 스타일만으로 특정 결정을 AI 또는 Human의 최초 제안으로 귀속하지 않는다.

## AI와 자동화에 적합했던 책임

### Source와 configuration inspection

- `BarcodeEventConsumer`가 `barcode-events`, consumer group `barcode-processing-group`을 사용하고 처리 예외를 삼키지 않는지 확인
- `KafkaConfig`의 `FixedBackOff(2000ms, 3)`와 `PermanentEventValidationException` 비재시도 경계 확인
- `DltFailureClassifier`가 `QueryTimeoutException`을 `TRANSIENT_REDIS`, 영구 validation을 `PERMANENT_VALIDATION`, 그 밖을 `UNKNOWN`으로 분류하는지 확인
- `DltDispositionService`가 `MAX_DLT_REPLAY_ATTEMPTS = 1`을 강제하고 malformed count, exhausted replay, permanent, unknown을 quarantine하는지 확인
- `DltDispositionRunner`가 시작 시 DLT end offset을 고정하고 output publish가 성공한 뒤 `commitSync(offset + 1)`을 수행하는지 확인

### 반복 수집과 deterministic verification

- branch, revision, frozen image와 runtime identity 대조
- broker running/OOM/restart, ISR, URP, unavailable partition의 반복 확인
- Redis `PONG`, Stream group lag, PEL 확인
- Kafka source/DLT/quarantine watermark와 consumer lag 확인
- Material Run manifest와 등록 관계 검증
- C0–C3 논리 식별자의 source, disposition과 terminal state 집합 대사

### Evidence consistency check

다음과 같은 서로 다른 수치를 하나의 의미로 합치지 않았다.

```text
source occurrence 5
DLT occurrence 2
quarantine occurrence 1
Redis accepted identity 3
MySQL persisted identity 3
unaccounted successor identity 0
```

C1은 원본과 replay 때문에 source occurrence가 2지만 하나의 business identity다. C2는 MySQL에 없어도 quarantine terminal state로 설명된다. 따라서 총합 일치만으로 완료를 판정하지 않고 identity별 ownership을 계산했다.

## 인간 판단 책임

다음 결정은 반복 계산만으로 정당화되지 않는다.

| 인간 책임 | 이유 |
|---|---|
| Scenario Scope | 어떤 장애 영역만 의도적으로 변화시킬지 선택하는 Engineering Intent |
| DLT disposition semantics | transient를 replay하고 permanent/unknown/malformed를 quarantine할지에 대한 업무 의미 결정 |
| Replay limit | 중복·재처리 위험과 복구 가능성 사이 Trade-off 수용 |
| Fail-closed boundary | metadata 불명확, partition ownership 변화, pre-fault 조건 실패 시 실행을 멈출지 결정 |
| Claim Boundary | 작은 C0–C3 cohort를 production-scale·exactly-once 보장으로 확대하지 않도록 통제 |
| Safe continuation 의미 | health 회복이 아니라 unfinished identity의 ownership에 따라 재개 지점을 선택 |
| Final acceptance | 기술적 `PASS`와 운영적 수용·공개 범위를 구분 |

이번 Trial 지시에서 Human이 추가로 명시한 중요한 기준은 다음과 같다.

- 총합이 맞아도 direct trace라고 부르지 않는다.
- `Redis healthy`를 Recovery Complete로 간주하지 않는다.
- `DLT exists`를 processing complete로 간주하지 않는다.
- replay-all이 아니라 unfinished identity의 current ownership에서 continuation point를 결정한다.
- fixed four files보다 독자 책임과 중복 비용을 먼저 평가한다.

이는 reader responsibility와 Claim Boundary에 대한 Human-originated correction이다. 아직 네 Draft 자체에 대한 인간의 기술 검토나 최종 수용은 수행되지 않았다.

## stale execution directive가 차단된 의미

```text
Freeze snapshot: Material Run NOT EXECUTED
→ 새 Run preparation 지시
→ repository inspection
→ 최신 Record는 이미 CLOSED / REPRODUCED
→ stale execution fail closed
```

이 사례는 Chat·과거 snapshot보다 Repository 정본을 먼저 확인해야 한다는 협업 Evidence다. 기존 Run을 다시 실행하지 않아 불필요한 fault injection과 Outcome drift를 막았다. 다만 이는 BIP-FR-005의 Redis 장애 기술 결과를 새로 증명하지 않으며, collaboration/preflight 품질 Evidence로만 사용한다.

현재 runtime의 broker-3 OOM은 역사적으로 완료되고 동기화된 Verified Run의 Outcome을 소급 변경하지 않는다. 이번 Documentation Trial은 runtime 상태를 현재 Run Evidence로 사용하지 않았고, broker를 복구하거나 Redis fault·DLT replay를 실행하지 않았다.

## FR-001~005 교차 비교

### 네 독자 책임

네 책임은 다섯 Scenario에서 반복됐다.

| 독자 책임 | FR-001~005에서 반복된 이유 |
|---|---|
| AI/Human 책임·권한·검증 경계 | 실행 가능성, 실행 권한과 최종 수용이 서로 다르기 때문 |
| Failure mechanism과 검증 결과 | Contract/Record만으로 처음 읽는 개발자의 인과 학습 순서가 항상 충분하지 않기 때문 |
| 인간 진단·복구·safe continuation | 장애 원인 확인, 현재 ownership과 재개 지점이 Scenario마다 다르기 때문 |
| README용 압축 설명 | Repository의 상세 Evidence와 공개 진입점의 정보 밀도가 다르기 때문 |

반복된 것은 책임이지 반드시 네 개의 독립 파일은 아니다.

### 고정 네 파일

고정 4-file taxonomy는 Trial 비교에는 유용했지만 장기 표준으로는 비용이 크다.

- `AI-USAGE-EXPLANATION.md`는 Contract의 Human Gate, 기존 AI/Human mapping과 겹친다.
- `SCENARIO-EXPLANATION.md`는 Contract, Record, Technical Report와 결과·한계를 반복한다.
- `HUMAN-RESPONSE-GUIDE.md`는 Runbook, Diagnostic Guide와 명령·복구 조건을 반복한다.
- `README-SECTION-DRAFT.md`는 통합되지 않으면 사실 복제본으로 drift할 수 있다.

따라서 후보 방향은 “네 책임을 보존하되 기존 정본에 책임별 section 또는 locator를 배치하고, 사람용 Guide만 독립 유지”다. 이 Trial은 그 Scope를 확정하지 않는다.

### 3계층 Human Response model

```text
Common Troubleshooting Core
→ Failure Mechanism
→ Project Adapter
```

판단 모델은 다섯 Scenario에 공통 적용 가능하다. FR-001은 `Part 1/2/3`, FR-003은 `Layer 1/2/3`으로 명시했고, FR-002와 FR-004도 증상·메커니즘·실제 구성의 책임은 존재했다. 다만 파일마다 Common Core를 복제하는 방식은 유지 비용이 크다. 공통 Core 한 개와 Scenario별 mechanism/adapter를 분리하는 대안이 더 작다.

### Identity accountability와 count/lag

다섯 Scenario 모두 다음 질문으로 정리할 수 있다.

```text
accepted logical identity
→ current state / ownership
→ correct continuation point
→ final disposition
```

FR-001은 Scanner/Ingest retry ownership, FR-002·003은 Kafka transport와 dedupe, FR-004는 Redis PEL/Worker ownership, FR-005는 source retry/DLT/Redis downstream ownership이 핵심이었다. Count, lag와 pending은 진행·이상 범위 좁히기에 유용하지만 final accountability를 대체하지 않았다.

### Human Review value

| Scenario | Repository로 확인 가능한 Human contribution | correction 분류의 Evidence 경계 |
|---|---|---|
| FR-001 | outage 범위, 복구 경계, Claim과 최종 책임 보유 | Trial 문서에 Human-originated 기술 교정은 직접 남지 않음 |
| FR-002 | Engineering Rule, 단계별 Gate, 주장 범위 승인; README 내용 검토 완료 표기 | timing 교정의 최초 제안자가 Human인지는 Repository만으로 불명 |
| FR-003 | 두 broker 동시 중단 위험, R2가 기존 Gate 안인지, 잔여 불확실성 수용 | review checklist는 있으나 실제 문장별 Human correction provenance는 없음 |
| FR-004 | 비즈니스 복구와 Redis per-record traceability를 분리하도록 명시적으로 교정 | abstraction correction과 Claim Boundary correction이 직접 확인됨 |
| FR-005 | identity/ownership 중심, direct/derived 구분, replay-all 금지, negative evidence 요구 | reader responsibility와 Claim Boundary correction은 확인. Draft acceptance는 아직 없음 |

확인되지 않은 review를 “사람이 기술 오류를 수정했다”로 확대하지 않는다. FR-004의 material correction은 분명한 가치가 있었지만, 나머지 Scenario의 승인 횟수 자체가 이해 향상을 증명하지는 않는다.

### Review process cost

Repository는 FR-001·002·004의 네 파일이 각각 한 번의 묶음 commit으로 보존됐고, FR-003은 AI usage 문서와 Trial completion이 두 단계 commit으로 남았음을 보여준다. 이는 commit 형태이지 실제 review 순서의 완전한 기록은 아니다.

현재 Evidence가 지지하는 후보는 다음이다.

1. material section 중심 검토: 기술 의미, abstraction, Claim Boundary에 집중
2. 마지막 일괄 검토: 네 reader responsibility 사이 모순과 중복 확인
3. 문서별 반복 검토: 실제 material correction이 있을 때만 사용

고정된 순차 4회 승인이 더 높은 품질을 만들었다는 Evidence는 없다.

## Negative / Counter Evidence

- 같은 Run 결과와 limitation이 Contract, Record, Technical Report와 네 Trial 파일에 반복된다.
- 정본 변경 뒤 파생 문서가 자동으로 갱신되지 않아 drift risk가 생긴다.
- 사람용 Guide에 Common Core와 모든 명령을 함께 넣으면 길어져 현장 검색성이 떨어진다.
- AI Usage 독립 파일은 이미 AI/Human mapping이나 Contract가 강한 프로젝트에서는 추가 가치가 낮을 수 있다.
- README Draft는 root README에 통합되지 않았으므로 실제 독자 가치가 아직 검증되지 않았다.
- Human의 단순 confirm은 기술 이해 향상이나 오류 탐지를 증명하지 않는다.
- Scenario마다 같은 Common Core를 복제하면 교정 비용과 표현 불일치가 증가한다.
- fixed file taxonomy는 실제 독자 질문보다 산출물 형식을 우선하게 만들 수 있다.
- FR-005의 malformed replay-count와 replay-exhausted path는 구현/test에는 있으나 Material Run cohort로 실행하지 않았다.

## Candidate reusable rules

아직 표준으로 승격하지 않는 후보는 다음과 같다.

1. 장애 문서는 count보다 logical identity와 current ownership을 우선한다.
2. Recovery Complete를 infrastructure, processing, disposition, downstream, identity reconciliation로 분리한다.
3. 직접 연결, derived reconciliation, not-directly-provable link를 명시한다.
4. Human review는 횟수보다 material correction의 종류와 Evidence를 기록한다.
5. 공통 Core는 한 번만 유지하고 Scenario mechanism과 project adapter를 연결한다.
6. 네 독자 책임은 유지하되 네 파일 고정은 요구하지 않는다.

## 관련 자료

- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [R1 Reproduction Contract](./REPRODUCTION-CONTRACT.md)
- [Identity accounting](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/identity-accounting.txt)
- [Failure signatures](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/failure-signatures.txt)
- [Reconciliation metrics](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/reconciliation-metrics.txt)
