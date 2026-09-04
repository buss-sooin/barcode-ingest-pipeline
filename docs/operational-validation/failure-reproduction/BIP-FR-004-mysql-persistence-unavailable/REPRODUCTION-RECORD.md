# BIP-FR-004 재현 실행 기록

## 1. 문서 상태

- Record ID: `BIP-FR-004-RR`
- Contract ID: `BIP-FR-004-RC`
- Applicable Contract Revision: `BIP-FR-004-RC-R1`
- Contract freeze commit: `18e059a0ab57a5052e3096dd6558285a18c797db`
- Record Status: `PREPARED / NOT EXECUTED`
- Human Gate: `PENDING`
- Material Run Authorization: `NONE`
- Material Runs: 없음

이 문서는 판정 대상 실행(Material Run) 전에 Run 수명주기와 추적 형식을 고정한다. 아직 Run ID, 실행 시각, Outcome 또는 Evidence locator를 기록하지 않는다.

## 2. Run → Contract Revision 규칙

최초 Material Run을 시작하기 전에 아래 한 줄을 실제 Run ID로 확정한다.

```text
BIP-FR-004-MR-<UTC> → BIP-FR-004-RC-R1
```

각 Material Run은 정확히 하나의 Contract Revision만 직접 참조한다. 절차를 중대하게 재설계해야 하면 R1 기록을 수정해 소급 적용하지 않고 새 Revision과 새 Run mapping을 만든다.

## 3. Material Run 등록부

| Material Run | Contract Revision | Human Gate Reference | Outcome | Evidence | Manifest |
|---|---|---|---|---|---|
| 아직 없음 | — | `PENDING` | 실행 전 — 판정하지 않음 | — | — |

## 4. Run 등록 절차

Human Gate가 PASS한 뒤 state-changing action 전에 다음을 수행한다.

1. UTC 기반 `BIP-FR-004-MR-<UTC>`를 한 번 생성한다.
2. 이 등록부에 Run과 `BIP-FR-004-RC-R1`의 일대일 mapping을 기록한다.
3. 검증 가능한 Human Gate reference를 기록한다. 존재하지 않는 approval ID나 시각은 만들지 않는다.
4. 동일 Run ID의 Evidence 디렉터리가 아직 없음을 확인한 뒤 새 디렉터리를 만든다.
5. 실행 branch, exact HEAD, clean working tree와 Contract hash를 E0에 보존한다.

## 5. Execution Record 필수 필드

각 Run 항목에는 최소 다음을 남긴다.

- Run ID와 적용 Contract Revision 하나
- Human Gate reference와 실행 authority
- 시작·traffic·MySQL stop/start·readiness·종료 UTC
- proposed envelope 대비 actual rate/count/duration
- TP-1~TP-4 판정과 연결 Evidence locator
- FS-01~FS-06 판정과 연결 Evidence locator
- resource, topology, unexpected restart/OOM 또는 다른 deviation
- recovery와 reconciliation cardinality
- `Directly Proven`, `Strongly Inferred`, `Unresolved`
- `REPRODUCED`, `PARTIALLY_REPRODUCED`, `NOT_REPRODUCED`, `INCONCLUSIVE` 중 하나의 Outcome
- Run-scoped Evidence directory와 검증된 `MANIFEST.sha256`

## 6. 판정 순서

```text
실험 유효성(Experiment Validity)
→ 증거 충분성(Evidence Sufficiency)
→ 실패 징후(Failure Signature)
→ Outcome
```

HTTP 오류나 DLQ 발생만으로 Outcome을 정하지 않는다. 필수 실패 징후는 run-scoped Redis record의 Worker read, DB 접근 실패, MySQL 부재, 조기 XACK 부재와 PEL ownership retention을 연결해야 한다. `Retry → DLQ → XACK`은 실제 `saveWithRetry()` 진입이 확인된 record에만 조건부로 평가한다.

## 7. Evidence navigation

실행 전 정본:

- [R1 Reproduction Contract](./REPRODUCTION-CONTRACT.md)
- [Execution and Evidence Preparation](./EXECUTION-PREPARATION.md)
- [Human-Executable Operational Path](./HUMAN-EXECUTABLE-OPERATIONAL-PATH.md)
- [Human Gate Package](./HUMAN-GATE-PACKAGE.md)

실행 후 각 Run의 repository-relative locator는 다음 형식을 따른다.

```text
./evidence/BIP-FR-004-MR-<UTC>/
./evidence/BIP-FR-004-MR-<UTC>/MANIFEST.sha256
```

Raw Evidence는 사후 정규화하거나 덮어쓰지 않는다.
