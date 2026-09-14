# BIP-FR-005 재현 실행 기록

## 1. Record 상태와 책임

| 항목 | 값 |
|---|---|
| Record ID | `BIP-FR-005-RR` |
| Contract Revision | `BIP-FR-005-RC-R1` |
| Contract Status | `FROZEN` |
| Historical Material Run | `BIP-FR-005-MR-20260909T124024Z` |
| Historical Outcome | `INCONCLUSIVE` |
| Current Material Run | `BIP-FR-005-MR-20260911T112314Z` |
| Current Run State | `REGISTERED / NOT_EXECUTED / NOT_ASSIGNED` |
| Verified Reproduction Claim | 없음 |

이 문서는 동결된 재현 계약(Reproduction Contract)의 의미를 변경하지 않고, 등록된 두 판정 대상 실행(Material Run)의 이력과 Failure Reproduction Workflow v0.1 검증 결과를 동기화한다. 실행 처분(Execution Disposition)은 Run의 재사용 가능 여부를, Outcome은 계약에 따른 장애 재현 판정을 나타내므로 서로 대체하지 않는다.

```text
Execution Disposition != Failure Reproduction Outcome
```

## 2. Material Run 등록부

| Material Run | 역할 | 실행 상태 | 실험 유효성 | Evidence Sufficiency | Outcome | 재사용 |
|---|---|---|---|---|---|---|
| `BIP-FR-005-MR-20260909T124024Z` | Historical Run | `ABORTED / SUPERSEDED` | `FAIL` | `SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE` | `INCONCLUSIVE` | `NOT_REUSABLE` |
| `BIP-FR-005-MR-20260911T112314Z` | Current execution candidate | `REGISTERED / NOT_EXECUTED` | 평가 전 | 실행 Evidence 없음 | `NOT_ASSIGNED` | 실행 후보 |

두 Run은 각각 정확히 `BIP-FR-005-RC-R1`을 참조한다. 후속 Run registration에 기록된 첫 Run의 `INCONCLUSIVE`는 참조값일 뿐 이 Record의 권위 근거가 아니다. 3절의 검증 순서로 독립 판정했다.

## 3. Historical Run — `BIP-FR-005-MR-20260909T124024Z`

### 3.1 실행 이력과 처분

- Attempt 1은 최종 runtime preflight에서 `bip-fr-002-broker-3_state_exited`를 발견해 formal Run start 전에 중단됐다. traffic, Redis 장애 주입, DLT disposition은 실행되지 않았다.
- Attempt 2는 final entry preflight를 통과하고 `2026-09-11T10:36:41Z`에 formal Run을 시작했다.
- `C0`는 `10:37:00Z`에 `barcode-events/1/3609`로 발행됐고 Processing의 Redis Streams handoff까지 성공했다.
- Persistence Worker는 준비된 `deviceId=bip-fr-005-c0-device`에 대응하는 `device_center_mapping`을 찾지 못했다. `C0`는 MySQL에 저장되지 않고 Worker DLQ로 이동했으며 원래 Redis Stream record는 DLQ 발행 뒤 `XACK`됐다.
- 정상 영속화 기준선이 실패했으므로 `C1`, `C2`, `C3`는 보내지 않았고 Redis 장애도 주입하지 않았다. Run은 `2026-09-11T10:39:05Z`에 중단됐다.
- 실행 처분: `ABORTED / SUPERSEDED / NOT_REUSABLE`.

주요 Evidence:

- [Attempt 1 execution state](./evidence/BIP-FR-005-MR-20260909T124024Z/02-material-run/execution-state.txt)
- [Attempt 2 timeline](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/timeline.txt)
- [C0 source request](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/c0-send.txt)
- [C0 service logs](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/c0-service-logs.txt)
- [C0 completion predicate](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/c0-completion.txt)
- [Cohort accounting](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/cohort-accounting.txt)
- [Prohibited actions](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/prohibited-actions.txt)

### 3.2 실험 유효성(Experiment Validity)

`FAIL`

계약이 요구한 Redis unavailable 상태와 active traffic의 중첩이 만들어지기 전에 정상 기준선이 실패했다. 직접 원인은 `C0`의 `device_center_mapping` 전제조건 위반이며, 관측된 Worker DLQ 전이는 Redis 장애의 효과가 아니다. 따라서 이 Run은 `BIP-FR-005-RC-R1`의 Redis failure lifecycle을 판정할 수 있는 유효한 실험이 아니다.

### 3.3 증거 충분성(Evidence Sufficiency)

`SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE`

Evidence는 formal start, `C0`의 source→Kafka→Redis→Worker DLQ 경로, MySQL 미영속화, 중단 원인과 Redis 장애 미주입을 root identity 수준으로 확정하기에 충분하다. 반면 Redis unavailable/recovery, source retry, Kafka DLT, classification, snapshot-bounded disposition, replay, quarantine 및 최종 responsibility reconciliation은 실행되지 않아 계약의 Failure Signature를 판정할 Evidence가 없다.

### 3.4 실패 징후 평가(Failure Signature Evaluation)

| Failure Signature | 평가 |
|---|---|
| `FS-01` ~ `FS-09` | `NOT_EVALUATED` |

`FS-01`부터 `FS-09`까지 어느 항목도 불충족으로 판정하지 않는다. 필요한 fault boundary에 진입하지 않았으므로 `NOT_EVALUATED`가 Evidence가 허용하는 최대 판단이다. [FS Evidence matrix](./evidence/BIP-FR-005-MR-20260909T124024Z/04-material-run-attempt-2/fs-evidence-matrix.txt)도 같은 경계를 보존한다.

### 3.5 Outcome

`INCONCLUSIVE`

Evidence는 실행이 무효라는 결론에는 충분하지만, Redis Streams unavailable 시나리오가 재현되는지 여부에는 답하지 못한다. 따라서 유효한 장애 실험에서 Failure Signature가 성립하지 않았음을 뜻하는 `NOT_REPRODUCED`로 분류하지 않는다. `INCONCLUSIVE`는 시스템 failure의 부재나 존재를 주장하지 않으며, 전제조건 실패로 Outcome 판단 능력을 잃은 Run이라는 뜻이다.

## 4. Current Run — `BIP-FR-005-MR-20260911T112314Z`

### 4.1 등록 상태

```text
REGISTERED
NOT_EXECUTED
Outcome = NOT_ASSIGNED
```

이 Run은 현재 등록된 실행 후보다. formal start, cohort traffic, Redis 장애 주입, DLT disposition은 모두 수행되지 않았고 새 frozen release도 배포되지 않았다. 성공, 실패, 재현, 미재현 또는 `INCONCLUSIVE` Outcome을 부여하지 않는다.

### 4.2 서로 독립적인 두 gate

```text
NORMAL_COHORT_DATA_CONTRACT=PASS
!=
RUNTIME_PREFLIGHT=PASS
```

- 결정적 데이터 계약 관문(Deterministic Data-contract Gate): `PASS`. `C0`, `C1`, `C3`의 `device_center_mapping`이 각각 1건임을 확인했고 `C2`는 빈 `deviceId`를 사용하는 permanent-validation cohort이므로 mapping 대상이 아니다. reference-data mutation은 `NO`다.
- Runtime entry: `BLOCKED`. 최초 blocker는 `bip-fr-002-broker-1`의 `state=exited`, `exit_code=137`, `oom_killed=true`다.
- Frozen release deployment: `NOT YET DEPLOYED`.

Evidence:

- [Run registration](./evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/run-registration.txt)
- [Normal cohort data contract](./evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/normal-cohort-data-contract.txt)
- [Preparation verification](./evidence/BIP-FR-005-MR-20260911T112314Z/00-environment/preparation-verification.txt)
- [Current manifest](./evidence/BIP-FR-005-MR-20260911T112314Z/MANIFEST.sha256)

### 4.3 Repository identity reconciliation

등록 당시 frozen image와 Evidence의 identity는 변경하지 않는다. 등록 base `57b59577ac856d664fd69f5a6c4867f1f583be8c`의 tracked diff와 untracked implementation/test set은 canonical implementation commit `e540d4238480cddd08ceb4578a93e935ed731b8b`의 내용과 정확히 일치하며, canonicalization anchor `7eba27e22a36a5e50109351f7dbd518d3c78b71b`는 application, test 또는 기존 release-preparation byte를 변경하지 않는다.

기존 `preflight.sh`와 Current Run manifest는 등록 시점 Evidence로 보존한다. 후속 entry requalification은 versioned `preflight-v2.sh`를 사용한다. v2는 historical registration base, canonical implementation commit, canonicalization anchor와 실행 시점의 clean preparation HEAD를 서로 다른 identity로 검증하고, 기존 frozen image ID 및 label은 그대로 확인한다. Repository-side static verification은 `PASS`지만 runtime preflight는 다시 실행하지 않았으므로 현재 gate는 계속 `BLOCKED`다.

Additive Evidence:

- [Identity reconciliation Evidence](./evidence/BIP-FR-005-MR-20260911T112314Z/01-identity-reconciliation/reconciliation-evidence.txt)
- [Identity reconciliation manifest](./evidence/BIP-FR-005-MR-20260911T112314Z/01-identity-reconciliation/RECONCILIATION-MANIFEST.sha256)

## 5. Contract와 manifest 무결성

- `REPRODUCTION-CONTRACT.md`의 SHA-256은 `1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865`이며 두 Run manifest에 기록된 값과 일치한다.
- `BIP-FR-005-RC-R1`은 `FROZEN` 상태를 유지한다. 이 Record는 계약의 Failure Signature, Verification Criteria, Scope, 승인 실행 경계 또는 의미를 변경하지 않는다.
- 계약에 남아 있는 pre-execution `Material Run = NOT EXECUTED`와 placeholder 설명은 freeze 시점의 상태다. 실행 이력의 현재 정본은 이 Record이며, frozen 계약을 runtime status log로 사용하지 않는다.
- 현재 Run의 `MANIFEST.sha256`은 등재 항목 전체가 현재 repository byte와 일치한다.
- Identity reconciliation은 기존 Current Run `MANIFEST.sha256`을 수정하거나 포괄 범위를 소급 확장하지 않는다. 추가된 v2 preflight와 reconciliation Evidence는 별도 `RECONCILIATION-MANIFEST.sha256`으로 검증한다.
- 첫 Run의 최상위 `MANIFEST.sha256`은 Run-local environment Evidence와 계약 등은 일치하지만, 현재의 공유 준비 artifact 4개(`docker-compose.release.yml`, `preflight.sh`, `capture-state.sh`, `EXECUTION-PREPARATION.txt`)와는 일치하지 않는다. 이는 첫 Run manifest의 과거 snapshot과 현재 공유 파일 사이의 byte drift이며, 해당 manifest를 현재 전체 디렉터리 검증값으로 사용해서는 안 된다.
- 첫 Run Attempt 2의 `ATTEMPT-2-MANIFEST.sha256`은 등재된 17개 Run-local Evidence 전부와 일치한다. 따라서 3절의 판정은 무결성이 확인된 Attempt 2 Evidence에 근거한다.

## 6. Repository 추적 상태

- FR-005 implementation, test, release-preparation, canonical documentation과 Evidence corpus는 전용 branch `validation/bip-fr-005-redis-streams-unavailability`에서 추적한다.
- Canonical implementation commit은 `e540d4238480cddd08ceb4578a93e935ed731b8b`, canonicalization anchor는 `7eba27e22a36a5e50109351f7dbd518d3c78b71b`다.
- `REPRODUCTION-CONTRACT.md`와 이 `REPRODUCTION-RECORD.md`는 `.gitignore`를 변경하지 않고 path-specific explicit tracking으로 보존한다.
- 최종 preparation HEAD를 특정 SHA로 상수화하지 않는다. `preflight-v2.sh`는 canonicalization anchor의 descendant인 clean checkout에서 canonical implementation 및 기존 release-preparation byte가 변하지 않았음을 검증하고 실제 HEAD를 Evidence 출력에 별도로 기록한다.

## 7. 다음 실행 관문

Repository-side identity reconciliation과 `preflight-v2.sh static`은 `PASS`다. 현재 Run을 시작하기 전에 v2로 runtime entry를 다시 검증해야 한다. `NORMAL_COHORT_DATA_CONTRACT=PASS`는 유지되지만 `RUNTIME_PREFLIGHT=BLOCKED`를 대체하지 않는다. Runtime 복구, frozen release 배포와 Material Run 시작은 별도 승인된 실행 책임에서 수행해야 하며, 이 Record는 이를 실행하거나 Outcome을 선배정하지 않는다.
