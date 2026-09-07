# BIP-FR-004 재현 실행 기록

## 1. Record 상태와 책임

- Record ID: `BIP-FR-004-RR`
- Contract ID: `BIP-FR-004-RC`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`)
- R1 lifecycle: `HISTORICAL / CLOSED`
- R2 lifecycle: `FROZEN / PRE-RUN`
- Existing Human Gate: `PASS` — `00I — 2026-09-04 Human approval`
- Current Material Run Authorization: `SUSPENDED`
- Material Runs: R1 3개, R2 0개

이 문서는 판정 대상 실행(Material Run)과 계약 개정(Contract Revision)의 일대일 mapping, 실행 편차, 검증 순서, Evidence locator와 제한을 보존한다. R1의 불완전한 실행을 R2 Evidence로 재분류하지 않으며, R2 placeholder는 새 Run 등록이 아니다.

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

## 6. R2 Run mapping 준비

다음은 형식만 고정한 placeholder이며 Material Run 등록이 아니다.

```text
BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R2
```

`00J`가 `NEW MATERIAL RUN AUTHORIZATION = RESTORED`를 명시한 뒤에만 다음을 수행한다.

1. UTC 기반 Run ID를 한 번 생성한다.
2. 이 등록부에 Run과 `BIP-FR-004-RC-R2`의 일대일 mapping을 먼저 기록한다.
3. existing Human Gate와 authorization reference를 기록한다.
4. approved HEAD, clean tree, R2 Contract hash와 release identity를 E0에 보존한다.
5. R2 phase controller에 같은 Run ID/Revision/Contract를 register한다.

R2 등록에는 [R2 Contract](./REPRODUCTION-CONTRACT-R2.md)를 사용한다. R1 Contract 또는 R1 Evidence directory를 재사용하지 않는다.

## 7. R2 verification과 Evidence navigation

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

## 8. 인계(Handoff)

- R1 Run references: 3절의 세 Material Run
- R1 Outcome: 모두 `INCONCLUSIVE`
- R1 Verified Claim: 세 번째 Run에서 active traffic과 겹친 MySQL stop, mapping lookup DB failure와 PEL 형성까지만 직접 관측
- Claim limitations: 유효한 post-recovery traffic, identity-level ACK correlation, natural reclaim와 final reconciliation이 단일 R1 Run Evidence로 완결되지 않음
- R2 Contract: `BIP-FR-004-RC-R2`
- R2 Material Runs: 없음
- R2 readiness responsibility: clean canonical repository에서 controller register prerequisite를 확인하고 `00J`가 authorization 복원 여부를 판정
- Unresolved historical field: R2의 exact approval timestamp와 독립 approval ID는 repository Evidence에 없음

## 9. Record integrity checks

- [x] R1 세 Run은 각각 `BIP-FR-004-RC-R1` 하나만 참조한다.
- [x] R1 Evidence는 run-scoped locator와 manifest로 보존하며, credential-bearing 원본 하나만 secure local locator에 byte-preserving 보관하고 Git에는 provenance가 연결된 redacted derivative를 사용한다.
- [x] Verification 순서를 적용하고 허용된 Outcome만 사용했다.
- [x] 유효하지 않거나 Evidence가 부족한 Run을 `NOT_REPRODUCED`로 잘못 분류하지 않았다.
- [x] R2는 predecessor, effective point, reason과 unchanged approval boundary를 식별한다.
- [x] Future R2 Run mapping 구조는 준비됐지만 Run 자체를 등록하지 않았다.
- [x] R1 recovery follow-up을 R2 Material Run Outcome으로 재분류하지 않았다.
