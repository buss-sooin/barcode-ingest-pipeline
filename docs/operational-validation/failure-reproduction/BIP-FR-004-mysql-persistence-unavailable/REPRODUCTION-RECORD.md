# BIP-FR-004 재현 실행 기록

## 1. Record 상태와 책임

- Record ID: `BIP-FR-004-RR`
- Contract ID: `BIP-FR-004-RC`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`)
- R1 lifecycle: `HISTORICAL / CLOSED`
- R2 lifecycle: `FROZEN / ACTIVE REVISION`
- Existing Human Gate: `PASS` — `00I — 2026-09-04 Human approval`
- Current Material Run Authorization: `EXECUTION COMPLETE / CONTROL PLANE DECISION REQUIRED`
- Material Runs: R1 3개, R2 4개

이 문서는 판정 대상 실행(Material Run)과 계약 개정(Contract Revision)의 일대일 mapping, 실행 편차, 검증 순서, Evidence locator와 제한을 보존한다. R1의 불완전한 실행을 R2 Evidence로 재분류하지 않으며, 중단된 R2 Run을 다른 실행에 재사용하지 않는다.

## 2. Contract Revision lineage

| Contract Revision | Previous Revision | Effective Point | 책임과 상태 |
|---|---|---|---|
| `BIP-FR-004-RC-R1` | 없음 — Initial Revision | R1 freeze commit `18e059a0ab57a5052e3096dd6558285a18c797db` | 최초 계약. 세 Material Run에만 적용되며 현재 `HISTORICAL / NOT REUSABLE` |
| `BIP-FR-004-RC-R2` | `BIP-FR-004-RC-R1` | [R2 Contract](./REPRODUCTION-CONTRACT-R2.md)를 최초로 포함하는 canonicalization commit | 수정된 application-owned reclaim, versioned runtime identity와 phase controller를 고정. 현재 `FROZEN / ACTIVE REVISION` |

R2는 R1 실행에서 확인된 pending reclaim 구현 결함과 단계별 Evidence 전이 공백을 닫기 위한 material procedure revision이다. 승인된 MySQL-only failure scenario, full-pipeline topology, 위험/영향 반경(Risk/Blast Radius), Failure Signature의 본질, Verification Criteria와 주장 경계를 확대하지 않았다. 기존 승인 경계가 유지되므로 새 사람 승인 관문(Human Gate)을 자동으로 요구하지 않지만, `00J`가 authorization을 복원하기 전에는 실행할 수 없다.

## 3. Run → Contract Revision 등록부

각 Material Run은 정확히 하나의 Revision만 직접 참조한다.

| Material Run | Contract Revision | Human Gate Reference | 실행 상태 | 실험 유효성 | Evidence Sufficiency | Outcome | Evidence / Manifest |
|---|---|---|---|---|---|---|---|
| `BIP-FR-004-MR-20260904T090410Z` | `BIP-FR-004-RC-R1` | `00I — 2026-09-04 Human approval` | traffic 완료 뒤 fault 전 중단 | `FAIL` | `INSUFFICIENT` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260904T090410Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260904T090410Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260904T094838Z` | `BIP-FR-004-RC-R1` | `00I — 2026-09-04 Human approval` | traffic 시작 전 중단 | `FAIL` | `INSUFFICIENT` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260904T094838Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260904T094838Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260904T095755Z` | `BIP-FR-004-RC-R1` | `00I — 2026-09-04 Human approval` | fault/recovery 수행 후 invalid closure | `FAIL` | `PARTIAL / INSUFFICIENT FOR OUTCOME` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260904T095755Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260904T095755Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260908T021905Z` | `BIP-FR-004-RC-R2` | `00I — 2026-09-04 Human approval` | traffic 5건 뒤 driver 비정상 종료, fault 미주입 | `FAIL` | `SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260908T021905Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260908T021905Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260908T045054Z` | `BIP-FR-004-RC-R2` | `00I — 2026-09-04 Human approval` | 정상 traffic 750건 완료 뒤 fault 경계 미진입 | `FAIL` | `SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260908T045054Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260908T045054Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260908T052751Z` | `BIP-FR-004-RC-R2` | `00I — 2026-09-04 Human approval` | baseline 646초 경과로 controller가 traffic-fault 전환 거부, fault 미주입 | `FAIL` | `SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE` | `INCONCLUSIVE` | [Evidence](./evidence/BIP-FR-004-MR-20260908T052751Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260908T052751Z/MANIFEST.sha256) |
| `BIP-FR-004-MR-20260908T055225Z` | `BIP-FR-004-RC-R2` | `00I — 2026-09-04 Human approval` / `71F` execution routing | controller 전 단계 PASS, active traffic 중 MySQL fault와 same-container recovery, natural reclaim 및 750건 reconciliation 완료 | `PASS` | `PARTIAL — sufficient for partial reproduction claim, insufficient for full record-level ownership claim` | `PARTIALLY_REPRODUCED` | [Evidence](./evidence/BIP-FR-004-MR-20260908T055225Z/) / [Manifest](./evidence/BIP-FR-004-MR-20260908T055225Z/MANIFEST.sha256) |

첫 Run의 `INCONCLUSIVE`는 raw `run-deviation.txt`의 `OUTCOME_CANDIDATE`와 일치한다. 둘째와 셋째 Run의 `INCONCLUSIVE`는 Effective Workflow의 판정 순서에 따라, 유효하지 않거나 Outcome 판정에 Evidence가 부족한 실행에는 `NOT_REPRODUCED`를 사용하지 않는다는 규칙을 적용한 closure classification이다. 시스템 실패를 새로 추정한 Outcome이 아니다.

## 4. R1 Material Run history

### 4.1 `BIP-FR-004-MR-20260904T090410Z`

- Mapping: `BIP-FR-004-MR-20260904T090410Z → BIP-FR-004-RC-R1`
- Run Start: `2026-09-04T09:04:10Z`
- Source HEAD captured: `78669f385eb63b103dfcb77ad8c703ea2bbc2ecd`
- Direct Evidence:
  - corrected Kafka/application baseline은 full ISR, URP 없음, unavailable partition 없음과 application health `UP`을 기록했다.
  - traffic은 `2026-09-04T09:34:03Z`부터 `09:37:11Z`까지 `750`건을 시도했고 HTTP 200 `750`, transport error `0`이었다.
  - deviation은 traffic 완료 뒤에도 MySQL fault가 주입되지 않았음을 명시한다.
  - 재확인된 post-abort baseline은 MySQL alive, Redis pending 0/lag 0/DLQ 0, Kafka URP/unavailable 없음이다.
- Experiment Validity: `FAIL` — active traffic과 MySQL fault가 겹치지 않았고 fault가 주입되지 않았다.
- Evidence Sufficiency: baseline, traffic과 abort 이유에는 충분하지만 Failure Signature와 recovery를 평가하기에는 부족하다.
- Failure Signature: 평가 대상 fault가 없으므로 판단하지 않는다.
- Outcome: `INCONCLUSIVE`
- Limitation: 최초 post-abort check의 일부 command가 잘못된 path를 읽어 실패했으며 `post-abort-clean-check-retry.txt`가 corrected Evidence다.
- Credential-safe Evidence provenance:
  - credential-bearing source: `./evidence/BIP-FR-004-MR-20260904T090410Z/01-baseline/mysql-redis-baseline.txt`
  - secure original locator: `/Users/sooinlee/Documents/CodexProjects/.secure-evidence/barcode-ingest-pipeline/BIP-FR-004/BIP-FR-004-MR-20260904T090410Z/01-baseline/mysql-redis-baseline.raw.txt`
  - original SHA-256: `7a3dc5b432eb3a3c155080a560173d6bc4c98ed9fe7778701af82a5c7d952f3c`
  - repository derivative: credential value 3개만 `[REDACTED]` 처리한 동일 locator의 파일
  - provenance Evidence: [`redaction-provenance.txt`](./evidence/BIP-FR-004-MR-20260904T090410Z/00-environment/redaction-provenance.txt)
  - original raw Evidence committed to Git: `NO`

### 4.2 `BIP-FR-004-MR-20260904T094838Z`

- Mapping: `BIP-FR-004-MR-20260904T094838Z → BIP-FR-004-RC-R1`
- Run Start: `2026-09-04T09:48:38Z`
- Source HEAD captured: `78669f385eb63b103dfcb77ad8c703ea2bbc2ecd`
- Direct Evidence:
  - baseline은 MySQL running/ready, Redis pending 0/lag 0/DLQ 0, Kafka URP/unavailable 없음과 application health `UP`을 기록했다.
  - `TRAFFIC_REQUEST_COUNT`와 `TRAFFIC_RATE`가 없어 driver가 `DRIVER_START` 전에 종료됐다.
  - `traffic-driver.txt`는 empty file이며 `TRAFFIC_SENT=0`, MySQL fault 미주입이 deviation에 기록됐다.
- Experiment Validity: `FAIL` — active traffic이 시작되지 않았다.
- Evidence Sufficiency: baseline과 abort 이유에는 충분하지만 Failure Signature와 recovery를 평가할 Evidence가 없다.
- Failure Signature: 평가하지 않는다.
- Outcome: `INCONCLUSIVE`
- Limitation: configuration omission에 의해 실행이 pre-fault에서 끝났으므로 시스템 동작에 대한 부정적 결론을 만들 수 없다.

### 4.3 `BIP-FR-004-MR-20260904T095755Z`

- Mapping: `BIP-FR-004-MR-20260904T095755Z → BIP-FR-004-RC-R1`
- Run Start: `2026-09-04T09:57:55Z`
- Source HEAD captured: `78669f385eb63b103dfcb77ad8c703ea2bbc2ecd`
- Direct temporal Evidence:
  - traffic: `2026-09-04T11:51:12Z` 시작, `11:54:20Z` 종료, attempted/HTTP 200 `750/750`
  - MySQL stop: `11:53:30Z` 요청, `11:53:35Z` 완료
  - Worker DB failure: stop 직후 mapping lookup SQL에서 `Communications link failure`와 `DataAccessResourceFailureException`
  - outage capture: MySQL exited/port closed, Redis PEL `200` (`worker-1=175`, `worker-2=25`, delivery count 1)
  - MySQL recovery: `11:54:54Z` 요청, `11:54:56Z` readiness, 동일 container ID/volume
- Experiment Validity: `FAIL`
  - fault 전·중 traffic overlap과 DB failure/PEL 형성은 관측됐다.
  - 그러나 traffic이 MySQL start보다 `34초` 먼저 종료돼 required post-recovery accepted traffic이 없다.
  - R1 application-owned reclaim은 이후 empty-ID claim 결함으로 자동 복구되지 않았고, 별도 infrastructure OOM contamination도 발견됐다.
- Evidence Sufficiency: `PARTIAL / INSUFFICIENT FOR OUTCOME`
  - fault authenticity, active traffic overlap, DB access failure와 PEL 형성은 직접 지지한다.
  - raw Run Evidence에는 post-recovery new flow, explicit identity별 no-XACK correlation, reclaim completion과 final reconciliation이 완결되지 않았다.
- Failure Signature:
  - Directly Proven: MySQL same-container stop/start, active traffic 중 DB mapping lookup failure, outage 시 PEL 형성.
  - Strongly Inferred: 실패한 batch의 원본 XACK이 보류돼 PEL에 남았다는 연결. Raw log와 PEL이 일관되지만 모든 record의 identity-level ACK 부재를 별도로 캡처하지 않았다.
  - Unresolved in this Run: 각 PEL ID의 exact ACK history, R1 scheduler를 통한 recovery, full terminal reconciliation.
- Outcome: `INCONCLUSIVE`
- Limitation: 관측된 부분 징후는 R2 설계 근거지만 R1의 유효한 재현 주장이나 R2 Outcome으로 승격하지 않는다.

## 5. R1 후속 복구 이력과 경계

R1 세 번째 Run 종료 뒤 별도 recovery/implementation verification에서 다음이 확인됐다.

- accepted third cohort: MySQL `614`, Redis pending `136`, unaccounted `0`, multi-state conflict `0`
- 이전 reclaim 결함: pending entry가 있어도 명시적 `RecordId` 없이 claim하여 `MessageIds must not be empty`
- source fix: `fc36250cf9b90d0e59780ae26e0c6399fc3494c2`
- versioned runtime release: `1ed4675e0d39c05a9656f46c44a76e520cf2c8c1`, parent=`fc36250...`
- application-owned recovery: original PEL cohort `136`을 reclaim/persist/XACK하여 PEL 0
- third cohort final: Redis unique `750`, MySQL unique `750`, Redis DLQ 0, Kafka DLT 0, conflict 0, unaccounted 0
- 후속 Kafka baseline recovery: full ISR, URP 0, unavailable partition 0

이 후속 결과는 runtime baseline recovery와 R2 준비의 근거다. 세 R1 Run directory의 raw Evidence 또는 해당 Run Outcome을 사후 보완하는 자료로 재분류하지 않는다. 현재 repository에 포함된 세 manifest는 Material Run 당시 보존된 파일을 검증하되, credential-bearing 파일 하나는 secure original의 hash/provenance와 credential-safe derivative를 분리한다. 위 후속 runtime verification의 별도 raw capture는 이 corpus에 포함돼 있지 않다는 limitation도 유지한다.

## 6. R2 Material Run history

### 6.1 `BIP-FR-004-MR-20260908T021905Z`

- Mapping: `BIP-FR-004-MR-20260908T021905Z → BIP-FR-004-RC-R2`
- Register: `2026-09-08T02:19:06Z`, controller `register=PASS`
- Approved HEAD: `1244e742b88e29762e894c74b025e1e97e95cdba`
- Baseline recovery:
  - pre-fault preflight에서 broker-3 `ExitCode=137 / OOMKilled=true`, URP `56`을 발견해 traffic 전에 중단했다.
  - 같은 broker-3 container를 한 번 start한 뒤 broker membership, 전체 RF=3 partition `56/56` full ISR, URP 0과 unavailable 0으로 수렴했다.
  - post-recovery full preflight와 controller baseline은 PASS했다. 이는 OOM 근본 원인 해결 주장이 아니라 bounded window의 baseline recovery다.
- Traffic execution:
  - `2026-09-08T03:42:49Z`에 등록된 driver invocation을 시작했다.
  - `03:42:50Z`까지 5개 `DRIVER_EVENT`가 모두 HTTP 200으로 완료됐지만 등록 PID가 사라졌고 `DRIVER_END`는 없다.
  - required pre-fault observation interval과 `traffic-fault` phase를 성립시키지 못했으며 MySQL fault는 주입하지 않았다.
- Limited observation: 종료 전 5건에 대해 Kafka log end, Redis Stream/entries-read와 MySQL row가 각각 5 증가했고 Redis PEL/lag/DLQ 및 Kafka DLT는 0이었다.
- Experiment Validity: `FAIL`
- Evidence Sufficiency: invalid Material Run 실행을 확정하기에는 충분하지만 BIP-FR-004 Failure Signature를 평가하기에는 부족하다.
- Failure Signature Evaluation: `NOT EVALUABLE`
- Outcome: `INCONCLUSIVE`
- Verified Reproduction Claim: 없음
- Claim limitations: 정상 처리된 최초 5건은 MySQL unavailable, PEL retention, application-owned reclaim 또는 recovery를 입증하지 않는다.
- Execution-mechanism finding: repository 밖 비판정 검증에서 background child 방식은 exec session 반환 뒤 사라졌고, 같은 변경 없는 driver를 foreground primary process로 실행했을 때 150/150건과 `DRIVER_END`가 완료됐다. 인과 분류는 `A — Invocation / Execution-Surface Lifecycle Defect`이며 exact signal은 unresolved다. [Non-material Evidence](./evidence/non-material/BIP-FR-004-NM-20260908T042618Z/)
- Run reuse: `NO`. 두 번째 traffic invocation, PID 재등록 또는 `DRIVER_END` 사후 생성은 허용하지 않는다.

### 6.2 `BIP-FR-004-MR-20260908T045054Z`

- Mapping: `BIP-FR-004-MR-20260908T045054Z → BIP-FR-004-RC-R2`
- Register: `2026-09-08T04:50:54Z`, controller `register=PASS`
- Approved HEAD: `1f2064ac783f41083ba0c4d7580523110bf79e57`
- Baseline: full deterministic preflight와 controller baseline이 PASS했고, run-scoped MySQL identity 범위의 선행 row는 0이었다.
- Traffic execution:
  - `2026-09-08T04:54:48Z`부터 `04:57:53Z`까지 foreground primary process로 750건을 실행했다.
  - HTTP 200은 `750`, 다른 HTTP 결과와 transport error는 각각 `0`이며 `DRIVER_END`가 정상 기록됐다.
  - active traffic 중 40초의 다중 관찰에서 Kafka full ISR/URP 0/unavailable 0, Redis ingress와 MySQL persistence 진행, Worker health를 확인했다.
  - 그러나 controller `traffic-fault` 전환 전에 traffic 750건이 모두 끝나 MySQL fault와 active traffic의 시간적 중첩을 만들지 못했다. MySQL fault는 주입하지 않았다.
- Limited observation: 정상경로에서 run-scoped MySQL `750/750`, Redis PEL 0/group lag 0/DLQ 0, Kafka DLT 0과 healthy post-traffic baseline을 확인했다.
- Experiment Validity: `FAIL`
- Evidence Sufficiency: invalid Material Run 실행을 확정하기에는 충분하지만 BIP-FR-004 Failure Signature를 평가하기에는 부족하다.
- Failure Signature Evaluation: `NOT EVALUABLE`
- Outcome: `INCONCLUSIVE`
- Verified Reproduction Claim: 없음
- Claim limitations: 정상 workload 완료는 MySQL unavailable, no-XACK/PEL retention, application-owned reclaim 또는 recovery를 입증하지 않는다.
- Execution-orchestration finding: foreground driver 자체는 정상 완료했지만 fault action과 traffic을 하나의 장기 실행 parent lifetime에서 병행하지 않아 fault 경계가 traffic 종료 뒤로 밀렸다. RC-R2 workload, Failure Signature, Verification Criteria와 위험 경계는 변경하지 않는다.
- Concurrent lifecycle verification: repository 밖 비판정 검증에서 하나의 살아 있는 parent shell이 traffic child를 소유한 상태로 read-only checkpoint 전·후 child liveness를 유지했고, 60/60 HTTP 200, 정확히 하나의 `DRIVER_END`와 PID cleanup을 확인했다. Post-test Kafka/Redis/MySQL/Worker baseline도 PASS했다. [Non-material Evidence](./evidence/non-material/BIP-FR-004-NM-20260908T052533Z/)
- Run reuse: `NO`. 두 번째 traffic invocation 또는 이 Run ID를 사용한 fault 실행은 허용하지 않는다.

### 6.3 `BIP-FR-004-MR-20260908T052751Z`

- Mapping: `BIP-FR-004-MR-20260908T052751Z → BIP-FR-004-RC-R2`
- Register: `2026-09-08T05:27:52Z`, controller `register=PASS`
- Approved HEAD: `5f320d75b1b858d0cf874b9a442b8d480753bf19`
- Baseline: full deterministic preflight와 controller baseline이 PASS했다. Controller는 baseline `PASS` 완료 시각 `2026-09-08T05:29:23Z`의 epoch를 freshness clock 시작점으로 기록했다.
- Traffic execution:
  - single long-lived parent가 traffic child를 소유하는 검증된 concurrent lifecycle로 `2026-09-08T05:38:51Z`에 driver를 시작했다.
  - controller `traffic-pre`는 PASS했고, child가 살아 있는 동안 171개 `DRIVER_EVENT`가 HTTP 200으로 완료됐다. `DRIVER_END`는 없었다.
  - pre-fault 관찰에서 Kafka full ISR/URP 0/unavailable 0, Redis ingress와 MySQL persistence 진행, Redis PEL/lag 0을 확인했다.
  - `traffic-fault` 전환 시 baseline age가 허용 최대 600초보다 큰 646초여서 controller가 `stale_baseline`으로 거부했다. 계약에 따라 MySQL fault를 주입하지 않고 traffic child를 종료했다.
- Limited observation: 성공한 pre-fault 관찰은 정상 경로 Evidence로만 보존하며 BIP-FR-004 재현 Evidence로 사용하지 않는다.
- Experiment Validity: `FAIL`
- Evidence Sufficiency: invalid Material Run 실행을 확정하기에는 충분하지만 BIP-FR-004 Failure Signature를 평가하기에는 부족하다.
- Failure Signature Evaluation: `NOT EVALUABLE`
- Outcome: `INCONCLUSIVE`
- Verified Reproduction Claim: 없음
- Run reuse: `NO`. 이 Run ID, baseline, traffic cohort 또는 정상 경로 Evidence를 후속 재현 실행에 재사용하지 않는다.

### 6.4 `BIP-FR-004-MR-20260908T055225Z`

- Mapping: `BIP-FR-004-MR-20260908T055225Z → BIP-FR-004-RC-R2`
- Register: `2026-09-08T05:52:25Z`, controller `register=PASS`
- Approved HEAD: `c4a8e46b36039b3fbe8328c11a660babeea5100a`
- Contract SHA-256: `8d765bd3b2d71820dade244d0ab7bf525cf6b28f374f358ac19b653d2cd7f9cf`
- Timeline:
  - full preflight `PASS`: `2026-09-08T06:01:49Z`
  - controller baseline `PASS` 및 freshness clock 시작: `06:01:52Z`
  - traffic 시작: `06:01:52Z`
  - pre-fault predicate 충족: `06:02:29Z`; fault 직전 baseline age `36초`, traffic PID alive, `DRIVER_END` 없음
  - controller `traffic-fault=PASS`: `06:02:30Z`
  - MySQL fault 완료: `06:02:34Z`
  - outage 관찰 완료: `06:03:37Z`; MySQL port closed, Worker DB access failure, Redis PEL `252`
  - 동일 MySQL container/volume readiness 복원: `06:03:43Z`
  - post-recovery traffic persistence 확인: `06:04:16Z`; MySQL cohort `297 → 415`
  - traffic 정상 완료: `06:05:08Z`; attempted/HTTP 200 `750/750`, HTTP other/transport error `0/0`, `DRIVER_END` 정확히 1회
  - application-owned reclaim 완료: `06:08:25Z`; 남은 PEL `132 → 0`, MySQL cohort `618 → 750`
  - reconciliation 완료: `06:08:42Z`; Redis run identity `750`, MySQL unique `750`, Redis DLQ `0`, Kafka DLT `0`, pending `0`, group lag `0`, unaccounted `0`, multi-state conflict `0`
- Experiment Validity: `PASS`
- Evidence Sufficiency: `PARTIAL — sufficient for partial reproduction claim, insufficient for full record-level ownership claim`
- Failure Signature Evaluation:
  - FS-1 Fault authenticity: `SATISFIED`
  - FS-2 Upstream isolation: `SATISFIED`
  - FS-3 Persistence failure / ownership retention: `PARTIALLY SATISFIED`
  - FS-4 Application-owned reclaim / ACK boundary: `PARTIALLY SATISFIED`
  - FS-5 Recovery / accountability: `SATISFIED`
  - Conditional Retry/DLQ path: `NOT OBSERVED / CODE PATH NOT REACHED`
- Outcome: `PARTIALLY_REPRODUCED`
- Verified Reproduction Claim:

  > `BIP-FR-004-RC-R2`의 active traffic 중 MySQL persistence unavailable 상태가 Worker DB access failure와 Redis PEL ownership accumulation을 만들었으며, Kafka와 비대상 subsystem은 healthy 상태를 유지했다. 동일 MySQL container와 volume을 복원한 뒤 application-owned reclaim activity가 관찰됐고 PEL은 0으로 drain됐으며, accepted cohort 750건 전부가 DLQ, DLT, unaccounted record 또는 conflict 없이 MySQL로 reconcile됐다.

- Claim limitations:

  > 현재 Evidence는 동일한 Redis `RecordId` 하나를 `DB failure → no XACK → PEL retention → explicit-ID XCLAIM → persistence → XACK` 전체 사슬에 걸쳐 직접 연결하지 못한다. 따라서 record-level ownership/ACK traceability는 부분적으로만 검증됐다.

- Evidence locators:
  - controller phase graph와 exact timeline: [`controller/events.tsv`](./evidence/BIP-FR-004-MR-20260908T055225Z/controller/events.tsv), [`timeline.tsv`](./evidence/BIP-FR-004-MR-20260908T055225Z/00-environment/timeline.tsv)
  - baseline/fault overlap: [`baseline.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/01-baseline/baseline.txt), [`immediate-pre-fault-witness.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/03-fault/immediate-pre-fault-witness.txt)
  - fault/PEL/Worker: [`mysql-stop.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/03-fault/mysql-stop.txt), [`outage-state.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/03-fault/outage-state.txt), [`outage-pending.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/05-redis/outage-pending.txt), [`outage-worker.log`](./evidence/BIP-FR-004-MR-20260908T055225Z/04-worker/outage-worker.log)
  - recovery/reclaim: [`mysql-recovery.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/07-recovery/mysql-recovery.txt), [`post-recovery-traffic.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/07-recovery/post-recovery-traffic.txt), [`reclaim-evidence.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/07-recovery/reclaim-evidence.txt), [`material-window-worker.log`](./evidence/BIP-FR-004-MR-20260908T055225Z/04-worker/material-window-worker.log)
  - reconciliation/final health: [`reconciliation.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/reconciliation.txt), [`final-preflight.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/final-preflight.txt)
  - Evidence integrity: [`MANIFEST.sha256`](./evidence/BIP-FR-004-MR-20260908T055225Z/MANIFEST.sha256), [`credential-check.txt`](./evidence/BIP-FR-004-MR-20260908T055225Z/00-environment/credential-check.txt)

## 7. Control Plane 결정 대기

`BIP-FR-004-MR-20260908T055225Z`의 `PARTIALLY_REPRODUCED` 결과는 동기화됐다. 이 Record는 추가 Material Run을 등록하거나 RC-R3를 생성·승인하지 않는다.

Control Plane은 다음 중 하나를 결정한다.

1. 현재 verified partial claim과 limitation으로 BIP-FR-004를 닫는다.
2. 동일 Redis `RecordId`의 XCLAIM/XACK traceability가 closure에 필수라면 RC-R3 assessment를 별도로 수행한다.

## 8. R2 verification과 Evidence navigation

판정 순서는 다음과 같다.

```text
실험 유효성(Experiment Validity)
→ 증거 충분성(Evidence Sufficiency)
→ 실패 징후 평가(Failure Signature Evaluation)
→ Outcome
```

R2의 E0~E8, FS-1~FS-5와 Recovery Complete 기준은 [R2 Contract](./REPRODUCTION-CONTRACT-R2.md)에 고정돼 있다. Future Run locator는 다음 형식을 사용한다.

```text
./evidence/BIP-FR-004-MR-<UTC>/
./evidence/BIP-FR-004-MR-<UTC>/MANIFEST.sha256
```

Raw Evidence는 정규화, 덮어쓰기 또는 다른 Run/Revision으로 이동하지 않는다.

## 9. 인계(Handoff)

- R1 Run references: 3절의 세 Material Run
- R1 Outcome: 모두 `INCONCLUSIVE`
- R1 Verified Claim: 세 번째 Run에서 active traffic과 겹친 MySQL stop, mapping lookup DB failure와 PEL 형성까지만 직접 관측
- Claim limitations: 유효한 post-recovery traffic, identity-level ACK correlation, natural reclaim와 final reconciliation이 단일 R1 Run Evidence로 완결되지 않음
- R2 Contract: `BIP-FR-004-RC-R2`
- R2 Material Runs: 세 historical `INCONCLUSIVE` Run과 `BIP-FR-004-MR-20260908T055225Z` 한 개의 `PARTIALLY_REPRODUCED` Run. 모두 각각 `BIP-FR-004-RC-R2` 하나만 참조한다.
- R2 verified claim: active traffic 중 MySQL persistence unavailable, Worker DB access failure, PEL accumulation, same-container recovery, application-owned reclaim activity, PEL 0과 750건 MySQL reconciliation까지 검증됐다.
- R2 claim limitation: 동일 Redis `RecordId`를 DB failure부터 XACK까지 직접 연결하는 record-level ownership/ACK traceability는 부분 검증이다.
- Next responsibility: `PARTIALLY_REPRODUCED`로 BIP-FR-004를 닫을지, record-level XCLAIM/XACK traceability를 위한 RC-R3 assessment가 필요한지 Control Plane이 결정한다. 이 Record는 RC-R3를 생성하거나 승인하지 않는다.
- Unresolved historical field: R2의 exact approval timestamp와 독립 approval ID는 repository Evidence에 없음

## 10. Record integrity checks

- [x] R1 세 Run은 각각 `BIP-FR-004-RC-R1` 하나만 참조한다.
- [x] R1 Evidence는 run-scoped locator와 manifest로 보존하며, credential-bearing 원본 하나만 secure local locator에 byte-preserving 보관하고 Git에는 provenance가 연결된 redacted derivative를 사용한다.
- [x] Verification 순서를 적용하고 허용된 Outcome만 사용했다.
- [x] 유효하지 않거나 Evidence가 부족한 Run을 `NOT_REPRODUCED`로 잘못 분류하지 않았다.
- [x] R2는 predecessor, effective point, reason과 unchanged approval boundary를 식별한다.
- [x] 최초 R2 Run은 `BIP-FR-004-RC-R2` 하나만 참조하고 invalid execution과 `INCONCLUSIVE` closure를 보존한다.
- [x] 최초 R2 Run의 5건 traffic Evidence를 삭제하거나 성공한 pre-fault interval로 재해석하지 않았다.
- [x] 두 번째 R2 Run은 정상 traffic 750건을 보존하되 fault 미주입 실행을 `INCONCLUSIVE`로 닫고 재사용하지 않는다.
- [x] 세 번째 R2 Run은 stale baseline으로 controller가 fault 전환을 거부한 invalid execution을 `INCONCLUSIVE`로 닫고, pre-fault 정상 경로 관찰을 재현 Evidence로 승격하지 않는다.
- [x] `BIP-FR-004-MR-20260908T055225Z`는 controller 전 단계 PASS, verified partial claim과 record-level Evidence gap을 함께 보존하며 `PARTIALLY_REPRODUCED`로 판정했다.
- [x] 현재 Run은 `BIP-FR-004-RC-R2` 하나만 참조하고 Contract hash가 controller state와 일치한다.
- [x] 현재 Run의 raw Evidence 80개는 수정 없이 manifest 검증을 통과하며 credential assignment 노출이 없다.
- [x] 비판정 traffic invocation 검증은 Material Run Evidence/Claim과 분리했다.
- [x] 현재 synchronization에서는 새 Material Run을 등록하거나 RC-R3를 생성하지 않았다.
- [x] R1 recovery follow-up을 R2 Material Run Outcome으로 재분류하지 않았다.
