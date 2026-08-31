# BIP-FR-001 — AI ↔ Human Resolution Mapping

| 항목 | 값 |
|---|---|
| Status | `APPROVED DESIGN IMPLEMENTATION` |
| Applicable scenario | `BIP-FR-001 — Active Scan 중 Kafka ingress broker unavailable` |
| Applicable branch | `validation/bip-fr-001-kafka-unavailable` |
| Material Run anchor | `20260829T073503Z` |
| Autonomy model | `Approved Boundary → Autonomous Execution within Boundary → Verify → Report` |
| Accountability | 권한 있는 Human 또는 조직 |

## 1. 목적

이 문서의 단일 책임은 BIP-FR-001에서 AI와 Human의 진단, 판단, 승인, 실행, 검증, 해결 및 최종 책임 경계를 정의하는 것이다. 핵심 질문은 다음과 같다.

> 누가 Evidence를 수집하고 해석하며, 누가 Recommendation을 만들고 material Decision을 승인하며, 누가 승인 경계 안에서 실행·검증하고, 누가 불확실성이나 충돌을 해결하며, 누가 최종 운영 책임(Operational Accountability)을 보유하는가?

역할 흐름은 다음과 같다.

```text
Evidence 수집
→ Observation / Diagnostic Inference
→ Recommendation
→ material Decision과 Approved Boundary에 대한 Human Approval
→ Approved Boundary 안의 Execution
→ Verification
→ uncertainty/conflict에 대한 Human Resolution(필요한 경우)
→ Human Operational Acceptance
→ Operational Accountability
```

AI는 외부화된 Evidence와 검토 가능한 엔지니어링 근거(Engineering Rationale)를 제공한다. Human은 AI의 내부 chain-of-thought를 승인하는 사람이 아니라, 그 외부화된 근거와 위험, 권한, 운영 문맥을 검토하는 권한자다.

## 2. 범위와 비목표

이 문서는 다음을 다룬다.

- 정보 상태(Information State) 사이의 경계와 전환 책임
- AI와 Human의 허용 책임 및 금지 책임
- 사람 승인 관문(Human Gate), 사람 해결(Human Resolution), 승인된 실행 경계(Approved Execution Boundary)의 관계
- BIP-FR-001 실제 lifecycle의 단계별 책임·권한·중단 조건
- Material Run `20260829T073503Z`의 AI ↔ Human 관점 walkthrough
- 기술 검증 결과와 운영적 수용의 분리
- 복구 완료(Recovery Complete)의 최종 책임

다음은 이 문서의 비목표다.

- Failure Reproduction 과정이나 Material Run Evidence를 다시 작성하지 않는다.
- First Broken Boundary 진단 절차를 복제하지 않는다.
- Kafka, Redis, retry, dedupe의 기술 원리를 다시 교육하지 않는다.
- 복구 명령과 각 Gate의 실행 절차를 다시 정의하지 않는다.
- Technical Report의 전체 검증 결과나 README의 presentation 책임을 대신하지 않는다.
- BIP local trial의 패턴을 Framework 또는 Workflow 규칙으로 승격하지 않는다.
- 새로운 장애 주입, runtime 조작, 복구 실행 또는 Evidence 재생성을 승인하지 않는다.

## 3. Source Artifact 책임

| Source Artifact | 고유 책임 | 이 문서의 사용 방식 |
|---|---|---|
| [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md) | 실제 Run, Evidence, 판정 및 Claim Boundary | 실행 사실과 Material Run 수치의 정본으로 참조한다. |
| [OPERATIONAL-DIAGNOSTIC-GUIDE.md](./OPERATIONAL-DIAGNOSTIC-GUIDE.md) | Evidence에서 First Broken Boundary와 영향 범위를 진단하는 방법 | 진단 입력·출력과 반증 원칙을 참조한다. |
| [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md) | Kafka/Redis/분산 시스템 현상의 원리와 인과관계 | 기술 해석의 경계와 non-claim을 참조한다. |
| [RUNBOOK.md](./RUNBOOK.md) | 진단된 조건에서 수행할 Action, Gate, Verification, Escalation | 승인 가능한 실행과 중단 조건의 정본으로 참조한다. |
| 이 문서 | 진단·추천·승인·실행·검증·Resolution·Acceptance·Accountability의 주체 | Source Artifact 위에 책임과 권한을 매핑한다. |

이 문서와 Source Artifact가 충돌하면 해당 사실·절차를 소유한 Source Artifact를 먼저 확인한다. 이 문서는 그 내용을 변경하거나 확장하는 권한을 만들지 않는다.

## 4. Resolution Information States

정보 상태는 서로 대체할 수 없다.

```text
Evidence
≠ Observation
≠ Diagnostic Inference
≠ Decision
```

| 상태 | 의미 | 생성·확정 책임 | 다음 상태로 넘어가기 위한 조건 |
|---|---|---|---|
| **Evidence** | timestamp가 있는 log, metric, CLI/query 결과, repository fact, 승인 참조처럼 다시 찾을 수 있는 원자료 | AI 또는 Human이 수집할 수 있다. 원자료의 존재와 provenance는 locator로 검증한다. | freshness, scope, source identity를 확인한다. |
| **Observation** | Evidence에서 직접 읽을 수 있고 해석을 최소화한 사실 문장 | AI가 추출할 수 있고 Human이 검토할 수 있다. | 관련 Evidence locator와 시간 범위를 연결한다. |
| **Hypothesis** | Observation을 설명할 수 있는 잠정적 원인 후보 | AI 또는 Human이 생성할 수 있다. | 경쟁 가설과 반증 probe를 명시한다. |
| **Diagnostic Inference** | Evidence, Observation, 검증 결과를 결합해 장애 경계나 영향을 해석한 결론 | AI가 작성할 수 있다. Human은 material Decision의 근거로 검토한다. | counter-evidence, 불확실성, sufficiency를 공개한다. |
| **Recommendation** | Diagnostic Inference와 Decision Criterion에 기반한 다음 행동 제안 | AI가 작성할 수 있다. | Action, 기대 관측, 검증, 중단 조건, 필요한 권한을 포함한다. |
| **Decision** | Recommendation 중 무엇을 채택할지 정하는 권한 행사 | 비중대한 기술 분류는 승인된 criteria로 AI가 평가할 수 있다. material Decision은 권한 있는 Human이 한다. | authority, materiality, risk, scope를 확인한다. |
| **Human Approval** | material Decision 또는 Approved Execution Boundary에 대한 명시적 권한 부여 | 권한 있는 Human만 할 수 있다. | 승인 대상, 환경, Action, 제한, 만료·중단 조건을 식별한다. |
| **Execution** | 승인된 Action을 실제로 수행하고 기록하는 행위 | 승인 경계 안에서는 AI/Codex 또는 Human이 수행할 수 있다. | 실제 명령·결과·시각을 보존하고 경계를 넘지 않는다. |
| **Verification** | 실행 결과를 사전에 정한 criteria와 Evidence로 평가하는 행위 | AI가 계산하고 `PASS`/`FAIL`을 평가할 수 있으며 Human이 독립 검토할 수 있다. | freshness와 evidence sufficiency가 충족돼야 한다. |
| **Recovery Complete** | Component Recovery, Flow Recovery, Backlog Drain, End-to-end Reconciliation이 충족된 복구 상태 | AI는 기술적 충족 여부를 assessment한다. 최종 운영 선언은 권한 있는 Human이 한다. | 기술 Evidence와 residual risk 검토가 모두 필요하다. |
| **Human Resolution** | AI가 안전하게 해소할 수 없는 Evidence·Authority·Scope·material uncertainty를 Human이 해결한 결과 또는 경로 | 권한 있는 Human이 담당한다. | Resolution이 새 material Decision이나 Boundary를 만들면 별도 Human Gate를 적용한다. |
| **Operational Accountability** | 운영 결과, 수용한 위험, 커뮤니케이션과 후속 조치에 대한 최종 책임 | 권한 있는 Human 또는 조직만 보유한다. | AI에게 위임하거나 AI PASS로 대체할 수 없다. |

Human Approval은 부족한 Evidence를 사실로 바꾸지 않는다.

```text
Operational Decision under Uncertainty
≠ Verified Engineering Fact
```

Evidence가 부족한 상태에서 운영상 결정을 내려야 한다면, 검증된 사실과 수용한 불확실성을 별도 필드로 기록한다.

## 5. AI Responsibility Boundary

### 5.1 AI가 수행할 수 있는 책임

- Evidence를 수집·정렬하고 locator, source identity, timestamp, freshness를 확인한다.
- Evidence에서 Observation을 추출하고 Evidence와 해석을 분리한다.
- 여러 Hypothesis와 competing explanation을 만들고 비교한다.
- 독립 probe와 counter-evidence로 반증을 시도한다.
- Diagnostic Inference와 Evidence Sufficiency State를 작성한다.
- uncertainty, conflict, stale Evidence, observability gap을 명시한다.
- Recommendation, Decision Criterion, Expected Observation, Verification Method를 제시한다.
- materiality, Approved Boundary, Scope, Authority를 기준으로 Human Gate 필요 여부를 판별한다.
- 명시적으로 승인된 Boundary 안에서 bounded execution을 수행한다.
- 실행 기록과 verification evidence를 수집한다.
- 승인된 criteria에 따라 기술적 `PASS`/`FAIL`을 평가한다.
- 결과, residual uncertainty, stop/escalation condition을 보고한다.

### 5.2 AI가 보유하지 않는 책임

AI는 다음을 수행하거나 보유할 수 없다.

- material Decision을 단독 승인한다.
- Approved Boundary를 임의로 확대하거나 다른 환경에 일반화한다.
- destructive/material action을 스스로 승인한다.
- Governance, Workflow 또는 Framework rule을 변경하거나 승격한다.
- 부족하거나 상충하는 Evidence를 확정된 사실로 변환한다.
- Human Gate를 우회하거나 approval reference를 추정한다.
- 기술적 `FAIL`을 운영 필요성만으로 `PASS`로 바꾼다.
- Human Resolution이 필요한 Authority·Scope conflict를 독단적으로 해결한다.
- 최종 Operational Accountability를 보유한다.

AI의 자율성은 명령이 state-changing인지 여부 하나로 결정하지 않는다. 같은 state-changing Action도 승인된 Boundary 안에 명시적으로 포함됐는지, materiality와 위험이 바뀌지 않았는지에 따라 권한이 달라진다.

## 6. Human Responsibility Boundary

권한 있는 Human은 다음 책임을 가진다.

- 실행자와 실행 환경의 권한을 확인한다.
- material risk와 blast radius를 평가하고 수용 또는 거부한다.
- material Decision과 Approved Execution Boundary에 Human Gate를 제공한다.
- Scope 또는 Authority의 material change를 승인하거나 거부한다.
- destructive/material action의 대상, rollback, Evidence 보존, 검증 계획을 승인한다.
- Evidence 부족·충돌, Authority conflict, Scope conflict, material uncertainty를 Human Resolution으로 해결한다.
- AI가 외부화한 Evidence, Diagnostic Inference, counter-evidence와 rationale을 검토한다.
- Verification result의 운영적 의미와 residual risk를 수용 또는 거부한다.
- Recovery Complete를 최종 운영 상태로 선언하거나 보류한다.
- incident 결과와 후속 조치에 대한 최종 Operational Accountability를 보유한다.

Human의 승인은 사실 판정의 대체물이 아니다. Human은 기술적 `FAIL`을 `PASS`로 재분류할 수 없으며, 필요하면 다음처럼 서로 다른 상태를 기록한다.

```text
Technical verification: FAIL
Operational decision: Accepted with unresolved risk
```

## 7. Human-auditable Resolution Rationale

material Diagnostic Inference 또는 Recommendation은 내부 chain-of-thought가 아니라 다음의 검토 가능한 기록을 남긴다.

| 필드 | 기록할 내용 |
|---|---|
| 1. Question / Decision Point | 지금 답해야 할 질문 또는 선택해야 할 결정 |
| 2. Observed Evidence | source, UTC, freshness가 있는 직접 Evidence |
| 3. Observation | Evidence에서 직접 확인되는 사실 문장 |
| 4. Diagnostic Interpretation | Observation이 의미하는 장애 경계·영향 해석 |
| 5. Competing Explanation / Counter-evidence | 양립 가능한 다른 설명과 현재 해석을 반증할 Evidence |
| 6. Uncertainty / Observability Gap | 확인하지 못한 상태, stale signal, 계량 불가능한 범위 |
| 7. Decision Criterion | Recommendation 또는 진행 여부를 가르는 사전 기준 |
| 8. Recommended Action | 제안하는 최소 Action과 의도 |
| 9. Authority / Approval Requirement | 실행 권한, Human Gate 필요 여부, 승인 참조 |
| 10. Expected Observation | Action이 맞다면 나타나야 할 관측 |
| 11. Verification Method | read-only probe, set reconciliation, 연속 sample 등 검증 방법 |
| 12. Stop / Escalation Condition | 즉시 중단하고 Human Resolution 또는 새 Gate로 반환할 조건 |
| 13. Evidence Locator | 원자료와 verification evidence의 재현 가능한 위치 |

모든 material AI conclusion은 가능한 범위에서 다음 trace를 유지한다.

```text
Evidence Locator
→ Observation
→ Diagnostic Inference
→ Decision Criterion
→ Recommendation
→ Approved Action
→ Verification Evidence
→ Result
```

`Kafka 문제 → restart → 정상`처럼 Evidence, 권한, 검증과 residual uncertainty를 생략한 축약은 허용하지 않는다.

## 8. Decision Authority와 Human Gate Model

### 8.1 Human Gate

Human Gate는 material Decision 또는 Approved Execution Boundary에 대한 권한 있는 Human의 승인 메커니즘이다. 필요 여부는 runtime state change 하나가 아니라 다음을 함께 평가한다.

- 기존 Approved Boundary와의 일치 여부
- materiality와 Engineering Intent
- Scope와 Authority
- risk와 blast radius
- reversibility와 rollback 가능성
- Evidence 보존 영향
- Governance 영향

이미 승인된 Boundary 안의 정상 실행과 read-only verification에는 단계마다 반복 Human Gate를 요구하지 않는다.

### 8.2 Human Resolution

Human Resolution은 AI가 안전하게 해결할 수 없는 다음 상태를 권한 있는 Human이 해결하는 경로 또는 결정이다.

- Evidence 부족 또는 freshness 불명
- Evidence conflict
- Authority conflict
- Scope conflict
- material uncertainty

Human Gate와 Human Resolution 사이에는 상하 authority hierarchy가 없다. 두 개념의 책임이 다르다. Human Resolution 결과가 새로운 material Decision 또는 새 Execution Boundary를 만들면, 그 결과에 대해 Human Gate가 필요할 수 있다.

### 8.3 Approved Boundary와 자율 실행

```text
Approved Boundary
→ Autonomous Execution within Boundary
→ Verify
→ Report
```

```text
Inside Approved Boundary
→ continue autonomously

Boundary exceeded
→ STOP
→ preserve Evidence
→ report
```

새 material Decision, Action, 환경, component, fault injection 또는 확장된 Scope가 필요하면 실행하지 않고 Human Gate로 반환한다.

### 8.4 BIP-FR-001 Material Action 경계

다음은 AI의 기본 autonomous authority 밖에 있는 Material Action 예시다.

- Kafka offset reset
- topic delete/recreate
- Redis PEL clear 또는 Redis Stream state 삭제
- manual `XACK`
- DLQ/DLT delete 또는 arbitrary replay
- DB insert/update/delete
- Scanner retry purge
- 승인되지 않은 Scanner/Ingest restart
- Kafka container recreation 또는 storage replacement
- Processing, Redis, Worker, MySQL 등 추가 component 조작
- 새 fault injection
- Approved Scope 확대

별도의 승인된 Boundary가 특정 Action을 명시적으로 허용한다면 그 Boundary 안에서 실행할 수 있다. 위 목록에 있다는 이유만으로 매 단계 새 Human Gate를 반복하는 것이 아니라, 명시적 승인 범위와 현재 조건의 일치 여부를 확인한다.

## 9. BIP-FR-001 Resolution Lifecycle Mapping

단계 사이의 기본 관계는 다음과 같다.

```text
Detect
→ Impact Assessment
→ First Broken Boundary Diagnosis
→ Recovery Decision
→ Component Recovery
→ Flow Recovery
→ Backlog Drain
→ End-to-end Reconciliation
→ Recovery Complete
```

### 9.1 Detect

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI-assisted operator 또는 Human operator |
| AI Responsibility | producer, Scanner, exporter, component state를 같은 시각축에 정렬하고 이상 Observation을 추출한다. |
| Human Responsibility | incident 문맥, 사용자·business impact, signal의 운영 중요도를 확인한다. |
| Required Evidence | timestamp가 있는 Ingest failure, Scanner fallback/retry, broker/exporter freshness, downstream progression |
| Decision Authority | detect 상태 기록은 criteria 기반으로 AI가 지원할 수 있다. incident severity와 대응 개시는 Human 권한이다. |
| Allowed Autonomous Action | 승인된 source의 read-only Evidence 수집·freshness 확인·correlation |
| Human Gate Trigger | 새로운 계측 설치, runtime 변경, 승인되지 않은 probe가 필요할 때 |
| Stop / Escalation | signal이 stale하거나 단일 source뿐이거나 incident scope를 식별할 수 없을 때 |
| Accountability | Human incident owner |

### 9.2 Impact Assessment

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI analysis, Human review |
| AI Responsibility | generated, acknowledged, uncertain, retry backlog를 분리하고 affected cohort와 data-integrity exposure를 계산한다. |
| Human Responsibility | business impact, 허용 downtime, affected cohort의 운영적 중요도를 판단한다. |
| Required Evidence | logical identity manifest/accounting cut, HTTP 결과 의미, retry state, Kafka/Redis/MySQL/DLQ/DLT 상태 |
| Decision Authority | 기술적 영향 계산은 AI가 수행할 수 있다. risk acceptance와 우선순위는 Human이 결정한다. |
| Allowed Autonomous Action | read-only 집계, set comparison, uncertainty 기록 |
| Human Gate Trigger | traffic 중단, replay, purge, 데이터 변경 등 영향 통제가 필요할 때 |
| Stop / Escalation | cohort가 정의되지 않거나 `HTTP Failure = Event Loss`처럼 state가 혼합될 때 |
| Accountability | Human incident owner와 관련 service owner |

### 9.3 First Broken Boundary Diagnosis

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI diagnostic assistant, Human diagnostic authority |
| AI Responsibility | competing hypothesis를 만들고 독립 probe와 counter-evidence로 마지막 정상 경계와 최초 비정상 경계를 좁힌다. |
| Human Responsibility | Diagnostic Inference와 sufficiency를 검토하고 운영 문맥상 복구 대상 후보를 수용하거나 보류한다. |
| Required Evidence | Ingest producer failure, independent broker/topic probe, offsets/progression, Redis·MySQL 독립 상태, restart/OOM 상태 |
| Decision Authority | AI는 inference를 제시한다. material recovery target 확정은 Human Decision이다. |
| Allowed Autonomous Action | 승인된 read-only probe, repository fact 확인, evidence trace 작성 |
| Human Gate Trigger | state-changing diagnostic, 새 fault injection, component restart가 필요할 때 |
| Stop / Escalation | Evidence가 `CONFLICTED` 또는 `INSUFFICIENT`, 복수 failure domain, stale probe일 때 |
| Accountability | Human diagnostic/incident owner |

### 9.4 Recovery Decision

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | Authorized Human |
| AI Responsibility | 최소 Action, expected observation, verification, rollback·중단 조건과 금지 행동을 Recommendation으로 제시한다. |
| Human Responsibility | 실행 권한, risk, blast radius, reversibility를 검토하고 Action과 Approved Boundary를 승인 또는 거부한다. |
| Required Evidence | First Broken Boundary rationale, pre-recovery identity/storage, affected cohort, approval reference |
| Decision Authority | Authorized Human |
| Allowed Autonomous Action | decision packet 작성과 승인 범위의 정적 대조 |
| Human Gate Trigger | primary recovery처럼 material state change를 승인할 때 |
| Stop / Escalation | 승인 불명확, 대상·환경 불일치, storage loss, 다른 component 조작 필요 시 |
| Accountability | 승인한 Human 또는 조직 |

### 9.5 Component Recovery

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | Approved executor(AI/Codex 또는 Human) |
| AI Responsibility | 승인된 정확한 Action을 한 번 실행하고 명령·시각·결과·identity를 보존하며 독립 probe로 component 상태를 검증한다. |
| Human Responsibility | 승인 Boundary를 소유하고 deviation 또는 실패 시 다음 결정을 내린다. |
| Required Evidence | 승인 참조, pre/post container identity, broker/topic probe, current exporter freshness |
| Decision Authority | 실행은 Approved Boundary가 부여한다. deviation은 Human이 결정한다. |
| Allowed Autonomous Action | BIP Runbook에서 승인된 동일 Kafka container start와 후속 read-only verification에 한정 |
| Human Gate Trigger | 반복 start, recreate, storage/topic/offset 변경, 다른 component action이 필요할 때 |
| Stop / Escalation | 명령 실패, identity 변경, topic·partition 불일치, probe 지속 실패 시 |
| Accountability | Authorized Human; executor는 실행 정확성과 기록을 책임진다. |

### 9.6 Flow Recovery

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI/Codex verification, Human oversight |
| AI Responsibility | publish → consume → Redis write → Worker read → MySQL persistence의 재개를 동일 시각축에서 검증한다. |
| Human Responsibility | 관측 window와 residual impact를 검토하고 운영 진행 여부를 판단한다. |
| Required Evidence | first publish/consume/retry success, Redis/Worker/MySQL progression, consumer group 상태 |
| Decision Authority | 승인된 criteria의 기술 판정은 AI가 할 수 있다. Scope 변경은 Human이 결정한다. |
| Allowed Autonomous Action | 기존 traffic·retry 경로의 read-only 관측과 criteria 적용 |
| Human Gate Trigger | replay, offset reset, Processing/Redis/Worker/MySQL restart가 필요할 때 |
| Stop / Escalation | broker만 응답하고 흐름이 재개되지 않거나 DLQ/DLT가 증가할 때 |
| Accountability | Human incident owner |

### 9.7 Backlog Drain

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI/Codex measurement, Human review |
| AI Responsibility | retry, Kafka lag, Redis group lag·PEL, DLQ/DLT를 같은 UTC sample로 수집하고 최소 두 번의 연속 수렴을 평가한다. |
| Human Responsibility | 관측 window, affected cohort, 지연 위험과 unresolved backlog를 수용 또는 escalation한다. |
| Required Evidence | 연속 backlog sample, queue full/drop, cohort/watermark, source freshness |
| Decision Authority | 기술 수렴 판정은 AI가 criteria로 평가한다. 수렴하지 않은 위험 수용은 Human Decision이다. |
| Allowed Autonomous Action | 승인된 window 안의 read-only 반복 관측 |
| Human Gate Trigger | purge, PEL clear, manual `XACK`, replay, offset reset을 고려할 때 |
| Stop / Escalation | 값이 증가·정체·진동하거나 관측 불능, 새 pending/unaccounted가 생길 때 |
| Accountability | Human incident owner |

### 9.8 End-to-end Reconciliation

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI/Codex calculation, Human review |
| AI Responsibility | generated identity를 MySQL, DLQ, DLT, pending, unaccounted와 set 기준으로 대조하고 transport duplicate와 final duplicate를 분리한다. |
| Human Responsibility | reconciliation scope와 Evidence locator를 검토하고 미해결 data risk의 처리 방향을 결정한다. |
| Required Evidence | immutable manifest/accounting cut, Kafka record count, Redis/PEL, MySQL identity set, DLQ/DLT, retry state |
| Decision Authority | 계산과 technical result는 AI가 평가한다. missing·extra·conflict 처리와 risk acceptance는 Human이 결정한다. |
| Allowed Autonomous Action | read-only set reconciliation과 criteria 적용 |
| Human Gate Trigger | DB 수정, arbitrary replay, DLQ/DLT 삭제 등 terminal state 변경이 필요할 때 |
| Stop / Escalation | manifest 부재, count-only 일치, missing·extra·final duplicate·unaccounted, conflicting evidence일 때 |
| Accountability | Human data/service owner와 incident owner |

### 9.9 Recovery Complete

| 항목 | 책임과 경계 |
|---|---|
| Primary Actor | AI technical assessor, Authorized Human declarer |
| AI Responsibility | Component Recovery, Flow Recovery, Backlog Drain, End-to-end Reconciliation criteria를 적용하고 technical `PASS`/`FAIL`, uncertainty와 locator를 보고한다. |
| Human Responsibility | Evidence와 residual risk를 검토하고 운영적으로 수용, 보류 또는 제한 수용하며 최종 선언을 한다. |
| Required Evidence | 네 단계의 verification evidence, 연속 sample, approval·execution record, unresolved risk 목록 |
| Decision Authority | Technical assessment는 criteria에 구속된다. 최종 operational declaration은 Authorized Human 권한이다. |
| Allowed Autonomous Action | 최종 evidence trace와 technical assessment 작성 |
| Human Gate Trigger | 미충족 criteria를 해결하기 위한 새 Action이나 Boundary가 필요할 때 |
| Stop / Escalation | 어떤 criteria라도 미충족, stale, conflicted, not observed일 때 |
| Accountability | Authorized Human 또는 조직 |

## 10. Uncertainty, Conflict와 Observability Gap

### 10.1 Evidence Sufficiency State

다음 값은 AI의 심리적 confidence percentage가 아니라 엔지니어링 Evidence의 충분성을 나타낸다.

| 상태 | 의미 | 허용되는 다음 행동 |
|---|---|---|
| `SUPPORTED` | material conclusion을 지지하는 최신·독립 Evidence가 있고 주요 counter-evidence가 설명됨 | Approved Boundary와 Decision Criterion에 따라 진행 가능 |
| `PARTIALLY SUPPORTED` | 일부 Evidence는 지지하지만 중요한 범위·freshness·independent confirmation이 부족함 | 제한된 claim만 유지하고 부족한 검증을 요청 |
| `CONFLICTED` | 신뢰 가능한 Evidence가 서로 양립하지 않음 | 결론 확정과 state change를 중단하고 Human Resolution 요청 |
| `INSUFFICIENT` | 결론에 필요한 Evidence가 없거나 관측할 수 없음 | 결론을 확정하지 않고 gap과 필요한 Evidence를 보고 |

### 10.2 처리 원칙

- **Missing Evidence:** `INSUFFICIENT`로 기록하고 결론을 확정하지 않는다.
- **Conflicting Evidence:** 상충 Evidence를 평균하거나 임의로 제거하지 않고 `CONFLICTED`로 기록한다.
- **Stale Evidence:** freshness가 보장되지 않는 signal을 현재 상태의 사실로 사용하지 않는다.
- **Observability Gap:** 관측하지 못한 값을 0으로 대체하지 않는다.

```text
not observed
≠ zero
```

예를 들어 Scanner retry queue를 현재 계량할 수 없다면 `retry remaining = 0`으로 추정하지 않는다. 그 상태에서는 Recovery Complete assessment가 `SUPPORTED`가 될 수 없으며, Human이 운영 위험을 별도로 수용하더라도 기술적 미검증 상태는 남는다.

## 11. Stop과 Escalation 규칙

AI/Codex는 다음 조건에서 추가 state change를 수행하지 않고 Evidence를 보존한 뒤 보고한다.

- 현재 Action이 Approved Boundary를 벗어난다.
- environment, repository revision, component identity 또는 authority가 승인 참조와 다르다.
- 새로운 material Decision, destructive action, fault injection 또는 Scope 확대가 필요하다.
- Evidence Sufficiency가 `CONFLICTED` 또는 `INSUFFICIENT`다.
- 핵심 signal이 stale하거나 observability gap 때문에 진행 criteria를 평가할 수 없다.
- pre/post Kafka identity가 다르거나 recreate·storage loss 정황이 있다.
- component는 복구됐지만 flow가 진행되지 않는다.
- backlog가 증가·정체·진동하거나 DLQ/DLT, pending, unaccounted가 증가한다.
- manifest reconciliation에서 missing, extra, final duplicate 또는 unexplained transport record가 발견된다.
- 승인된 verification criteria가 `FAIL`이다.

보고에는 현재 완료된 최고 상태, 실행한 Action, 실행하지 않은 Material Action, Evidence locator, residual risk, 필요한 Human Resolution 또는 Human Gate를 포함한다.

## 12. Recovery Complete Accountability

### 12.1 AI/Codex

- Evidence locator와 freshness
- 정확한 실행 기록
- verification calculation
- 승인 criteria 적용 결과
- Evidence Sufficiency State
- uncertainty와 observability gap
- technical assessment

### 12.2 Authorized Human

- Action approval와 Approved Execution Boundary
- material risk acceptance
- deviation과 Scope change 결정
- verification result의 operational acceptance
- residual risk acceptance
- Recovery Complete의 최종 operational declaration

### 12.3 Operational Accountability

최종 Operational Accountability는 권한 있는 Human 또는 조직이 보유한다. AI는 Recovery Complete criteria가 충족됐다는 기술적 assessment를 제공할 수 있지만 운영 결과에 대한 최종 책임자가 될 수 없다.

```text
AI Verification PASS
≠ Human Operational Acceptance

Human risk acceptance
≠ Technical PASS
```

- **AI Verification PASS:** 승인된 criteria와 Evidence에 따르면 기술적 verification condition이 충족됐다.
- **Human Operational Acceptance:** 권한 있는 Human이 Evidence와 residual risk를 검토하고 운영 상태를 수용했다.

Human이 기술적 `PASS`를 운영상 보류할 수 있고, 기술적 `FAIL` 상태에서 운영을 제한 수용할 수도 있다. 어느 경우에도 기술 판정 자체를 바꾸지 않고 두 결과를 나란히 기록한다.

## 13. Material Run `20260829T073503Z` Walkthrough

이 절은 기존 Material Run Evidence에 승인된 역할 모델을 적용한 책임 walkthrough다. 역사적 Evidence를 변경하거나 원 기록에 없는 actor action을 새 실행 사실로 주장하지 않는다.

### 13.1 Evidence → Diagnostic Inference

- **Evidence:** `07:45:34.673Z` Ingest broker 연결 실패, `07:45:40.978Z` 첫 batch confirmation failure, `07:45:40.985Z` Scanner fallback, `07:45:52.087Z` retry enqueue가 시간 순서로 관측됐다.
- **Evidence:** fault window에 Kafka exporter process는 running이었지만 6개 metrics request가 HTTP `000`이었고 Processing receive와 Worker Redis read는 0이었다.
- **AI Observation:** 하나의 application log가 아니라 producer, Scanner, exporter, downstream progression이 같은 Kafka boundary 이상을 지시했다.
- **AI Diagnostic Inference:** Ingest → Kafka broker availability가 First Broken Boundary이며 Redis/MySQL은 신규 입력을 받지 못한 downstream 상태라는 해석이 `SUPPORTED`다.
- **Competing explanation:** Ingest 자체 장애나 downstream component 장애. 다른 applications의 생존, Redis/MySQL 독립 상태, Kafka-only fault와 timeline이 이를 반증했다.
- **Evidence locator:** [29-detect-impact-recovery-summary.txt](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt), [18-fault-recovery-timeline.txt](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt)

### 13.2 Recommendation → Human-approved Boundary

- **AI Recommendation 역할:** 보존된 동일 Kafka container의 availability만 복원하고, 다른 component나 data/topic/offset state는 변경하지 않으며, 이후 flow·backlog·reconciliation을 read-only로 검증한다.
- **Decision Criterion:** Kafka availability가 First Broken Boundary이고 기존 container identity와 storage가 보존되며 승인된 Compose context와 일치해야 한다.
- **Human-approved Boundary:** Material Run은 Kafka `stop/start`만 허용하고 state 조작, 다른 component restart, recreate를 금지한 승인 경계에서 수행됐다.
- **Authority:** material state change의 승인은 Human이 보유하며 executor는 승인 내용을 확장할 수 없다.
- **Source:** [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)의 Material Failure Run과 [RUNBOOK.md](./RUNBOOK.md)의 안전 경계

### 13.3 Bounded Execution → Component/Flow Recovery

- **Execution:** 승인된 primary recovery는 동일 Kafka container `start` 한 번이었다. 다른 component restart, topic/data/offset 조작, manual repair는 없었다.
- **Verification Evidence:** 동일 container ID가 유지됐고 `07:46:48.405Z` 첫 Kafka publish, `07:46:48.823Z` 첫 Processing consume, `07:46:49.398Z` 첫 Scanner retry success, `07:46:50Z` broker probe가 확인됐다.
- **AI technical assessment 역할:** `Component Recovered`와 `Flow Recovered` criteria는 `PASS`다. 이 판정만으로 Recovery Complete를 선언하지 않는다.
- **Evidence locator:** [29-detect-impact-recovery-summary.txt](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt)

### 13.4 Backlog Drain → Reconciliation

- **Generated logical identities:** healthy 300 + outage 220 + post-recovery 300 = `820`.
- **Kafka transport records:** `1,235`.
- **Retry-induced transport duplicates:** `415`.
- **Processing:** received `1,235`, new `820`, duplicate `415`, error `0`.
- **Final MySQL unique persisted:** `820`.
- **Terminal state:** DLQ `0`, DLT `0`, pending `0`, unaccounted `0`, final duplicate row `0`.
- **Backlog Evidence:** `07:49:18Z`와 `07:49:34Z` 두 sample에서 Kafka lag, Redis group lag, Redis PEL, retry remaining이 0으로 수렴했다.

```text
820 logical identities
≠ 1,235 Kafka transport records

1,235 transport records
= 820 logical identities
+ 415 retry-induced transport duplicates
```

`415`는 final business duplicate row 수가 아니다. 같은 logical identity의 retry-induced transport duplicate이며 Processing의 Redis dedupe가 이를 분류했다. 이 수치는 Material Run Evidence이지 운영 threshold나 production guarantee가 아니다.

- **AI reconciliation assessment 역할:** `Generated unique 820 = MySQL unique 820 + DLQ 0 + DLT 0 + pending 0 + unaccounted 0`이며, 이 bounded run의 Backlog Drain과 End-to-end Reconciliation criteria는 `PASS`다.
- **Evidence locator:** [22-backlog-drain-observation.txt](./evidence/20260829T073503Z/22-backlog-drain-observation.txt), [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt)

### 13.5 Technical Assessment → Human Acceptance/Accountability

- **AI technical assessment:** 승인 criteria와 Material Run Evidence에 따르면 Component Recovery, Flow Recovery, Backlog Drain, End-to-end Reconciliation은 모두 `PASS`다.
- **Residual uncertainty:** Ingest HTTP status count는 log와 response mapping의 파생치이며, Scanner retry queue는 전용 metric 없이 log로 계량됐다. 추가 single POST의 일부 원인은 working hypothesis로 남았다.
- **Human operational acceptance:** 권한 있는 Human은 위 Evidence, claim boundary와 residual uncertainty를 검토해 실행의 운영적 수용 여부를 결정한다.
- **Operational Accountability:** 최종 결과와 수용된 위험에 대한 책임은 Authorized Human 또는 조직이 보유한다.

이 walkthrough는 로컬 단일 broker bounded run의 결과다. replicated Kafka HA, storage loss, container recreation, Scanner restart, retry queue overflow, production alerting, production RTO/RPO 또는 일반적인 exactly-once를 입증하지 않는다.

## 14. Artifact Boundaries

| Artifact | 답하는 질문 |
|---|---|
| [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md) | 실제로 무엇을 실행했고 무엇을 관측·입증했는가? |
| [OPERATIONAL-DIAGNOSTIC-GUIDE.md](./OPERATIONAL-DIAGNOSTIC-GUIDE.md) | Evidence로 First Broken Boundary를 어떻게 진단하는가? |
| [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md) | Kafka/Redis/분산 시스템 현상이 왜 발생하는가? |
| [RUNBOOK.md](./RUNBOOK.md) | 진단된 조건에서 어떤 승인된 Action과 Verification을 수행하는가? |
| 이 문서 | 누가 진단·추천·승인·실행·검증·Resolution·Acceptance·Accountability를 담당하는가? |
| 향후 Technical Report | 전체 검증 질문과 결과를 어떻게 종합하는가? |
| 향후 README | 검증된 capability를 어떻게 presentation하는가? |

## 15. Candidate Reusable Patterns

아래 항목은 BIP-FR-001 local trial에서 관찰한 후보이며 Framework 또는 Workflow Rule이 아니다.

| Local Observation | Potential Reusable Pattern | Candidate Scope | Reason | Validation Needed |
|---|---|---|---|---|
| Evidence와 해석이 섞이면 timeout을 loss로 오판하기 쉽다. | Human-auditable Resolution Rationale | BIP incident diagnosis local trial | material conclusion의 근거·대안·권한·검증을 한 trace로 검토할 수 있다. | 다른 failure domain과 여러 운영자 handoff에서 비용·명확성 검증 |
| 임의 confidence percentage는 engineering sufficiency를 설명하지 못한다. | Evidence Sufficiency State | BIP operational validation local trial | `SUPPORTED`/`PARTIALLY SUPPORTED`/`CONFLICTED`/`INSUFFICIENT`가 결론 가능 범위를 직접 나타낸다. | 상태 간 전이 기준과 reviewer 일치도 검증 |
| 기술적 criteria 충족과 운영 위험 수용은 책임자가 다르다. | Technical Verification vs Operational Acceptance | BIP recovery declaration local trial | 기술 판정 왜곡 없이 운영 결정을 별도로 기록할 수 있다. | 실제 incident governance와 audit 요구에서 검증 |

Pattern의 재사용이나 상위 Scope 승격은 별도 설계, 비교 검증, Human Gate와 적용 가능한 Governance 절차가 필요하다.

## 16. Claim Boundary

이 문서가 확정하는 것은 BIP-FR-001에 적용할 AI/Human 책임·권한·검증·수용 경계다. 다음은 주장하지 않는다.

- AI가 incident의 material Decision 또는 Operational Accountability를 대체한다.
- Human Approval이 Evidence 부족을 해소하거나 기술적 사실을 만든다.
- 모든 state-changing command가 항상 새 Human Gate를 필요로 한다.
- Human Gate와 Human Resolution 중 하나가 다른 하나보다 상위다.
- AI Verification PASS가 Human Operational Acceptance를 자동으로 만든다.
- Human risk acceptance가 Technical FAIL을 PASS로 바꾼다.
- Material Run의 `820`, `1,235`, `415`가 운영 threshold 또는 production guarantee다.
- 이 local trial의 pattern이 Framework, Workflow 또는 Governance 규칙으로 승격됐다.
- 이 문서가 새로운 runtime Action, fault injection 또는 Material Action을 승인한다.

## 17. References

### 17.1 Operational and Validation Artifacts

- [BIP-FR-001 재현 기록](./REPRODUCTION-RECORD.md)
- [BIP-FR-001 운영 진단 가이드](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)
- [BIP-FR-001 Kafka Failure Learning Note](./KAFKA-FAILURE-LEARNING-NOTE.md)
- [BIP-FR-001 복구 Runbook](./RUNBOOK.md)

### 17.2 Material Run Evidence

- [Detect·Impact·Recovery Summary](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt)
- [Fault·Recovery Timeline](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt)
- [Backlog Drain Observation](./evidence/20260829T073503Z/22-backlog-drain-observation.txt)
- [Final Event Reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt)
- [Final Runtime Safety and Validity](./evidence/20260829T073503Z/31-final-runtime-safety-and-validity.txt)
