# BIP-FR-003 Kafka insufficient ISR 쓰기 불가 재현 기록

## 1. Record Metadata

- Record ID: `BIP-FR-003-RR`
- Project / Task Scope: `BIP Operating Validation / BIP-FR-003`
- Owner: 이 repository와 local validation 실행에 대한 권한 있는 Human 사용자
- Created At: 2026-09-02
- Updated At: 2026-09-02
- Workflow Version: Failure Reproduction Workflow v0.1
- Record Status: 첫 실행 시도 `INCONCLUSIVE` 보존 / bounded 재실행 준비

## 2. 관찰된 실패와 정의된 시나리오

- 관찰된 실패(Observed Failure) 참조: Kafka leader는 존재하지만 ISR size가 topic `min.insync.replicas`보다 작은 상태에서 `acks=all` 새 쓰기가 성공 확인을 받지 못하는 조건
- 정의된 실패 시나리오(Defined Failure Scenario): `BIP-FR-003 — Kafka Insufficient ISR Write Unavailability During Active Scan`
- 관계: 이 실행은 승인된 로컬 토폴로지에서 위 조건을 의도적으로 만들고 application-visible failure와 설정 완화 없는 회복을 검증한다. production incident나 일반 보증을 재현한다고 주장하지 않는다.
- 사전 계약: [REPRODUCTION-CONTRACT.md](./REPRODUCTION-CONTRACT.md)

## 3. Contract와 Human Gate

- Contract ID: `BIP-FR-003-RC`
- 적용 Revision: [`BIP-FR-003-RC-R1`](./REPRODUCTION-CONTRACT.md#bip-fr-003-rc-r1)
- Revision effective point: R1 포함 준비 commit부터 최초 Material Run
- Previous Revision: 없음
- Revision reason: 최초 실행 전 승인 Intent, 실패 징후, 검증·Evidence·안전 경계 고정
- Human Gate: 승인됨
- Approval reference: `Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation`
- 승인 시각/별도 승인 ID: 독립적으로 확인할 수 없어 생성하지 않음

## 4. 판정 대상 실행(Material Run) 목록

각 Material Run은 정확히 하나의 Contract Revision만 참조한다.

### Run `BIP-FR-003-MR-20260902T112532Z`

- Run ID: `BIP-FR-003-MR-20260902T112532Z`
- Contract ID: `BIP-FR-003-RC`
- 계약 개정(Contract Revision): `BIP-FR-003-RC-R1`
- 실행 시각: `2026-09-02T11:36:53Z` 시작
- 실행 주체: 승인 경계 안의 Codex bounded execution
- 실제 환경과 조건: 기존 local/dev BIP validation topology, 준비 HEAD `4078118b4f4ad71daf7763e0582d09b4076e8bfb`
- 수행 action: 실행 정체성과 effective runtime config 캡처 시작. 장애 주입 전 중단
- Deviation 또는 anomaly: healthcheck가 없는 controller에서 `docker inspect` 템플릿이 `.State.Health`를 직접 조회해 template parsing error 발생
- 증거 자산(Evidence Assets) locator: [`./evidence/BIP-FR-003-MR-20260902T112532Z/`](./evidence/BIP-FR-003-MR-20260902T112532Z/)
- Evidence integrity: `MANIFEST.sha256` 생성·검증

직접 매핑:

```text
BIP-FR-003-MR-20260902T112532Z → BIP-FR-003-RC-R1
```

#### 실행 전 종료 판정

- 실험 유효성(Experiment Validity): 미확립. 사전 조건 캡처가 완료되기 전에 종료됨
- 증거 충분성(Evidence Sufficiency): 불충분
- 실패 징후 평가(Failure Signature Evaluation): 미수행
- Outcome: `INCONCLUSIVE`
- 장애 영향: SIGKILL 0회, broker/controller/application 변경 없음
- 후속 조치: 계약·승인 경계와 실험 절차는 유지하고, health key가 없는 container도 읽을 수 있도록 inspection 템플릿만 수정

### Run `BIP-FR-003-MR-20260902T113950Z`

- Run ID: `BIP-FR-003-MR-20260902T113950Z`
- Contract ID: `BIP-FR-003-RC`
- 계약 개정(Contract Revision): `BIP-FR-003-RC-R1`
- 실행 시각: 실행 Evidence에서 UTC로 기록 예정
- 실행 주체: 승인 경계 안의 Codex bounded execution
- 실제 환경과 조건: 기존 local/dev BIP validation topology, 실행 전 Evidence로 확정 예정
- 수행 action: R1의 runtime discovery, L0/F1 순차 SIGKILL, F1/L0 순차 복구, reconciliation
- Deviation 또는 anomaly: 실행 후 기록 예정
- 증거 자산(Evidence Assets) locator: [`./evidence/BIP-FR-003-MR-20260902T113950Z/`](./evidence/BIP-FR-003-MR-20260902T113950Z/)
- Evidence integrity: 실행 종료 후 `MANIFEST.sha256` 생성·검증 예정

직접 매핑:

```text
BIP-FR-003-MR-20260902T113950Z → BIP-FR-003-RC-R1
```

## 5. 사전 Verification 상태

### 1. 실험 유효성(Experiment Validity)

- 평가: 첫 실행 시도는 `INCONCLUSIVE`; 재실행은 미판정
- 사전 확인: 계약 R1, Human Gate 참조와 단일 Revision 매핑을 고정함

### 2. 증거 충분성(Evidence Sufficiency)

- 평가: 첫 실행 시도는 불충분; 재실행은 미판정
- 요구사항: Contract 10절의 runtime/config/timeline/identity Evidence를 수집해야 함

### 3. 실패 징후 평가(Failure Signature Evaluation)

- 평가: 첫 실행 시도는 미수행; 재실행은 미판정

### 4. Outcome

- Outcome: `BIP-FR-003-MR-20260902T112532Z = INCONCLUSIVE`; 재실행은 미배정
- 허용 값: `REPRODUCED | PARTIALLY_REPRODUCED | NOT_REPRODUCED | INCONCLUSIVE`

Outcome은 실험 유효성 → 증거 충분성 → 실패 징후 평가 뒤에만 배정한다.

## 6. 실행 전 무결성 확인

- [x] 관찰된 실패와 정의된 실패 시나리오를 구분했다.
- [x] Material Run 전에 Contract, 실패 징후와 Verification Criteria를 고정했다.
- [x] 할당한 Material Run이 정확히 하나의 Contract Revision을 참조한다.
- [x] Human Gate 승인 대상과 Risk/Blast Radius 경계를 기록했다.
- [x] 승인 시각이나 식별자를 추정해 생성하지 않았다.
- [x] 첫 실행 시도의 Evidence locator와 SHA-256 manifest를 보존·검증한다.
- [ ] 재실행 후 Evidence locator와 SHA-256 manifest를 검증한다.
- [ ] 실행 후 정해진 Verification 순서와 허용 Outcome을 적용한다.
- [ ] 실행 후 검증된 재현 주장과 제한을 Evidence 범위 안에서 기록한다.
