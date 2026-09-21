# BIP-FR-005 장애 시나리오 설명

> 문서 상태: `FINAL — HUMAN CONFIRMED`
>
> 검증 대상: `BIP-FR-005-RC-R1` / Verified Material Run `BIP-FR-005-MR-20260915T031000Z` / Outcome `REPRODUCED`

## 먼저 이해할 한 문장

Kafka에서 이벤트를 정상적으로 소비한 뒤 Redis Streams로 넘기는 구간이 실패했고, source retry를 소진한 C1의 처리 책임은 DLT로 이동했다. Redis 복구 뒤 C1만 한 번 replay해 Redis와 MySQL까지 완료했고, 영구 validation 오류 C2는 quarantine으로 종결했다.

```text
Redis unavailable
≠ Kafka unavailable
```

이 Run에서 Kafka broker와 topic은 fault 전·중·후에 별도 검증됐다. 의도적으로 중단한 것은 Redis container이며, Kafka source record는 이미 존재했다. 따라서 이번 장애의 최초 실패 경계는 Kafka append가 아니라 Processing의 Redis handoff다.

## 정상 처리 경로

```text
barcode-events
→ barcode-processing-service
→ Redis Lua: dedupe + XADD + dedupe mark
→ barcode:stream
→ barcode-persistence-group
→ barcode-persistence-worker
→ MySQL
```

Processing은 `barcode-events`를 group `barcode-processing-group`으로 소비한다. `dedupe-and-publish.lua`는 `originalBarcode` 기반 중복 표시와 Redis Stream `XADD`를 하나의 Redis 원자 실행으로 묶는다. Worker는 Stream `barcode:stream`을 group `barcode-persistence-group`으로 읽고 MySQL에 저장한다.

## 장애와 복구의 인과 사슬

```text
Kafka source record
→ Processing
→ Redis handoff attempt
→ Redis unavailable
→ source retry
→ retry exhaustion
→ barcode-events-dlt
→ Redis recovery
→ one-shot snapshot-bounded disposition
→ replay 또는 quarantine
→ Redis Stream acceptance
→ Worker
→ MySQL persistence
→ final logical identity reconciliation
```

Material Run 시간선은 다음과 같다.

| 시각(UTC) | 전이 | 의미 |
|---|---|---|
| 07:04:21 | formal start | Run identity 활성화 |
| 07:05:52–07:05:58 | C0 정상 처리 | 장애 전 end-to-end 기준선 |
| 07:07:09 | Redis stop, unavailable 확인 | `PONG` 실패와 container exited 직접 관측 |
| 07:08:13 | C1·C2 전송 | Redis unavailable window와 active traffic 중첩 |
| 07:12:19 | DLT end offset 2→4 | C1/C2의 DLT 책임 이전 완료 |
| 07:15:18 | Redis healthy/PONG | infrastructure recovery일 뿐 완료 아님 |
| 07:15:55–07:15:59 | one-shot disposition | C1 replay, C2 quarantine, DLT commit |
| 07:16:48 | C1 MySQL 완료, C2 quarantine 확인 | disposition/downstream recovery |
| 07:18:11–07:18:20 | C3 정상 처리 | 새 post-recovery traffic 성공 |
| 07:21:18 | identity reconciliation PASS | successor identity 전체 귀속 |

초기 DLT poll 파일의 `FAIL`은 제한 시간 안에 새 DLT record가 나타나지 않았다는 중간 상태다. 이어진 continuation poll에서 DLT end offset이 `2 → 4`, source lag이 `2 → 0`으로 바뀌어 최종 `PASS`가 됐다. 중간 파일 하나만 떼어 최종 Outcome으로 읽지 않는다.

## C0–C3가 맡은 역할

| Cohort | Source / disposition | 최종 귀속 | 판단 |
|---|---|---|---|
| C0 | 장애 전 정상 source 1건 | Redis 1, MySQL 1 | 정상 기준선 |
| C1 | 원본 `barcode-events/0/2`, DLT `/0/2`, replay source `/0/4` | Redis 1, MySQL 1 | transient recovery 완료 |
| C2 | 원본 `barcode-events/0/3`, DLT `/0/3` | quarantine 1, Redis/MySQL 0 | permanent terminal disposition |
| C3 | 복구 뒤 정상 source 1건 | Redis 1, MySQL 1 | 새 처리 흐름 복구 확인 |

C1의 source occurrence가 2인 것은 같은 business identity의 원본과 replay다. 두 건을 별도 업무 완료로 계산하지 않는다.

## Retry와 DLT 책임 이전

`KafkaConfig`는 Redis handoff exception에 `2초 간격, 최대 3회 재시도`를 적용한다. 최초 delivery와 세 번의 retry로 C1은 총 4회 delivery가 관측됐다. Redis command timeout이 계속되자 `QueryTimeoutException` cause chain을 `TRANSIENT_REDIS`로 분류해 `barcode-events-dlt`에 발행했다.

C2의 빈 `deviceId`는 `PermanentEventValidationException`이다. 재시도로 의미가 바뀌지 않으므로 transient retry를 우회하고 `PERMANENT_VALIDATION` DLT로 이동했다.

```text
Kafka source offset committed
≠ Business processing lost
```

source consumer가 원본 offset을 지나갔다는 것은 정상 완료 또는 DLT로 책임 이전됐다는 뜻일 수 있다. DLT와 root identity를 함께 보지 않으면 손실인지, 격리인지, 재개 대기인지 판단할 수 없다.

```text
DLT record exists
≠ Processing complete
```

DLT는 실패 책임을 보존하는 중간 상태다. C1은 Redis 복구 뒤 replay가 필요했고, C2는 quarantine terminal state가 필요했다.

## Failure category와 disposition semantics

| 입력 상태 | Normalized state | Disposition |
|---|---|---|
| Redis timeout/connection failure | `TRANSIENT_REDIS`, generation 0 | replay count 1로 `barcode-events`에 한 번 replay |
| 영구 validation failure | `PERMANENT_VALIDATION` | `barcode-events-quarantine` |
| 인식 불가 예외·분류 누락 | `UNKNOWN` | fail closed, quarantine |
| replay count 누락 | generation 0 | category 규칙 적용 |
| 음수·숫자 아님·해석 불가 | malformed | `INVALID_REPLAY_COUNT`, quarantine |
| replay count ≥ 1 | exhausted | `REPLAY_EXHAUSTED`, quarantine |

최대 DLT replay 횟수는 `1`이다. quarantine record는 replay하지 않는다.

Verified Material Run은 C1의 `0 → 1` replay와 C2 permanent quarantine을 실행했다. `UNKNOWN` historical record도 disposition 중 quarantine됐지만 successor cohort가 아니며, malformed replay-count와 replay-exhausted path는 이 Material Run cohort로 실행하지 않았다. 구현과 deterministic test의 존재를 Run 관측으로 확대하지 않는다.

## One-shot snapshot과 commit boundary

DLT disposition은 시작할 때 세 partition의 end offset을 고정했다.

```text
barcode-events-dlt-0 = 4
barcode-events-dlt-1 = 0
barcode-events-dlt-2 = 0
```

같은 실행은 `offset < startup snapshot end`인 `0..3`만 처리했다. 먼저 존재하던 historical residue 2건과 successor C1/C2 2건이다. 새로 append된 record를 재귀적으로 계속 먹지 않는다.

각 record의 정산 순서는 다음과 같다.

```text
classify
→ replay/quarantine output publish
→ publish success 확인
→ commitSync(DLT offset + 1)
```

```text
output publish success
→ DLT offset commit
```

순서는 “출력 없이 DLT를 완료 처리”하는 위험을 줄인다. 그러나 publish와 commit은 하나의 Kafka transaction이 아니다.

```text
publish success
→ commit 전 failure
→ 같은 DLT record 재소비 가능
→ same-generation duplicate output 가능
```

Producer의 idempotence가 켜져 있어도 별도 consumer offset commit과 원자적으로 묶이지 않는다. 따라서 exactly-once replay를 주장하지 않는다.

## Identity accountability

### 사용한 identity 계층

```text
Business identity
(originalBarcode, scanTime, deviceId)

↕

Kafka transport identity
(topic, partition, offset)

↕

Disposition
(retry / DLT / quarantine, category, replay-count)

↕

Redis identity
(Redis Record ID, internalBarcodeId, originalBarcode, scanTime, deviceId)

↕

MySQL final identity
(internalBarcodeId, originalBarcode, scanTime, deviceId)
```

### 연결 강도

| 연결 | 수준 | 근거와 한계 |
|---|---|---|
| Business identity ↔ source Kafka offset | 직접 연결 | source dump 한 record에 payload와 topic/partition/offset이 함께 존재 |
| Source offset ↔ DLT offset | 직접 연결 | DLT original topic/partition/offset header와 동일 payload 존재 |
| DLT C1 ↔ replay source | 직접 연결 | 동일 payload, retained original metadata, category와 replay-count `1` 존재 |
| DLT C2 ↔ quarantine | 직접 연결 | 동일 payload, source DLT locator, category와 quarantine reason 존재 |
| Kafka/replay ↔ Redis entry | 파생 조정(Derived Reconciliation) | `originalBarcode`, `scanTime`, `deviceId`가 일치하지만 Redis entry에 Kafka partition/offset은 저장되지 않음 |
| Redis entry ↔ MySQL row | 직접 필드 동일성 + 파생 처리 인과 | `internalBarcodeId`와 business fields가 일치하지만 MySQL row에 Redis Record ID는 저장되지 않음 |
| 특정 Kafka delivery attempt ↔ 특정 Redis command | 직접 증명 불가 | 구조화된 cross-system trace ID가 없음 |
| 특정 Worker read/XACK ↔ MySQL transaction commit | 직접 증명 불가 | 이 Run은 최종 ID와 PEL 0을 확인했지만 per-action trace를 저장하지 않음 |

따라서 C1의 최종 accountability는 강하게 입증됐지만 전 구간을 하나의 direct distributed trace라고 표현하지 않는다.

## Recovery Complete를 단계로 나누는 이유

```text
Infrastructure Recovery
→ Redis reachable, PONG, healthy

Processing Recovery
→ replay와 새 source record의 Redis handoff 성공

Disposition Recovery
→ DLT ownership이 replay 또는 quarantine으로 정산

Downstream Recovery
→ Redis-accepted identity가 Worker를 거쳐 MySQL 또는 terminal state로 진행

Identity Reconciliation
→ 모든 run-scoped identity가 정확히 하나의 설명 가능한 최종 책임에 귀속
```

```text
Redis healthy
≠ Recovery Complete
```

최종 시점에는 source consumer lag, DLT disposition lag, Redis group lag와 PEL이 모두 `0`이었고 unknown residue는 `NONE`, unaccounted successor identity는 `0`이었다. 이 수치는 진행 상태를 뒷받침한다. 완료 판정의 핵심은 C0–C3 각 identity의 귀속이다.

```text
Count convergence
≠ Exact identity accountability
```

동일한 총합이라도 어떤 C1이 빠지고 다른 identity가 중복되면 실패다. 그래서 `identity-accounting.txt`와 실제 Redis/MySQL 집합을 우선했다.

## Outcome과 limitation

Verified outcome은 `REPRODUCED`다. R1의 `FS-01`부터 `FS-09`까지 독립 검증에서 `SATISFIED`로 확정됐다.

다만 다음은 주장하지 않는다.

- production-scale, high-load 또는 long-duration 안정성
- 일반적인 exactly-once replay
- malformed replay-count와 replay-exhausted path의 Material Run 관측
- publish success 후 DLT commit failure가 실제로 발생하지 않을 것이라는 보장
- Kafka offset부터 Redis Record ID, MySQL transaction까지 이어지는 단일 direct trace
- pre-run broker OOM의 kernel-level root cause 확정

## 관련 자료

- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [R1 Reproduction Contract](./REPRODUCTION-CONTRACT.md)
- [Timeline](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/timeline.txt)
- [DLT disposition](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/03-recovery-disposition/dlt-disposition.txt)
- [Identity accounting](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/identity-accounting.txt)
- [Redis run records](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/redis-stream-run-records.json)
- [MySQL run records](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/mysql-run-records.tsv)
