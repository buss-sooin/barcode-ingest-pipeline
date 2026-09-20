# BIP-FR-004 AI 활용 설명

> 상태: `HUMAN REVIEW COMPLETE`
> 이 문서는 BIP-FR-004에서 AI와 자동화가 실제로 맡은 검증 작업, 인간이 바로잡은 판단 기준과 그 한계를 설명한다.

## 핵심

BIP-FR-004에서 AI가 해야 할 핵심 작업은 PEL 수와 MySQL row 수를 비교하는 일이 아니었다.

```text
실험에 투입해 수락된 논리 데이터 집합을 정한다
→ 각 ID가 장애 중 어느 상태에 있었는지 찾는다
→ 복구 후 동일 ID가 어느 최종 상태에 귀속됐는지 대사한다
→ 설명되지 않는 ID와 중복 귀속 ID를 찾는다
```

사람이 제시한 중요한 교정은 “왜 장애가 발생했는가?”라는 시스템 가설보다 먼저 다음 질문에 답해야 한다는 점이었다.

> 이미 진행한 작업은 어디까지 전달·저장됐고, 어느 ID부터 다시 처리해야 하는가?

이 질문은 물류 현장의 상세 업무 규칙을 새로 도입한 것이 아니다. 비동기 처리 장애를 해결할 때 필요한 가장 기본적인 상태 확인이다.

## FR-001~004에 공통으로 적용할 검증 단위

네 시나리오의 최종 수치는 ID 집합 대사의 요약이어야 한다. 수량 그 자체가 결론이 되어서는 안 된다.

| 시나리오 | 실험 입력의 논리 식별자 | 최종 귀속 확인 |
|---|---|---|
| FR-001 | 실행별 `scanTime` manifest 820개 | 같은 820개가 MySQL에 존재하고 missing·extra 0 |
| FR-002 | 생성 manifest의 `scanTime` 66개 | MySQL의 같은 66개 identity와 일치; Kafka 중복 9개는 business duplicate를 만들지 않음 |
| FR-003 | 생성 manifest의 `scanTime` 54개 | MySQL 53개와 명시적 expected rejection 1개로 ID별 귀속 |
| FR-004 | accepted `scanTime` 750개와 Redis payload의 `internalBarcodeId` 750개 | MySQL의 같은 750개 ID와 일치; outage PEL 252개에 연결된 business ID도 모두 최종 MySQL에 존재 |

따라서 FR-001~004의 공통 기조는 다음이어야 한다.

```text
장애 원인과 최초 단절 경계를 찾는다
+
이미 처리한 각 논리 ID의 현재 위치를 확인한다
+
복구 후 각 ID의 최종 귀속과 안전한 재개 지점을 확정한다
```

## BIP-FR-004에서 사용한 세 종류의 ID

| ID | 생성 위치 | 검증 책임 |
|---|---|---|
| `scanTime + deviceId` | scanner 입력 | scanner 수락분을 Redis·MySQL까지 연결하는 run-scoped identity |
| `internalBarcodeId` | Processing Service | Redis에 발행된 비즈니스 레코드와 MySQL 저장 행의 동일성 확인 |
| Redis Record ID | Redis `XADD` | PEL ownership, `XCLAIM`, `XACK` 같은 전달 제어 추적 |

Redis Record ID와 `internalBarcodeId`는 대체 관계가 아니다.

- `internalBarcodeId`는 어떤 비즈니스 레코드가 저장됐는지 답한다.
- Redis Record ID는 그 Stream entry의 ownership과 ACK가 어떻게 바뀌었는지 답한다.

이번 실험의 운영적 핵심인 “이미 진행한 데이터가 모두 저장됐는가?”는 `internalBarcodeId` 집합으로 판단할 수 있다. 모든 `XCLAIM`·`XACK` 내부 전이를 개별 Redis Record ID로 기록하는 것은 더 상세한 메커니즘 추적 책임이다.

## AI와 자동화가 실제로 수행하기 적합했던 일

### 실행 전

- 승인된 Contract, branch, HEAD와 runtime image 일치 확인
- MySQL 이외의 기존 장애와 PEL·DLQ·DLT 오염 확인
- 실행 cohort의 `scanTime` 범위 고정
- MySQL container와 volume identity 기록

### 실행 중

- active traffic과 MySQL stop 구간의 실제 중첩 확인
- MySQL availability, Worker DB 오류와 PEL 형성의 시간 순서 기록
- PEL의 Redis Record ID와 payload 보존
- 조건이 맞지 않으면 다음 단계로 진행하지 않는 fail-closed 집행

### 실행 후

- accepted `scanTime` 집합과 Redis·MySQL `scanTime` 집합 비교
- Redis payload와 MySQL의 `internalBarcodeId` 집합 비교
- outage PEL Record ID를 Redis payload의 `internalBarcodeId`로 변환해 최종 DB 포함 여부 확인
- DLQ, DLT, pending, unaccounted와 multi-state conflict 검사
- Evidence manifest 검증

이 작업은 반복 계산과 누락 탐지가 중심이므로 AI·자동화에 적합하다.

## 인간이 바로잡아야 했던 판단

초기 문서 초안은 다음 두 주장을 충분히 분리하지 못했다.

1. 비즈니스 데이터가 복구됐는가
2. Redis 내부 ownership·ACK 전이를 동일 Record ID로 모두 직접 추적했는가

두 번째 Evidence가 없다는 이유로 첫 번째 결과까지 “부분적으로만 의미 있다”고 읽히게 만든 것은 부정확했다.

실제 Evidence를 ID 집합으로 다시 계산한 결과는 다음과 같다.

| 대사 | 결과 |
|---|---:|
| accepted `scanTime` | 750개, 모두 고유 |
| Redis `scanTime` | 750개, accepted 집합과 차이 0 |
| MySQL `scanTime` | 750개, accepted 집합과 차이 0 |
| Redis `internalBarcodeId` | 750개, 모두 고유 |
| MySQL `internalBarcodeId` | 750개, Redis 집합과 양방향 차이 0 |
| outage PEL Record ID | 252개, 모두 고유 |
| 위 252개에 대응하는 최종 MySQL 누락 ID | 0개 |
| 최종 PEL / DLQ / DLT / unaccounted / conflict | 모두 0 |

이 결과는 bounded run의 비즈니스 데이터 복구와 안전한 최종 수렴을 직접 지지한다.

## 재실험이 필요하지 않은 이유

현재 질문은 “개별 `XCLAIM`과 `XACK` 호출을 다시 입증하라”가 아니라 “진행한 데이터가 어디까지 저장됐고 어디서 다시 시작할 수 있는가”다. 기존 Evidence에는 이 질문에 답하는 실제 ID 집합이 이미 보존돼 있다.

동일 Redis Record ID의 모든 내부 전이를 반드시 직접 기록하려면 단순 재실행으로는 부족하다. Worker에 다음 구조화 로그 또는 trace를 먼저 추가한 뒤 새 Contract로 실행해야 한다.

```text
runId
redisRecordId
internalBarcodeId
consumer
action = READ | CLAIM | PERSIST | ACK | DLQ
timestamp
```

이 개선은 전달 메커니즘을 더 자세히 검증하려는 별도 목적에는 유효하지만, 현재 확보된 비즈니스 데이터 복구 결론을 만들기 위한 필수 조건은 아니다.

## Canonical Outcome 표기의 해석

Repository의 현재 Workflow Outcome은 `PARTIALLY_REPRODUCED`다. RC-R2가 동일 Redis Record ID의 `DB failure → PEL → XCLAIM → persistence → XACK` 직접 연결까지 Evidence Sufficiency에 포함했기 때문이다.

네 설명 문서는 이 정본 표기를 임의로 바꾸지 않는다. 대신 다음 두 결과를 함께 명시한다.

- **비즈니스 데이터 상태와 복구:** 750개 ID 전부 최종 MySQL로 귀속됐으며 missing·extra·pending·conflict가 없다.
- **전달 메커니즘 추적:** 각 Redis Record ID의 전체 ownership·ACK 전이는 하나의 trace로 남지 않았다.

`PARTIALLY_REPRODUCED`를 “데이터도 일부만 복구됐다”는 뜻으로 사용하지 않는다.

## 관련 자료

- [R2 Reproduction Contract](./REPRODUCTION-CONTRACT-R2.md)
- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [Redis cohort](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/redis-cohort.json)
- [MySQL final cohort](./evidence/BIP-FR-004-MR-20260908T055225Z/06-mysql/final-cohort.tsv)
- [Outage PEL](./evidence/BIP-FR-004-MR-20260908T055225Z/05-redis/outage-pending.txt)
