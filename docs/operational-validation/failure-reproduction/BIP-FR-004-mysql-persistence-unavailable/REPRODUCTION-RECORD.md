# BIP-FR-004 재현 실행 기록

## 1. Record 상태와 책임

- Record ID: `BIP-FR-004-RR`
- Contract ID: `BIP-FR-004-RC`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`)
- R1 lifecycle: `HISTORICAL / CLOSED`
- R2 lifecycle: `FROZEN / ACTIVE REVISION`
- Existing Human Gate: `PASS` — `00I — 2026-09-04 Human approval`
- Current Material Run Authorization: `RESTORED FOR 71E BOUNDED EXECUTION` — 현재 Control Plane routing
- Material Runs: R1 3개, R2 2개

이 문서는 판정 대상 실행(Material Run)과 계약 개정(Contract Revision)의 일대일 mapping, 실행 편차, 검증 순서, Evidence locator와 제한을 보존한다. R1의 불완전한 실행을 R2 Evidence로 재분류하지 않으며, 중단된 R2 Run을 다른 실행에 재사용하지 않는다.

## 2. Contract Revision lineage

| Contract Revision | Previous Revision | Effective Point | 책임과 상태 |
|---|---|---|---|
| `BIP-FR-004-RC-R1` | 없음 — Initial Revision | R1 freeze commit `18e059a0ab57a5052e3096dd6558285a18c797db` | 최초 계약. 세 Material Run에만 적용되며 현재 `HISTORICAL / NOT REUSABLE` |
| `BIP-FR-004-RC-R2` | `BIP-FR-004-RC-R1` | [R2 Contract](./REPRODUCTION-CONTRACT-R2.md)를 최초로 포함하는 canonicalization commit | 수정된 application-owned reclaim, versioned runtime identity와 phase controller를 다음 Run 전에 고정. 현재 `FROZEN / PRE-RUN` |

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

## 7. 다음 R2 Run mapping 준비

다음 형식은 후속 Material Run의 새 identity를 위한 placeholder이며, 위 historical Run을 다시 여는 수단이 아니다.

```text
BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R2
```

Control Plane이 후속 Run 실행을 승인한 뒤에만 다음을 수행한다.

1. UTC 기반 Run ID를 한 번 생성한다.
2. 이 등록부에 Run과 `BIP-FR-004-RC-R2`의 일대일 mapping을 먼저 기록한다.
3. existing Human Gate와 authorization reference를 기록한다.
4. approved HEAD, clean tree, R2 Contract hash와 release identity를 E0에 보존한다.
5. R2 phase controller에 같은 Run ID/Revision/Contract를 register한다.

R2 등록에는 [R2 Contract](./REPRODUCTION-CONTRACT-R2.md)를 사용한다. R1 Contract 또는 R1 Evidence directory를 재사용하지 않는다.

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
- R2 Material Runs: `BIP-FR-004-MR-20260908T021905Z`, `BIP-FR-004-MR-20260908T045054Z` 2개, 모두 `INCONCLUSIVE`, 재사용 금지
- R2 readiness responsibility: 71E의 bounded authorization에 따라 concurrent child traffic과 fault control을 하나의 장기 parent execution에서 먼저 비판정 검증하고, clean baseline과 clean tree가 확인된 경우에만 새 Run ID를 등록한다.
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
- [x] 비판정 traffic invocation 검증은 Material Run Evidence/Claim과 분리했다.
- [x] 후속 R2 Run mapping 구조는 준비됐지만 새 Run은 등록하지 않았다.
- [x] R1 recovery follow-up을 R2 Material Run Outcome으로 재분류하지 않았다.
