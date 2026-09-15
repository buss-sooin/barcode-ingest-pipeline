# BIP-FR-005 재현 실행 기록

## 1. Record 상태와 책임

| 항목 | 값 |
|---|---|
| Record ID | `BIP-FR-005-RR` |
| Contract Revision | `BIP-FR-005-RC-R1` |
| Contract Status | `FROZEN` |
| Historical Material Runs | `BIP-FR-005-MR-20260909T124024Z`, `BIP-FR-005-MR-20260911T112314Z` |
| Historical Outcomes | `INCONCLUSIVE`, `INCONCLUSIVE` |
| Current executable Run | 없음 |
| Next Material Run | 새 등록 필요 |
| Successor baseline enforcement | `SUCCESSOR-BASELINE-PREPARATION-V1` |
| Verified Reproduction Claim | 없음 |

이 문서는 동결된 재현 계약(Reproduction Contract)의 의미를 변경하지 않고, 등록된 두 판정 대상 실행(Material Run)의 이력과 Failure Reproduction Workflow v0.1 검증 결과를 동기화한다. 실행 처분(Execution Disposition)은 Run의 재사용 가능 여부를, Outcome은 계약에 따른 장애 재현 판정을 나타내므로 서로 대체하지 않는다.

```text
Execution Disposition != Failure Reproduction Outcome
```

## 2. Material Run 등록부

| Material Run | 역할 | 실행 상태 | 실험 유효성 | Evidence Sufficiency | Outcome | 재사용 |
|---|---|---|---|---|---|---|
| `BIP-FR-005-MR-20260909T124024Z` | Historical Run | `ABORTED / SUPERSEDED` | `FAIL` | `SUFFICIENT FOR INVALID EXECUTION / INSUFFICIENT FOR FAILURE SIGNATURE` | `INCONCLUSIVE` | `NOT_REUSABLE` |
| `BIP-FR-005-MR-20260911T112314Z` | Historical Run #2 | `ABORTED` | `FAIL` | `SUFFICIENT FOR INVALIDATION / INSUFFICIENT FOR COMPLETE FAILURE-SIGNATURE EVALUATION` | `INCONCLUSIVE` | `NOT_REUSABLE` |

두 Run은 각각 정확히 `BIP-FR-005-RC-R1`을 참조한다. 두 실행 모두 유효성 실패로 종료됐으며 현재 실행 가능한 Run은 없다. 다음 실행은 새 Material Run 등록이 필요하다.

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

## 4. Historical Run #2 — `BIP-FR-005-MR-20260911T112314Z`

### 4.1 실행 이력과 제어 편차

- Repository identity, frozen image, `NORMAL_COHORT_DATA_CONTRACT`와 runtime entry preflight는 formal start 전에 모두 `PASS`했다.
- `2026-09-14T09:01:58Z`에 formal Run을 시작했고 `C0`는 `barcode-events/1/3610`에서 Redis Streams와 MySQL까지 정상 처리됐다.
- `bip-fr-002-broker-3`는 `09:03:21.830371884Z`에 `exit_code=137`, `oom_killed=true`로 종료됐다.
- `09:03:22Z` pre-fault collection은 이미 이 상태를 관측했지만, collection과 Redis fault action이 하나의 fail-closed 전이로 묶이지 않아 실패 Predicate를 assertion으로 차단하지 못했다.
- Redis fault는 `09:03:24Z`에 주입됐고 `C1`, `C2`는 `09:03:42Z`에 발행됐다. 이는 Redis 단독 장애라는 계약 유효성 전제가 이미 깨진 뒤의 실행 제어 편차다.
- Run은 `09:07:15Z`에 `UNEXPECTED_KAFKA_BROKER_OOM`으로 중단됐다. Redis는 중단 정리 목적으로만 복구했고 DLT disposition, replay, quarantine 처리와 `C3` 전송은 수행하지 않았다.
- 실행 처분: `ABORTED / NOT_REUSABLE`. 후속 Run이 아직 등록되지 않았으므로 `SUPERSEDED`로 표기하지 않는다.

주요 Evidence:

- [Material Run manifest](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/MANIFEST.sha256)
- [Execution abort](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/execution-abort.txt)
- [Execution-control deviation](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/execution-control-deviation.txt)
- [Pre-fault gate observation](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/pre-fault-gate.txt)
- [Timeline](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/timeline.txt)
- [Cohort accounting](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/cohort-accounting.txt)
- [Failure-signature observations](./evidence/BIP-FR-005-MR-20260911T112314Z/02-material-run/preliminary-signature-evaluation.txt)

### 4.2 실험 유효성(Experiment Validity)

`FAIL`

Redis fault 전에 Kafka broker OOM과 9개 시나리오 topic partition의 under-replication이 발생했다. 다른 failure domain이 동시에 활성화됐고 pre-fault infrastructure Predicate 실패 뒤에도 fault transition이 진행됐으므로 이 실행은 R1의 Redis-only failure lifecycle을 판정하는 유효한 Material Run이 아니다.

### 4.3 증거 충분성(Evidence Sufficiency)

`SUFFICIENT FOR INVALIDATION / INSUFFICIENT FOR COMPLETE FAILURE-SIGNATURE EVALUATION`

Evidence는 entry PASS, C0 정상 처리, broker OOM 시각, pre-fault 관측, 이후의 잘못된 fault transition, C1/C2 source와 DLT identity, 중단 및 Redis 정리 복구를 재구성하기에 충분하다. 반면 중단 뒤 DLT disposition, replay, quarantine과 C3를 수행하지 않았으므로 전체 Failure Signature와 최종 lifecycle을 평가하기에는 불충분하다.

### 4.4 실패 징후 평가(Failure Signature Evaluation)

| Failure Signature | invalid Run 관측 상태 |
|---|---|
| `FS-01` | `OBSERVED` |
| `FS-02` | `OBSERVED` |
| `FS-03` | `NOT_OBSERVED` |
| `FS-04` ~ `FS-09` | `NOT_EVALUABLE` |

`FS-01`, `FS-02`는 무효 실행에서 직접 관측된 사실일 뿐 Verified Reproduction Claim이 아니다. `C1`은 Redis command timeout 뒤 DLT에 도달했지만 failure category가 `TRANSIENT_REDIS`가 아닌 `UNKNOWN`이어서 `FS-03`은 `NOT_OBSERVED`다. 중단 뒤 단계가 필요한 `FS-04`부터 `FS-09`까지는 판정할 수 없다.

### 4.5 Outcome

`INCONCLUSIVE`

실행 무효화는 확정할 수 있지만 복합 장애와 중단된 lifecycle로 인해 R1 시나리오의 최종 재현 여부를 판단할 수 없다. 따라서 이 Run을 `NOT_REPRODUCED`나 Verified Reproduction Claim으로 승격하지 않는다.

### 4.6 Corrective Fast Path와 다음 Run 경계

확인된 실행 제어 회귀는 기존 pre-fault Predicate와 Engineering Intent를 바꾸지 않고 최소 교정한다. `pre-fault-gate.sh`는 required broker의 running/health/OOM/exit/restart 상태와 세 scenario topic의 RF=3, full ISR, URP=0, unavailable=0을 검증한다. `material-run-controller.sh`는 이 gate가 `PASS`일 때만 Redis fault action을 호출하고, 실패하면 `ABORTED / redis_fault_action=NOT_EXECUTED`로 전이를 거부한다.

Invalid Run에서 Redis `QueryTimeoutException`이 `UNKNOWN`으로 분류된 것은 “Redis 연결 실패는 `TRANSIENT_REDIS`”라는 R1의 기존 의미와 일치하지 않는 classifier 누락이다. 새 정책을 추가하지 않고 같은 cause chain의 `QueryTimeoutException`을 `TRANSIENT_REDIS`로 분류하며 deterministic test로 고정한다.

```text
CONTRACT_REVISION_REQUIRED=NO
NEW_RUN_REQUIRED=YES
Current executable Run=NONE
```

현재 Run은 formal start, C0/C1/C2, Redis fault와 DLT 상태를 생성했으므로 다시 사용할 수 없다. successor Run의 registration, release identity와 runtime preparation은 이 교정의 repository synchronization 이후 별도 책임에서 수행한다.

### 4.7 Successor baseline 격리 교정

Historical DLT/quarantine 전체 건수를 `0`으로 요구하면 보존해야 하는 이전 Run Evidence와 successor Run의 진입 가능성이 충돌한다. Successor entry는 전역 삭제나 offset reset 대신 다음 독립 Predicate로 판정한다.

1. `barcode-events-dlt`와 `barcode-events-quarantine`의 partition별 log start/end watermark를 등록 시점에 고정한다.
2. watermark 구간의 모든 record를 topic/partition/offset/root identity 단위로 inventory화한다.
3. 기존 record가 `known-historical-residue-v1.tsv`와 정확히 일치하고 immutable Run Evidence의 해시로 소유권을 증명하는지 검증한다.
4. 새 Run의 모든 root identity가 MySQL, Redis Stream, Worker DLQ와 dedupe state에 없음을 개별 확인한다.
5. runtime 재검증 시 partition watermark와 inventory가 등록 baseline에서 변하지 않았는지 확인한다.

알 수 없는 record, owner, 누락된 offset, watermark drift 또는 successor identity collision은 fail closed로 entry를 차단한다. Source consumer lag, Redis consumer-group lag와 Redis PEL은 계속 `0`이어야 한다. 전역 DLT/quarantine end-offset 합계는 운영 진단값일 뿐 successor의 부재나 Failure Reproduction Claim을 판정하지 않는다.

이 교정은 `SUCCESSOR-BASELINE-PREPARATION-V1.txt`, `successor-baseline-capture-v1.sh`, `successor-baseline-reconciliation-v1.sh`와 `successor-preflight-v3.sh`로 버전 고정한다. 기존 Run 전용 `EXECUTION-PREPARATION.txt`, `preflight.sh`, `preflight-v2.sh`, Run Evidence와 manifest는 변경하지 않는다. 이 변경은 R1의 root-identity reconciliation을 실행 전 baseline에도 적용한 것이며 DLT 삭제, topic truncate 또는 offset correction을 허용하지 않는다.

현재 알려진 inventory는 Historical Run #2의 `barcode-events-dlt/0/0` C1과 `/0/1` C2 두 record만 허용한다. Kafka retention이나 log-start 변화, 새 residue, JSON `.barcode`로 식별할 수 없는 payload 또는 topic당 10,000건을 넘는 baseline은 자동 승인하지 않고 새 Evidence와 versioned inventory reconciliation을 요구한다.

## 5. Contract와 manifest 무결성

- `REPRODUCTION-CONTRACT.md`의 SHA-256은 `1ed738712229c27320b59dd0ac13748baedfadbd350cdbdb0078692883880865`이며 두 Run manifest에 기록된 값과 일치한다.
- `BIP-FR-005-RC-R1`은 `FROZEN` 상태를 유지한다. 이 Record는 계약의 Failure Signature, Verification Criteria, Scope, 승인 실행 경계 또는 의미를 변경하지 않는다.
- 계약에 남아 있는 pre-execution `Material Run = NOT EXECUTED`와 placeholder 설명은 freeze 시점의 상태다. 실행 이력의 현재 정본은 이 Record이며, frozen 계약을 runtime status log로 사용하지 않는다.
- 두 번째 Run의 등록 시점 `MANIFEST.sha256`은 그대로 보존한다. Material Run의 44개 파일은 self-excluding 43-entry `02-material-run/MANIFEST.sha256`으로 별도 검증하며 등재 항목 전체가 일치한다.
- Identity reconciliation은 두 번째 Run의 등록 시점 `MANIFEST.sha256`을 수정하거나 포괄 범위를 소급 확장하지 않는다. 당시 v2 preflight와 reconciliation Evidence는 별도 `RECONCILIATION-MANIFEST.sha256`으로 고정했다. 그 manifest가 포함한 공유 `REPRODUCTION-RECORD.md` 항목은 해당 reconciliation 시점의 canonical snapshot이며, 이번 successor baseline additive update 이후 현재 Record byte 검증값으로 사용하지 않는다. Historical manifest를 다시 쓰지 않았으므로 `preflight-v2.sh`와 Run-local reconciliation Evidence 항목은 계속 일치하지만 현재 Record 항목은 의도적으로 drift한다.
- 첫 Run의 최상위 `MANIFEST.sha256`은 Run-local environment Evidence와 계약 등은 일치하지만, 현재의 공유 준비 artifact 4개(`docker-compose.release.yml`, `preflight.sh`, `capture-state.sh`, `EXECUTION-PREPARATION.txt`)와는 일치하지 않는다. 이는 첫 Run manifest의 과거 snapshot과 현재 공유 파일 사이의 byte drift이며, 해당 manifest를 현재 전체 디렉터리 검증값으로 사용해서는 안 된다.
- 첫 Run Attempt 2의 `ATTEMPT-2-MANIFEST.sha256`은 등재된 17개 Run-local Evidence 전부와 일치한다. 따라서 3절의 판정은 무결성이 확인된 Attempt 2 Evidence에 근거한다.

## 6. Repository 추적 상태

- FR-005 implementation, test, release-preparation, canonical documentation과 Evidence corpus는 전용 branch `validation/bip-fr-005-redis-streams-unavailability`에서 추적한다.
- Canonical implementation commit은 `e540d4238480cddd08ceb4578a93e935ed731b8b`, canonicalization anchor는 `7eba27e22a36a5e50109351f7dbd518d3c78b71b`다.
- `REPRODUCTION-CONTRACT.md`와 이 `REPRODUCTION-RECORD.md`는 `.gitignore`를 변경하지 않고 path-specific explicit tracking으로 보존한다.
- 두 번째 Run의 등록·release identity·기존 manifest는 historical Evidence로 변경하지 않는다. classifier와 실행 제어 교정은 successor Run에서 새 implementation/release identity로 등록해야 한다.
- Successor baseline V1은 Historical Run #2의 DLT Evidence 파일 SHA-256 `33ea7d1c08ee16767fdec5a9b183e650232551d6d71b370a5f03286db0ca189c`를 ownership anchor로 사용한다. 기존 Evidence byte를 수정하지 않고 새 inventory에서 참조한다.

## 7. 다음 실행 관문

현재 실행 가능한 Run은 없다. Successor 등록의 선행조건은 안정적인 Kafka/Redis/MySQL/application topology에서 새 고유 Run ID와 cohort를 만들고, `successor-baseline-capture-v1.sh`가 생성한 partition watermarks·exact residue inventory·identity-state·lag/PEL snapshot을 Run-local `01-entry-baseline`에 고정하는 것이다. 등록은 `BIP-FR-005-RC-R1`, corrected application revision `83eaa799e2359a353e748e567a5fbfc0df0cf9c3`, clean preparation revision, baseline isolation version `1`과 `known-historical-residue-v1.tsv` 해시를 정확히 하나씩 연결해야 한다. 이후 새 frozen release identity를 같은 Run에 연결하고 `successor-preflight-v3.sh static|runtime`을 통과해야 한다. 이 Record는 successor Run을 등록하거나 실행 Surface를 선결정하지 않는다.
