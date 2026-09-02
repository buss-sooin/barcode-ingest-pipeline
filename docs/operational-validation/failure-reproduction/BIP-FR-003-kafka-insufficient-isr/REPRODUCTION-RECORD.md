# BIP-FR-003 Kafka insufficient ISR 쓰기 불가 재현 기록

## 1. Record Metadata

- Record ID: `BIP-FR-003-RR`
- Project / Task Scope: `BIP Operating Validation / BIP-FR-003`
- Owner: 이 repository와 local validation 실행에 대한 권한 있는 Human 사용자
- Created At: 2026-09-02
- Updated At: 2026-09-02
- Workflow Version: Failure Reproduction Workflow v0.1
- Record Status: 완료 / 주 실행 `REPRODUCED`

이 문서는 BIP-FR-003의 계약 개정(Contract Revision), 판정 대상 실행(Material Run), Evidence, 검증과 인계(Handoff)를 보존한다. 실행 전 기준은 [재현 계약](./REPRODUCTION-CONTRACT.md), 결과 해석과 최대 검증 주장은 [기술 보고서](./TECHNICAL-REPORT.md)가 담당한다.

## 2. 관찰된 실패와 정의된 시나리오

- 관찰된 실패(Observed Failure): partition leader는 존재하지만 ISR size가 topic `min.insync.replicas`보다 작은 상태에서 `acks=all` 새 쓰기가 성공 확인을 받지 못하는 조건
- 정의된 실패 시나리오(Defined Failure Scenario): `BIP-FR-003 — Kafka Insufficient ISR Write Unavailability During Active Scan`
- 관계: 승인된 로컬 토폴로지에서 위 조건을 의도적으로 만들고 application-visible failure, 설정 완화 없는 기능 복구와 최종 수렴을 검증했다. production incident나 일반 보증을 재현했다고 주장하지 않는다.

## 3. Contract Revision 이력과 Human Gate

- Contract ID: `BIP-FR-003-RC`
- Revision lineage: [`BIP-FR-003-RC-R1`](./REPRODUCTION-CONTRACT.md#bip-fr-003-rc-r1) → [`BIP-FR-003-RC-R2`](./REPRODUCTION-CONTRACT.md#bip-fr-003-rc-r2)
- R1 effective point: 준비 commit `4078118b4f4ad71daf7763e0582d09b4076e8bfb`
- R2 effective point: 준비 commit `baed9cca55167ca024a307b7278b7fc0595d8fe0`
- R2 reason: 첫 ISR=2 sample 즉시 witness를 보낸 R1 절차를 연속 sample과 명시적 안정화 구간으로 교정
- 승인 경계 변화: 없음. topology, failure target 규칙, 두 broker 동시 down 위험, 실패 징후, 성공·정합성·claim 경계 불변
- Human Gate: 승인됨
- Approval reference: `Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation`
- 승인 시각/별도 승인 ID: 독립적으로 확인할 수 없어 생성하지 않음

## 4. Material Run → 정확히 하나의 Revision

| Material Run | 적용 Revision | Outcome | 역할과 편차 |
|---|---|---|---|
| `BIP-FR-003-MR-20260902T112532Z` | `BIP-FR-003-RC-R1` | `INCONCLUSIVE` | controller health key가 없는 환경에서 Evidence inspection template이 실패. 사전 조건 확립 전 종료, SIGKILL 0회 |
| `BIP-FR-003-MR-20260902T113950Z` | `BIP-FR-003-RC-R1` | `INCONCLUSIVE` | `P=1`, `L0=2`, clean leader `2→3`, ISR 3→2까지 관측했으나 첫 ISR=2 sample 즉시 witness를 보내 안정화 선행 조건 미확립. F1 SIGKILL 0회 |
| `BIP-FR-003-MR-20260902T114420Z` | `BIP-FR-003-RC-R2` | `REPRODUCED` | 연속 ISR=2 안정화, active traffic 중 ISR=1 실패 witness, ISR 1→2 기능 복구, ISR 2→3 전체 복구와 정합성을 검증한 주 실행 |

```text
BIP-FR-003-MR-20260902T112532Z → BIP-FR-003-RC-R1
BIP-FR-003-MR-20260902T113950Z → BIP-FR-003-RC-R1
BIP-FR-003-MR-20260902T114420Z → BIP-FR-003-RC-R2
```

각 Run은 한 Revision만 참조한다. R1 첫 시도의 inspection template 수정은 실험 절차 변경이 아니어서 R1을 유지했다. R1 두 번째 실행이 노출한 ISR=2 안정화 orchestration 문제는 material procedure redesign이므로 R2를 만들었지만 승인된 Risk/Blast Radius는 확대하지 않았다.

## 5. Evidence 위치와 무결성

| Material Run | Evidence | Manifest | 핵심 판정 |
|---|---|---|---|
| `...112532Z` | [디렉터리](./evidence/BIP-FR-003-MR-20260902T112532Z/) | [SHA-256](./evidence/BIP-FR-003-MR-20260902T112532Z/MANIFEST.sha256) | [장애 주입 전 종료](./evidence/BIP-FR-003-MR-20260902T112532Z/44-aborted-before-injection.txt) |
| `...113950Z` | [디렉터리](./evidence/BIP-FR-003-MR-20260902T113950Z/) | [SHA-256](./evidence/BIP-FR-003-MR-20260902T113950Z/MANIFEST.sha256) | [ISR=2 안정화 편차](./evidence/BIP-FR-003-MR-20260902T113950Z/46-deviation-verdict.txt) |
| `...114420Z` | [디렉터리](./evidence/BIP-FR-003-MR-20260902T114420Z/) | [SHA-256](./evidence/BIP-FR-003-MR-20260902T114420Z/MANIFEST.sha256) | [주 실행 checks](./evidence/BIP-FR-003-MR-20260902T114420Z/43-run-checks.txt) |

각 Evidence 디렉터리에서 `shasum -a 256 -c MANIFEST.sha256`로 독립 검증할 수 있다. 세 manifest는 canonical synchronization 전에 전 항목 `OK`로 재검증했다.

## 6. R1 실행 이력

### 6.1 `BIP-FR-003-MR-20260902T112532Z`

`2026-09-02T11:36:53Z`에 실행 정체성과 config 캡처를 시작했으나 healthcheck가 없는 controller에서 `.State.Health`를 직접 읽은 inspection template이 실패했다. broker/controller/application은 모두 running이었고 SIGKILL은 없었다. 실험 유효성을 확립하지 못했고 중앙 실패 징후를 실행하지 않았으므로 `INCONCLUSIVE`다.

### 6.2 `BIP-FR-003-MR-20260902T113950Z`

| UTC | 관측 |
|---|---|
| `11:42:16` | healthy mapping probe, `P=1`, `L0=2` |
| `11:42:22` | `L0=2` SIGKILL |
| `11:42:34` | 첫 `leader=3`, ISR `3,1` sample과 동시에 degraded witness 시작 |
| `11:42:39` | Ingest 5초 확인 timeout, HTTP 503 |
| `11:42:41.601` | 같은 underlying send가 partition 1 offset 168 acknowledgment를 뒤늦게 받음 |
| 이후 | F1 kill 전 중단, broker 2 same-volume 안전 복구, generated unique 2 = MySQL unique 2 |

ISR=2 write 가능성 자체는 late acknowledgment로 관측됐지만, “stabilize new leader with ISR=2”를 선행 조건으로 확립하지 않았다. 따라서 중앙 ISR=1 실패 징후로 진행하지 않고 `INCONCLUSIVE`로 판정했으며 R2를 만들었다.

## 7. R2 주 실행 — `BIP-FR-003-MR-20260902T114420Z`

### 7.1 실행 정체성과 런타임 역할

- 실행 HEAD: `baed9cca55167ca024a307b7278b7fc0595d8fe0`
- 실제 실행: `2026-09-02T11:47:47Z–11:50:21Z`
- `P=1`, `L0=2`, `L1=3`, `F1=1`
- 시작 ISR: `3,1,2`
- producer runtime: `acks=-1(all)`, `enable.idempotence=true`, `retries=3`, 3-broker bootstrap

근거는 [실행 정체성](./evidence/BIP-FR-003-MR-20260902T114420Z/00-run-identity-and-contract.txt), [유효 설정](./evidence/BIP-FR-003-MR-20260902T114420Z/before/01-effective-runtime-config.txt), [런타임 역할](./evidence/BIP-FR-003-MR-20260902T114420Z/05-runtime-role-mapping.txt)에 있다.

### 7.2 인과 시간선

| UTC | 직접 관측 | 의미 |
|---|---|---|
| `11:48:12` | `L0=2` SIGKILL | 첫 failure target은 `P=1`의 현재 leader |
| `11:48:23–11:48:26` | clean leader `2→3`, ISR `3,1,2→3,1` 연속 확인 | `L1=3`, `F1=1`; R2 안정 sample 충족 |
| `11:48:26–11:48:37` | 10초 안정화 뒤 같은 leader/ISR 재검증 | `L0` down 상태 유지 |
| `11:48:37` | ISR=2 witness HTTP 200, offset 170 ack | 두 in-sync replica에서 새 쓰기 성공 |
| `11:48:40` | bounded active Scanner traffic 시작 | 총 50개 driver request |
| `11:48:46` | `L1=3`, ISR `3,1`, `F1=1` follower 재확인 후 F1 SIGKILL | current leader를 kill하지 않음 |
| `11:48:59` | `leader=3`, ISR `3` | leader 존재 + ISR=1 직접 확인 |
| `11:49:07–11:49:12` | 고유 failure witness 수신, offset `177→177`, HTTP 503 | active traffic 중 성공 ack 부재 |
| `11:49:18–11:49:23` | F1=1 same-volume 복구, ISR `3→3,1` | 설정 완화·application restart 없는 기능 복구 |
| `11:49:24` | recovery witness HTTP 200, offset 213 ack | ISR=2 write acceptance 회복 |
| `11:49:27–11:49:37` | L0=2 same-volume 복구, 전체 ISR=3 | URP 0, unavailable 0, broker 3개 healthy |
| `11:49:33` | active traffic 종료 | failure witness 시각이 traffic 구간 내부 |
| `11:50:21` | 정합성·manifest checks 완료 | lag/DLQ/DLT/pending/unaccounted 0 |

## 8. 재시도·증폭과 정합성

### 8.1 관측량

```text
54 generated logical identities
= 53 final MySQL unique identities
+ 1 directly evidenced expected rejection
+ 0 DLQ/DLT/pending/unaccounted

54 Kafka transport records
= 53 Kafka unique identities
+ 1 transport duplicate
```

- top-level manifest: mapping 1, ISR=2 degraded witness 1, active Scanner 50, ISR=1 failure witness 1, ISR=2 recovery witness 1
- driver HTTP: 53건 200, 의도한 failure witness 1건 503; driver retry 0
- Scanner: fallback log event 21회가 31개 failed index를 단건 경로로 넘겼고 retry queue high-water는 16/10000, drop 0, 최종 queue 0이었다.
- Ingest: batch HTTP 38회에서 총 51 item, single HTTP 74회를 수신했다. 단건 74회 중 3회는 명시적 witness이고 나머지는 Scanner fallback·queue retry·HTTP client 재실행 경계다.
- Ingest send callback: 성공 53회, 실패 72회로 총 125 application `KafkaTemplate.send()` 결과가 기록됐다.
- Kafka: 54 records, 53 unique scanTime, 중복 identity 1개.
- Processing: 같은 barcode의 offset 177과 198을 수신하고 duplicate 1회를 검출했다.

Transport duplicate identity는 Scanner-origin 단건 HTTP 제출이 반복된 상태에서 발생했다. 첫 record offset 177에는 동일 시점의 성공 acknowledgment가 없고, 재제출 경계의 record offset 198에는 성공 acknowledgment가 있다. 따라서 특정 send의 exact ACK-loss sequence는 미해결로 남지만, Kafka leader가 저장 record를 독립 replay했다는 증거는 아니다.

### 8.2 최종 integrity

- failure witness scanTime `1788349746303`: Kafka slice와 MySQL에 없음, 직접 입증된 expected rejection 1
- Kafka에 들어간 unique 53개: MySQL unique 53개와 일치
- transport duplicate 1: Processing dedupe로 business duplicate 0
- missing/unaccounted/extra: 0
- Kafka target lag 0, Redis group lag 0, PEL 0, DLQ 0, DLT 0

근거는 [정합성 요약](./evidence/BIP-FR-003-MR-20260902T114420Z/final/42-run-scoped-reconciliation-summary.txt), [Kafka records](./evidence/BIP-FR-003-MR-20260902T114420Z/final/29-run-scoped-kafka-records.jsonl), [MySQL rows](./evidence/BIP-FR-003-MR-20260902T114420Z/final/27-run-scoped-mysql-rows.tsv)에 있다.

## 9. Verification

### 1. 실험 유효성(Experiment Validity)

평가: `VALID`

- approved R2 HEAD와 clean working tree에서 실행했다.
- controller는 계속 UP이었고 application·Redis·MySQL·worker를 재시작하지 않았다.
- runtime discovery로 P/L0/L1/F1을 정했고 두 번째 kill 직전에 F1이 follower임을 다시 확인했다.
- `L0=2`, `F1=1`만 순차 SIGKILL했고 `L1=3`은 계속 살아 있었다.
- volume, topic, offset, minISR, `acks`, unclean election을 변경하지 않았다.
- recovery 순서는 F1→ISR=2→witness→L0→ISR=3이었다.

### 2. 증거 충분성(Evidence Sufficiency)

평가: `SUFFICIENT`

계약/Revision, 실행 정체성, runtime ProducerConfig, topic config, role mapping, container/volume, 시간 술어, ISR·leader·offset, application request/error/ack, retry queue, Kafka record identity, Processing duplicate와 MySQL reconciliation이 manifest로 추적된다.

### 3. 실패 징후 평가(Failure Signature Evaluation)

평가: `SATISFIED`

- active traffic: `11:48:40–11:49:33Z`
- leader exists + ISR=1: broker 3 healthy, partition 1 ISR `3`
- 새 application/Kafka attempt: `11:49:07Z`, unique barcode `9913497463030`
- application-visible failure: 5초 confirmation timeout과 HTTP 503
- producer callback: `NotEnoughReplicasException` — required ISR보다 적어 reject됨
- partition offset: witness 전후 `177→177`; identity는 Kafka/MySQL에 없음

### 4. Outcome

- Outcome: `REPRODUCED`
- 근거: 유효하고 충분한 R2 실행에서 사전 고정한 insufficient ISR 실패 징후와 설정 완화 없는 기능 복구, 전체 복구와 identity reconciliation을 모두 확인했다.

## 10. 증거 → 주장 매핑

| 주장 | 분류 | Evidence |
|---|---|---|
| effective topology/topic/producer config | 직접 증명(Directly Proven) | [effective config](./evidence/BIP-FR-003-MR-20260902T114420Z/before/01-effective-runtime-config.txt), [healthy state](./evidence/BIP-FR-003-MR-20260902T114420Z/before/02-healthy-preconditions.txt) |
| `P=1`, `L0=2`, clean leader `L1=3`, `F1=1` | 직접 증명 | [role mapping](./evidence/BIP-FR-003-MR-20260902T114420Z/05-runtime-role-mapping.txt), [first transition](./evidence/BIP-FR-003-MR-20260902T114420Z/timeline/10-first-transition-isr3-to2.txt) |
| ISR=2 write 성공 | 직접 증명 | [degraded witness](./evidence/BIP-FR-003-MR-20260902T114420Z/07-isr2-write-witness.txt), [application log](./evidence/BIP-FR-003-MR-20260902T114420Z/08-isr2-write-application-logs.txt) |
| active traffic ∩ leader ∩ ISR=1 ∩ failure witness | 직접 증명 | [traffic](./evidence/BIP-FR-003-MR-20260902T114420Z/09-active-traffic-boundaries.txt), [ISR1 state](./evidence/BIP-FR-003-MR-20260902T114420Z/13-isr1-leader-alive-state.txt), [failure witness](./evidence/BIP-FR-003-MR-20260902T114420Z/14-isr1-failure-witness.txt) |
| `NotEnoughReplicasException`, offset 불변, no downstream identity | 직접 증명 | [failure logs](./evidence/BIP-FR-003-MR-20260902T114420Z/15-isr1-failure-application-logs.txt), [failure verification](./evidence/BIP-FR-003-MR-20260902T114420Z/16-isr1-failure-verification.txt), [reconciliation](./evidence/BIP-FR-003-MR-20260902T114420Z/final/42-run-scoped-reconciliation-summary.txt) |
| F1 복구 후 ISR=2 write 회복 | 직접 증명 | [F1 recovery](./evidence/BIP-FR-003-MR-20260902T114420Z/18-F1-functional-recovery.txt), [ISR transition](./evidence/BIP-FR-003-MR-20260902T114420Z/timeline/19-functional-recovery-isr1-to2.txt), [recovery witness](./evidence/BIP-FR-003-MR-20260902T114420Z/20-isr2-recovery-write-witness.txt) |
| L0 복구, ISR=3/URP0/unavailable0 | 직접 증명 | [L0 recovery](./evidence/BIP-FR-003-MR-20260902T114420Z/22-L0-full-recovery.txt), [full recovery](./evidence/BIP-FR-003-MR-20260902T114420Z/timeline/17-full-recovery-isr2-to3.txt) |
| `54 logical → 54 records(53 unique+1 duplicate) → 53 MySQL unique + 1 expected rejection` | 직접 증명 | [generated manifest](./evidence/BIP-FR-003-MR-20260902T114420Z/03-generated-manifest.tsv), [reconciliation](./evidence/BIP-FR-003-MR-20260902T114420Z/final/42-run-scoped-reconciliation-summary.txt) |

## 11. Directly Proven / Strongly Inferred / Unresolved

### 직접 증명(Directly Proven)

- 위 Verification과 Evidence → Claim 표의 runtime/config/state/timeline/identity 사실
- producer runtime `enable.idempotence=true`를 포함한 캡처 값
- Scanner retry queue high-water 16, final 0, drop 0
- application send 결과 125개 중 success callback 53, failure callback 72
- duplicate identity가 두 Kafka offset에서 관측되고 Processing이 한 번 제거한 사실

### 강한 추론(Strongly Inferred)

- Kafka client metadata refresh와 재연결 과정이 R1 late acknowledgment 및 R2 전이 지연에 관여했다는 설명
- 반복 HTTP 제출과 confirmation ambiguity가 transport duplicate 발생 조건을 만들었다는 인과 설명

### 미해결(Unresolved)

- 각 application send의 exact Kafka 내부 retry count
- offset 177 record가 어떤 request attempt에서 언제 append되고 어떤 acknowledgment가 손실됐는지에 대한 wire-level 순서
- producer ID/epoch/sequence의 protocol history와 관측된 `OutOfOrderSequenceException` 각각의 내부 원인
- Scanner-origin 단건 HTTP receipt 71회를 explicit fallback call, retry queue call, HTTP automatic 503 re-execution으로 정확히 분해한 수치
- 이 로컬 bounded run 밖의 일반적인 failover 또는 write-recovery latency

## 12. 검증된 재현 주장(Verified Reproduction Claim)

> 승인된 로컬 BIP-FR-003 토폴로지와 bounded R2 run에서, 전용 KRaft controller가 유지되고 `barcode-events` partition 1의 leader가 broker 3으로 존재하는 동안 follower broker 1을 두 번째로 SIGKILL해 ISR이 1로 내려갔다. RF=3, topic `min.insync.replicas=2`, runtime producer `acks=all`, unclean leader election 비활성화 조건에서 active Scanner traffic과 겹쳐 제출한 고유 application produce witness는 5초 안에 성공 acknowledgment를 받지 못하고 HTTP 503과 `NotEnoughReplicasException`을 남겼으며 partition offset과 downstream identity도 증가하지 않았다. broker 1을 같은 volume으로 먼저 복구해 ISR이 2가 되자 application 재시작이나 설정 완화 없이 새 write가 성공했고, 최초 중단 broker 2까지 같은 volume으로 복구한 뒤 모든 `barcode-events` partition이 ISR 3, URP 0, unavailable partition 0으로 수렴했다. 54개 logical identity는 최종 MySQL unique 53개와 직접 입증된 expected rejection 1개로 모두 귀속됐고, transport duplicate 1개는 Processing dedupe 뒤 business duplicate를 만들지 않았다.

## 13. Claim limitations와 명시적 비주장

다음을 주장하지 않는다.

- 일반적인 exactly-once guarantee 또는 duplicate-free transport
- production HA, SLA, RTO, RPO
- controller HA, 세 번째 broker failure 또는 세 broker 동시 failure tolerance
- network partition, storage loss/corruption/full, topic recreation·offset reset 상황
- 모든 topic/partition assignment 또는 다른 Kafka/client/version/infra의 동일 동작
- SIGKILL 순간 특정 produce가 정확히 in-flight였다는 보장
- application callback timeout이 언제나 Kafka append 실패를 뜻한다는 주장
- Scanner/Processing/Redis/MySQL/worker 결합 장애 복구
- 성능, capacity, 장시간 soak 또는 일반적인 recovery latency 보장
- 관측된 `OutOfOrderSequenceException`의 근본 원인(Root Cause) 확정

## 14. 인계(Handoff)

- Contract / Revision: `BIP-FR-003-RC / BIP-FR-003-RC-R2`
- 주 Material Run: `BIP-FR-003-MR-20260902T114420Z`
- Outcome: `REPRODUCED`
- Experiment Validity: `VALID`
- Evidence Sufficiency: `SUFFICIENT`
- Verified Evidence: 주 실행 Evidence와 `MANIFEST.sha256`
- 후속 책임: 이 결과를 production 보장이나 remediation으로 자동 승격하지 않는다. 운영 정책·설계 변경은 별도 Engineering Intent와 Human Gate를 따른다.
- unresolved: 11절의 protocol-level retry/ack/sequence 및 HTTP attempt 세부 귀속

## 15. Record Integrity Checks

- [x] 관찰된 실패와 정의된 실패 시나리오를 구분했다.
- [x] 각 Run 전에 적용 Contract Revision을 고정했다.
- [x] 모든 Material Run이 정확히 하나의 Revision을 직접 참조한다.
- [x] material procedure redesign을 R2로 보존했다.
- [x] 승인 경계 불변과 새 Human Gate 불필요 판단 근거를 기록했다.
- [x] `Experiment Validity → Evidence Sufficiency → Failure Signature → Outcome` 순서를 지켰다.
- [x] Outcome은 Workflow 허용 값만 사용했다.
- [x] Evidence, 해석, inference와 unresolved 항목을 분리했다.
- [x] Evidence 디렉터리와 Record 책임을 분리하고 manifest locator를 제공했다.
- [x] Claim과 limitations를 Handoff에 보존했다.
