# BIP-FR-003 AI 활용 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: BIP-FR-003에서 AI와 인간 개발자가 어떤 책임과 권한을 맡았는지 확인하려는 개발자  
> 근거 범위: Repository 정본, Material Run Evidence, Git 이력에서 재구성할 수 있는 외부화된 작업만 설명한다.

## 한눈에 보기

BIP-FR-003에서 AI 지원에 적합했던 책임은 재현 계약(Reproduction Contract)을 구조화하고, 승인된 경계 안에서 상태 수집·장애 주입·복구·정합성 검증을 자동화하며, 결과를 원본 Evidence와 대조하는 일이었다. 인간 개발자의 핵심 책임은 어떤 장애와 위험을 허용할지 결정하고, 두 broker가 동시에 중단되는 실행 경계를 승인하며, 교정이 기존 승인 범위 안인지 판단하고, 최종 주장의 범위를 통제하는 것이었다.

이 분리는 “AI가 실행했으므로 AI가 결과를 승인한다”는 뜻이 아니다.

```text
Human: Engineering Intent · 위험 · 권한 · 승인 경계
                         ↓
AI 지원: 계약 구조화 · 자동 실행 · Evidence 수집 · 기준 대조
                         ↓
Repository Evidence: 독립 재검증 가능한 사실과 판정 근거
                         ↓
Human: 주장 범위 · 잔여 불확실성 · 운영적 수용
```

과거 대화의 내부 추론 과정(chain-of-thought)은 복원하지 않는다. Repository에는 FR-003 작업에 사용된 정확한 AI 모델, 각 turn의 추론 수준, 프롬프트 전문이 보존돼 있지 않으므로 이 문서도 이를 추정하지 않는다.

## 1. 책임을 확인한 근거

| Source Artifact | 직접 확인되는 책임 | 이 문서에서의 사용 |
|---|---|---|
| [REPRODUCTION-CONTRACT.md](./REPRODUCTION-CONTRACT.md) | 실행 전 Failure Question, Scope, Failure Signature, 성공·실패·무효 기준, Human Gate, 허용·금지 action | 인간이 승인한 실행 경계와 AI가 따라야 했던 판정 기준 |
| [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md) | 세 Material Run, Contract Revision, 편차, Evidence Sufficiency, Outcome | 실패한 실행을 숨기지 않은 방식과 최종 판정의 추적성 |
| [run-material.sh](./run-material.sh) | 런타임 역할 발견, 안전 술어, 상태 수집, 장애·복구 순서, bounded verification | 자동화된 실행·수집·검증 책임의 구현 |
| [주 Material Run Evidence](./evidence/BIP-FR-003-MR-20260902T114420Z/) | 명령 결과, Kafka·application 상태, 시간선, identity reconciliation | AI 설명과 독립적으로 다시 확인할 수 있는 원자료 |
| [TECHNICAL-REPORT.md](./TECHNICAL-REPORT.md) | 직접 증명, 강한 추론, 미해결, 최대 검증 주장과 Non-Claim | 분석 결과의 증거 경계와 일반화 제한 |
| Git 이력 `4078118` → `3a56246` → `baed9cc` → `3c405c1` | 준비, 사전 조건 편차 보존, R2 절차 교정, 결과 동기화 | 산출물과 교정 순서. 개별 행위자의 내부 의사결정 증거로 사용하지 않음 |

Repository는 산출물과 실행 결과를 증명하지만, 특정 문장을 AI 또는 Human이 최초 제안했다는 사실까지 모두 증명하지는 않는다. 따라서 아래 구분은 확인 가능한 책임 구조를 설명하며, 확인되지 않은 과거 대화 세부를 사실로 만들지 않는다.

## 2. 인간 개발자가 통제한 Engineering Intent와 실행 경계

인간 개발자는 다음 material boundary의 권한자였다.

- 검증할 질문을 “broker가 죽었는가”가 아니라 “leader가 살아 있어도 ISR이 `min.insync.replicas` 아래면 `acks=all` 쓰기가 거부되는가”로 한정한다.
- 로컬 전용 KRaft controller 1개와 broker 3개, `barcode-events` RF=3, topic `min.insync.replicas=2`, producer `acks=all`을 검증 경계로 승인한다.
- 첫 leader broker와 뒤이은 follower broker를 순차 SIGKILL하여 두 broker가 동시에 중단되는 위험을 허용한다.
- current leader, controller, 세 번째 broker, volume, topic, offset, `min.insync.replicas`, `acks`, unclean leader election은 승인 없이 변경하지 못하게 한다.
- 복구 순서를 `F1 same-volume start → ISR 1→2 → recovery witness → L0 same-volume start → ISR 2→3`으로 제한한다.
- 결과를 production HA, SLA, RTO/RPO, storage loss, network partition 또는 일반적인 exactly-once 보장으로 확대하지 않는다.

Repository가 식별하는 승인 참조는 `Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation`이다. 정확한 승인 시각과 별도 승인 ID는 독립 Evidence가 없어 생성하지 않았다.

## 3. AI 지원이 사용된 책임

### 3.1 설계와 분석

AI 지원의 설계 책임은 인간이 정한 의도를 실행 전에 검증 가능한 계약으로 외부화하는 데 있었다.

- Failure Question을 `leader exists + ISR=1 < minISR=2 + acks=all`이라는 인과 경계로 고정한다.
- 정상, 실패, 복구 상태와 각 상태에서 필요한 witness를 구분한다.
- 성공·실패·실행 편차(Deviation)·무효 실험(Invalid Experiment) 기준을 결과가 나오기 전에 명시한다.
- 직접 증명(Directly Proven), 강한 추론(Strongly Inferred), 미해결(Unresolved)을 구분한다.
- 기능 복구와 전체 복구, transport duplicate와 business duplicate를 별도 검증 경계로 둔다.
- Evidence가 허용하는 최대 Claim과 Explicit Non-Claim을 작성한다.

이 책임의 결과는 AI의 내부 추론이 아니라 `REPRODUCTION-CONTRACT.md`, `REPRODUCTION-RECORD.md`, `TECHNICAL-REPORT.md`라는 검토 가능한 산출물로 남았다.

### 3.2 구현과 실행

자동화 스크립트는 승인된 경계를 결정론적으로 적용하는 실행 책임을 맡았다.

- 과거 broker 번호를 가정하지 않고 runtime metadata로 target partition `P`, 최초 leader `L0`, 새 leader `L1`, follower `F1`을 찾는다.
- 두 번째 SIGKILL 직전에 `leader=L1`, ISR size=2, `F1 ∈ ISR`, `F1 != L1`, `L0 ∉ ISR`를 다시 확인한다.
- active traffic, unique witness, Kafka state, application log와 offset을 UTC 시간선으로 수집한다.
- `F1`과 `L0`을 승인된 순서와 같은 volume으로 복구한다.
- ISR, URP, unavailable partition, Kafka/Redis lag, PEL, DLQ/DLT, retry queue와 MySQL identity를 종단 대사한다.
- 필수 조건이 맞지 않으면 다음 장애 주입으로 진행하지 않고 Evidence를 보존한다.

이 자동화는 새로운 권한을 만들지 않는다. 스크립트가 명령을 실행할 수 있다는 사실과 그 명령을 실행할 권한은 다른 문제이며, 허용 action은 Reproduction Contract의 Human Gate 경계에서만 나온다.

### 3.3 검증과 보고

AI 지원의 검증 책임은 결과를 기대 서사에 맞추는 것이 아니라 사전 기준에 대조하는 것이었다.

```text
Experiment Validity
→ Evidence Sufficiency
→ Failure Signature Evaluation
→ Outcome
```

주 실행에서는 다음 연결을 확인했다.

```text
ISR=2 안정 상태의 write 성공
→ active traffic 중 follower 추가 중단
→ leader broker 3은 alive, ISR size=1
→ unique witness HTTP 503 + NotEnoughReplicasException
→ offset 177→177, downstream identity 없음
→ F1 복구로 ISR=2
→ 설정 완화·application restart 없이 write 성공
→ L0 복구 뒤 ISR=3, URP=0, unavailable=0
→ 54 logical identity 전부 귀속, unaccounted=0
```

최종 `REPRODUCED`는 AI 설명 자체가 아니라 Contract와 위 Evidence의 일치에 근거한다.

## 4. Reproduction Contract, Failure Signature, Verification Criteria의 역할

### Reproduction Contract

계약은 실행 전에 질문과 경계를 고정해 결과에 맞춘 기준 변경을 막았다. 특히 ISR=1 failure뿐 아니라 ISR=2의 정상 write, 설정 완화 없는 recovery write, 최종 replica·downstream 수렴까지 하나의 인과 사슬로 요구했다.

### Failure Signature

HTTP 503 하나를 실패 증거로 사용하지 않았다. 다음 항목이 같은 시간 구간과 동일 witness identity로 연결돼야 했다.

- target partition leader 존재
- ISR size 1과 topic `min.insync.replicas=2`
- runtime producer `acks=all`
- active traffic과 고유한 새 produce attempt
- 성공 acknowledgment 부재와 `NotEnoughReplicasException`
- offset 불변과 Kafka/MySQL identity 부재

### Verification Criteria

검증 기준은 단순한 broker 재기동 성공보다 넓었다.

- 안전 술어를 지킨 fault injection
- ISR 3→2→1과 1→2→3 전이
- ISR=2 write 가능, ISR=1 write 거부, ISR=2 write 회복
- same-volume recovery와 configuration 불변
- retry queue·lag·PEL·DLQ/DLT의 terminal 수렴
- generated, Kafka, MySQL, expected rejection의 identity 대사

이 세 구조 덕분에 “leader가 있으니 Kafka는 정상” 또는 “broker가 다시 UP이니 Recovery Complete” 같은 축약을 판정 근거로 사용할 수 없었다.

## 5. 자동화에 적합했던 상태 수집·검증

| 자동화 책임 | 자동화가 적합한 이유 | 보존된 결과 |
|---|---|---|
| runtime role discovery | broker ID를 추정하지 않고 반복 가능한 규칙으로 선택 | `P=1`, `L0=2`, `L1=3`, `F1=1` |
| 연속 metadata sampling | 순간 sample과 안정 상태를 구분 | ISR=2 연속 sample과 10초 안정화 |
| timestamp 정렬 | traffic, fault, witness, recovery의 시간 술어 계산 | failure witness가 active window 안에 있음을 확인 |
| config·상태 캡처 | 실행 시점의 effective value를 source default와 구분 | topic minISR 2, runtime producer `acks=-1(all)` |
| 상태 집합 대사 | 누락·중복을 수작업 인상보다 정확하게 계산 | 54 logical, 53 MySQL unique, expected rejection 1, unaccounted 0 |
| manifest 생성·검증 | 원본 Evidence의 누락·변조 탐지 | 각 Run의 `MANIFEST.sha256` |
| 계약 기반 판정 | 같은 기준을 모든 Run에 일관되게 적용 | 두 `INCONCLUSIVE`, 한 `REPRODUCED` |

자동화가 적합하다는 것은 결과를 무검토 승인해도 된다는 뜻이 아니다. 자동화는 반복 가능한 수집과 계산을 담당하고, 기준의 정당성과 주장 범위는 별도 책임으로 남는다.

## 6. 인간 판단이 필요했던 부분

| 인간 판단 | AI가 대신 확정할 수 없는 이유 |
|---|---|
| 두 broker 동시 down을 허용할지 | 위험과 영향 반경을 수용하는 권한 문제 |
| 어떤 Failure Question이 프로젝트에 가치 있는지 | Engineering Intent와 학습 목표의 선택 |
| 허용·금지 action과 복구 순서 | 파괴 가능성, 데이터 보존과 승인 범위의 결정 |
| R2가 기존 Gate 안의 교정인지 | Risk, Blast Radius와 execution boundary가 바뀌었는지에 대한 책임 있는 판단 |
| 미해결 retry/ACK 세부를 남긴 채 Outcome을 수용할지 | 검증된 Claim과 잔여 불확실성의 운영적 의미 평가 |
| production에 어떤 정책으로 반영할지 | SLA, 비용, RTO/RPO와 조직 책임이 이 로컬 실험 범위를 넘음 |
| 최종 Claim과 공개 범위 | 기술적 판정과 운영적 책임은 동일하지 않음 |

Human Approval은 Evidence 부족을 사실로 바꾸지 않는다. 반대로 AI가 기술 기준을 만족했다고 계산해도 production 적용이나 잔여 위험 수용까지 자동 승인되지는 않는다.

## 7. 실패한 실행과 교정은 어떻게 보존됐는가

| Run | 판정 | 보존한 문제 | 교정 방식 |
|---|---|---|---|
| `BIP-FR-003-MR-20260902T112532Z` | `INCONCLUSIVE` | controller에 health key가 없는데 inspection template이 이를 직접 읽어 사전 조건 확립 전 종료. SIGKILL 0회 | 실험 의미를 바꾸지 않는 inspection 호환성 수정. R1 유지 |
| `BIP-FR-003-MR-20260902T113950Z` | `INCONCLUSIVE` | 첫 ISR=2 sample 즉시 witness를 보내 승인된 안정화 선행 조건 미확립. 이후 late acknowledgment 관측. F1 SIGKILL 0회 | 연속 두 sample, 추가 10초 안정화, witness 직전 재검증을 추가. material procedure redesign으로 R2 생성 |
| `BIP-FR-003-MR-20260902T114420Z` | `REPRODUCED` | R2 전체 인과 사슬과 최종 reconciliation 충족 | 결과·Evidence·Claim을 정본 문서에 동기화 |

두 앞선 실행은 삭제하거나 성공 실행에 합치지 않았다. 성공 기준을 완화하지 않고 편차의 원인만 교정했으며, 각 Run을 정확히 하나의 Contract Revision에 연결했다.

R2 교정은 topology, failure target 규칙, 두 broker 동시 down 위험, Failure Signature, 성공·정합성 기준과 Claim boundary를 바꾸지 않았다. Repository 정본은 이를 기존 Human Gate 안의 변경으로 기록한다.

## 8. AI 결과를 Repository Evidence와 대조한 방법

AI가 만든 설명 또는 판정 후보는 다음 순서로 대조됐다.

```text
사전 계약의 조건
→ 실제 실행 identity와 effective config
→ 원본 Kafka·application 상태와 UTC 시간선
→ identity-level reconciliation
→ Evidence Sufficiency와 Failure Signature 평가
→ Maximum Verified Claim / Explicit Non-Claim
```

예를 들어 failure witness의 HTTP 503은 단독 결론이 아니었다. 같은 시점의 leader·ISR, `NotEnoughReplicasException`, offset `177→177`, Kafka/MySQL identity 부재를 함께 확인했다. 반대로 R1의 HTTP 503은 2.229초 뒤 같은 underlying send의 acknowledgment가 확인됐기 때문에 ISR=2 write failure로 일반화하지 않고 `INCONCLUSIVE` 편차로 보존했다.

또한 최종 성공 건수만 보지 않았다. `54 logical → 54 Kafka records(53 unique + 1 transport duplicate) → 53 MySQL unique + 1 expected rejection`을 대조해 transport duplicate와 business duplicate를 분리했다.

## 9. 이 문서가 주장하지 않는 것

- 과거 AI의 내부 chain-of-thought, 숨은 판단 과정 또는 프롬프트 전문을 복원하지 않는다.
- Repository로 확인되지 않는 AI 모델, 추론 수준, 각 작업의 정확한 session 구성을 추정하지 않는다.
- Git author 정보만으로 각 문장이나 결정의 최초 제안자를 AI 또는 Human으로 확정하지 않는다.
- 자동화 스크립트가 존재한다는 이유만으로 모든 실행이 무인·무감독이었다고 주장하지 않는다.
- `REPRODUCED`를 AI의 독립 승인, production readiness 또는 운영 정책 변경으로 해석하지 않는다.
- 이 로컬 Trial을 조직 공통 AI-Human collaboration rule로 승격하지 않는다.

## 10. 기존 Artifact와의 중복 평가

### 독자 책임의 필요성

AI와 인간의 책임 경계를 한 번에 이해하려는 독자 책임은 FR-003에서도 필요하다. `REPRODUCTION-CONTRACT.md`는 승인된 실행 경계, `REPRODUCTION-RECORD.md`는 Run과 판정, `TECHNICAL-REPORT.md`는 기술 결과를 각자 정확히 설명하지만, “누가 무엇을 정하고 자동화하며 승인했는가”를 처음부터 끝까지 묶어 설명하지는 않는다.

### 독립 파일 필요성

독립 파일의 가치는 있으나 중복 비용도 크다.

- Human Gate, 허용·금지 action, Claim boundary는 `REPRODUCTION-CONTRACT.md`와 중복된다.
- Run 편차와 R1→R2 교정은 `REPRODUCTION-RECORD.md`와 중복된다.
- 직접 증명·추론·미해결과 Maximum Claim은 `TECHNICAL-REPORT.md`와 중복된다.

따라서 이 파일은 사실의 새 정본이 아니라 책임 관점의 읽기 경로로만 유지해야 한다. 장기 구조에서는 각 Source Artifact의 내용을 다시 서술하기보다 책임 매핑과 locator만 남기는 더 짧은 문서, 또는 기존 Record의 전용 절로 통합하는 대안이 가능하다. 이번 Trial만으로 고정 4-file 구조를 표준으로 확정하지 않는다.

## 11. Human Review 확인 항목

이 Draft를 검토할 때 문장 취향보다 다음 판단을 우선한다.

- 실제 인간 통제와 AI 지원 책임이 뒤바뀌거나 과장된 부분이 있는가?
- `Task #52` 외에 Repository가 확인하지 못하는 승인 사실을 잘못 암시하는가?
- R1→R2 교정을 단순 구현 수정 또는 새 Engineering Intent로 잘못 분류했는가?
- 자동화 가능 책임과 material human decision의 경계가 실제 협업 경험과 맞는가?
- 기존 Contract·Record·Report와의 중복 때문에 독립 파일의 가치가 낮은가?

Human이 실제 내용을 확인하기 전에는 이 문서의 상태를 `FINAL`로 변경하지 않는다.
