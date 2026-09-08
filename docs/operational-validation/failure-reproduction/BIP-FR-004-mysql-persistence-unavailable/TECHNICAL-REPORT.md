# BIP-FR-004 MySQL Persistence Unavailability 기술 보고서

## 1. 결론

주 검증 실행 `BIP-FR-004-MR-20260908T055225Z`의 Failure Reproduction Workflow Outcome은 `PARTIALLY_REPRODUCED`다. 승인된 로컬 full-pipeline 환경에서 active Scanner traffic 중 MySQL만 중단하자 Worker의 DB 접근이 실패했고, Redis 소비자 그룹의 보류 항목 목록(Pending Entries List, PEL)은 `252`까지 증가했다. Kafka와 Redis를 포함한 비대상 경계는 계속 동작했으며 traffic process도 살아 있었다.

같은 MySQL container와 volume의 availability를 복원한 뒤 Worker restart나 설정 완화 없이 신규 record persistence가 재개됐다. 이후 application-owned reclaim이 관찰됐고, 남아 있던 PEL `132`건은 `0`으로 소진되면서 MySQL cohort가 `618`에서 `750`으로 수렴했다. 최종적으로 accepted `750`개 identity는 MySQL unique `750`, Redis DLQ `0`, Kafka DLT `0`, pending `0`, unaccounted `0`, multi-state conflict `0`으로 조정됐다.

이 실행이 주는 가장 중요한 운영 결론은 다음과 같다.

> **MySQL healthy ≠ Persistence Pipeline Recovery Complete**

MySQL health 또는 read가 회복된 시점은 dependency availability가 돌아온 시점이다. 복구 완료(Recovery Complete)는 Worker 처리, application-owned reclaim, PEL 소진과 identity-level terminal reconciliation까지 확인한 뒤에만 선언할 수 있다.

다만 동일 Redis `RecordId` 하나를 `DB failure → no XACK → PEL → XCLAIM → persistence → XACK` 전체 lifecycle에 걸쳐 직접 연결한 Evidence는 확보하지 못했다. 따라서 record-level ownership/ACK traceability는 부분 검증이며 Outcome을 `REPRODUCED`로 승격하지 않는다.

## 2. 운영 질문과 검증 경계

이 Scenario의 질문은 “MySQL container가 stop/start 되는가”가 아니다.

> 외부 persistence dependency가 unavailable해졌을 때 처리 책임이 어디에 남으며, dependency가 복구된 뒤 application이 unfinished work를 어떻게 다시 처리하고, 언제 실제 Recovery Complete라고 판단할 수 있는가?

검증 범위는 다음으로 제한됐다.

- 로컬 Docker full-pipeline topology와 bounded active traffic
- 기존 MySQL container 하나의 일시 중단과 동일 container/volume 복구
- Kafka, Processing, Redis와 두 Persistence Worker의 실행 유지
- Worker DB access failure, PEL 변화, 신규 흐름 회복, 자연스러운 application reclaim와 최종 조정 관찰
- Worker restart, 설정 완화, manual `XCLAIM`/`XACK`, Redis state mutation 없이 복구

## 3. 처리 구조와 책임 경계

검증 대상의 처리 구조는 다음과 같다.

```text
Kafka
→ Processing
→ Redis Streams
→ Persistence Worker
→ MySQL
```

각 구성 요소의 책임은 서로 다르다.

| 경계 | 책임 | 장애 시 확인할 상태 |
|---|---|---|
| Kafka / Processing | 입력 이벤트를 처리해 Redis Streams로 전달 | upstream 진행 여부와 Kafka lag |
| Redis Streams | persistence work를 Worker에 전달하고 consumer-group ownership 보존 | group lag, PEL, consumer ownership |
| Persistence Worker | Redis record를 DB 처리 경로에 넣고 완료 뒤 ACK | DB access failure, reclaim, processing health |
| MySQL | 최종 비즈니스 데이터를 영속화 | availability, 실제 read/write, run cohort count |

MySQL 장애는 upstream 입력을 반드시 막는 장애가 아니다. 이번 실행에서는 Scanner부터 Redis까지 흐름이 계속되는 동안 persistence boundary만 닫혔다. 따라서 장애를 “전체 pipeline 중단”으로 뭉뚱그리지 않고, record가 어느 경계까지 도달했으며 완료 책임이 어디에 남았는지 추적해야 한다.

## 4. Redis PEL과 `group lag = 0`의 의미

PEL은 단순한 input backlog가 아니다. Redis 소비자 그룹에서 consumer에게 이미 전달됐지만 아직 ACK되지 않은 미완료 소유권(unfinished ownership)을 나타낸다.

```text
group lag
= 아직 consumer group에 전달되지 않은 새 record

PEL
= consumer에게 전달됐지만 완료 ACK가 없는 record
```

따라서 다음 상태는 모순이 아니다.

```text
group lag = 0
+ PEL > 0
```

이는 새로 전달할 backlog는 없지만, Worker가 이미 가져간 record 중 completion boundary를 통과하지 못한 work가 남아 있을 수 있다는 뜻이다. 실제 reclaim 관찰에서 `06:04:31Z`부터 group lag는 `0`이었지만 PEL `132`와 MySQL `476`이었고, `06:05:18Z`에는 traffic이 사실상 끝난 뒤에도 PEL `132`, MySQL `618`이 유지됐다. 입력 전달이 끝났다는 사실만으로 persistence 완료를 선언할 수 없었던 이유다.

## 5. Monitoring / Symptom

장애 중 관측된 신호는 다음 조합이었다.

| Signal | 관측 | 운영 의미 |
|---|---:|---|
| MySQL runtime | `exited`, port closed | persistence dependency availability 상실 |
| Traffic | process alive, `DRIVER_END` 없음 | active traffic과 fault가 실제로 중첩 |
| Worker | JDBC `Communications link failure`, DB lookup failure | Worker가 record를 받았지만 DB 경계를 통과하지 못함 |
| Redis PEL | `13 → 132 → 132 → 252` | 전달된 record의 unfinished ownership 증가 |
| Redis group lag | outage snapshot에서 낮거나 변동 | upstream이 계속 새 record를 전달 중 |
| Kafka / 비대상 subsystem | healthy | failure domain을 MySQL persistence boundary로 축소하는 근거 |

단일 신호만으로는 충분하지 않다. 예를 들어 PEL 증가만 보면 Worker 자체 장애, Redis consumer stall 또는 느린 DB도 후보가 될 수 있다. MySQL port closed, Worker의 DB 통신 실패, active traffic, PEL 증가, 비대상 subsystem health를 함께 볼 때 MySQL availability failure로 장애 영역(Failure Domain)을 좁힐 수 있다.

## 6. Failure-domain narrowing

운영자는 다음 순서로 질문을 좁힌다.

1. **입력이 Worker까지 오지 않았는가?** Kafka/Processing/Redis 흐름과 group lag를 확인한다.
2. **Worker가 record를 받았지만 완료하지 못했는가?** PEL, consumer별 pending과 Worker processing log를 확인한다.
3. **완료 실패가 MySQL 경계 때문인가?** MySQL availability/readiness와 같은 시각의 JDBC failure를 연결한다.
4. **장애가 MySQL에 한정됐는가?** Kafka, Redis, application health와 unrelated restart/OOM 부재를 확인한다.
5. **책임이 소실됐는가, 보존됐는가?** PEL과 최종 identity reconciliation으로 판단한다.

이번 실행에서는 MySQL이 `06:02:34Z`에 중단됐고, Worker는 `Communications link failure`와 “읽은 record는 ack되지 않아 pending에 남는다”는 processing failure를 남겼다. `06:03:37Z` outage 관찰 시 PEL은 `252`였다. 이 인과 순서는 “Worker가 입력을 받지 못했다”보다 “Worker가 입력을 받은 뒤 DB completion boundary에서 실패했다”는 해석을 지지한다.

## 7. Hypothesis와 Evidence 판정

검증 가설은 다음과 같았다.

```text
MySQL availability failure
→ Worker DB access failure
→ 완료되지 않은 record의 PEL ownership 증가
→ MySQL availability recovery
→ 신규 persistence 회복
→ application-owned reclaim
→ PEL drain
→ terminal reconciliation
→ Recovery Complete
```

Evidence는 가설 전체를 같은 강도로 지지하지 않는다.

### 7.1 직접 확인된 사실

- active traffic 중 기존 MySQL container가 중단되고 port가 닫혔다.
- Worker 두 개에서 MySQL `Communications link failure`와 DB lookup failure가 관측됐다.
- outage 동안 PEL은 `13 → 132 → 132 → 252`로 증가했다.
- 동일 MySQL container/volume이 복구됐고 실제 read와 readiness가 회복됐다.
- Worker restart 없이 post-recovery MySQL cohort가 `297 → 415`로 증가했다.
- application-owned reclaim activity가 관찰됐고 PEL은 `132 → 0`, MySQL cohort는 `618 → 750`으로 수렴했다.
- 최종 accepted `750`건이 MySQL unique `750`건으로 귀속됐으며 DLQ, DLT, pending, unaccounted와 conflict는 모두 `0`이었다.

### 7.2 강하게 지지되는 해석

- PEL 증가는 Worker에 전달됐지만 DB completion boundary를 통과하지 못한 unfinished ownership이 누적된 현상이다.
- MySQL 복구 뒤 신규 흐름은 먼저 회복됐지만 기존 pending `132`건은 별도 reclaim 시점까지 남아 있었다.
- 마지막 `132`건의 PEL 소진과 MySQL `132`건 증가는 application reclaim이 기존 unfinished work를 persistence 경로로 다시 넣어 수렴시켰다는 해석을 강하게 지지한다.

### 7.3 직접 연결하지 못한 사실

- 동일 Redis `RecordId` 하나의 DB failure와 no XACK
- 그 ID의 PEL 체류와 explicit-ID `XCLAIM`
- 같은 ID의 MySQL persistence와 최종 `XACK`

이 gap 때문에 전체 record lifecycle을 직접 증명했다고 표현하지 않는다. 집합 수준의 장애·reclaim·수렴은 검증됐지만, 단일 record 수준 ownership/ACK 인과 추적은 부분적이다.

## 8. Application-owned Recovery

현재 Worker 구현에서 recovery semantics는 Redis가 단독으로 자동 완성하지 않는다. Application scheduler와 persistence path가 Redis consumer-group 기능을 조합한다.

```text
XPENDING summary/detail
→ 5분 이상 idle인 RecordId 선택
→ explicit RecordId로 XCLAIM
→ 기존 persistence path 재진입
→ MySQL persistence 또는 승인된 terminal routing
→ 성공한 record만 XACK
```

Worker의 pending scheduler는 60초 주기로 동작하고, 5분 이상 idle인 pending ID만 reclaim 후보로 선택한다. `XCLAIM`은 처리 ownership을 현재 consumer로 옮기지만 그 자체가 비즈니스 완료를 뜻하지 않는다. Claimed record가 persistence path를 다시 통과하고 MySQL 저장 또는 승인된 DLQ routing이 성공한 뒤에야 원본 ACK가 가능하다.

이번 Material Run에서는 controller나 사람이 manual claim/ACK를 수행하지 않았다. Recovery는 application-owned path로 관찰됐다. 다만 실제 Run Evidence가 위 단계 전체를 동일 `RecordId` 하나로 연결하지 못했으므로, 소스의 가능한 동작과 Material Run에서 직접 관측된 lifecycle을 구분한다.

## 9. 인과 시간선

| UTC | 사건 | 판정 의미 |
|---|---|---|
| `06:01:52` | healthy baseline PASS, traffic 시작 | fault 전 정상 조건과 cohort 시작 |
| `06:02:29–06:02:30` | active traffic predicate와 fault transition PASS | fault/traffic 시간 중첩 확인 |
| `06:02:34` | MySQL stop 완료 | persistence dependency availability 상실 |
| `06:03:37` | port closed, Worker DB failure, PEL `252` | failure signature 관측 |
| `06:03:43` | 동일 MySQL container/volume recovery | dependency availability 회복 |
| `06:04:16` | MySQL cohort `297 → 415` | Worker restart 없는 신규 흐름 회복 |
| `06:05:08` | traffic `750/750` 완료 | 입력 cohort 닫힘; 이때도 기존 PEL 잔존 |
| `06:05:18` | PEL `132`, lag `0`, MySQL `618` | delivery 완료와 persistence 완료가 다름 |
| `06:08:24–06:08:25` | PEL `132 → 0`, MySQL `618 → 750` | application reclaim과 backlog 수렴 |
| `06:08:42` | accepted `750`, MySQL `750`, 기타 terminal state `0` | Recovery Complete 판정 |

MySQL은 `06:03:43Z`에 healthy 상태로 돌아왔지만 최종 조정은 약 5분 뒤인 `06:08:42Z`에 끝났다. 이 간격이 dependency recovery와 application recovery를 분리해야 하는 실증적 이유다.

## 10. Troubleshooting Action

이 Scenario에서 필요한 조치는 특정 CLI 사용법이 아니라 상태 전이를 확인하고 잘못된 조기 종료를 막는 것이다.

### 장애 중

- active input과 fault가 실제로 중첩됐는지 확인한다.
- Kafka/Processing/Redis delivery와 Worker DB failure를 분리해 최초로 끊어진 경계를 찾는다.
- group lag만 보지 않고 PEL summary/detail과 consumer별 ownership을 함께 본다.
- MySQL runtime/port/readiness와 Worker JDBC failure의 시각을 연결한다.
- pending을 수동 ACK하거나 claim해 Evidence와 application recovery semantics를 훼손하지 않는다.

### 복구 중

- MySQL process health뿐 아니라 실제 read와 Worker의 신규 persistence를 확인한다.
- application scheduler가 reclaim eligibility를 충족할 때까지 PEL과 MySQL cohort를 함께 관찰한다.
- `PEL 감소`를 진행 신호로 사용하되, 0이 되기 전에는 완료로 판정하지 않는다.
- DLQ/DLT 증가, unaccounted identity 또는 multi-state conflict가 생기면 단순 PEL drain을 성공으로 해석하지 않는다.
- application restart나 설정 완화 없이 승인된 recovery path가 작동했는지 확인한다.

## 11. Recovery 단계와 완료 조건

복구는 하나의 boolean health가 아니라 다음 단계의 수렴이다.

1. **Dependency Available**: 동일 MySQL container/volume이 healthy이고 실제 read가 가능하다.
2. **New Flow Healthy**: Worker restart 없이 새 record가 MySQL에 저장된다.
3. **Unfinished Ownership Progressing**: application-owned reclaim이 eligible pending을 다시 처리한다.
4. **PEL Drained**: Redis PEL과 group lag가 `0` 또는 사전 정의된 설명 가능한 값으로 수렴한다.
5. **Terminal Reconciliation Complete**: accepted identity 전부가 상호 배타적인 최종 상태로 귀속된다.
6. **Recovery Complete**: unaccounted `0`, multi-state conflict `0`, pending `0`이며 scenario가 허용한 최종 상태와 일치한다.

```text
MySQL Healthy
≠ Worker Processing Healthy
≠ PEL Drained
≠ Terminal Reconciliation Complete
```

앞 단계는 뒤 단계의 필요조건일 수 있지만 충분조건은 아니다.

## 12. 최종 reconciliation

| 항목 | 결과 |
|---|---:|
| attempted / accepted | `750 / 750` |
| explicit rejected / HTTP other / transport error | `0 / 0 / 0` |
| Redis run unique | `750` |
| MySQL rows / unique identities | `750 / 750` |
| Redis DLQ / Kafka DLT | `0 / 0` |
| Redis pending / group lag | `0 / 0` |
| unaccounted / multi-state conflict | `0 / 0` |

적용한 accounting boundary는 다음과 같다.

```text
N_accepted
= N_mysql
+ N_redis_dlq
+ N_kafka_dlt
+ N_redis_pending
+ N_unaccounted
+ N_multi_state_conflict
```

`pending ≠ unaccounted`다. Pending은 아직 완료되지 않았지만 Redis consumer group이 추적하는 소유권이고, unaccounted는 어느 허용된 최종·중간 상태에서도 설명할 수 없는 identity다. Recovery Complete에는 둘 다 `0`이어야 한다.

## 13. Outcome 정밀도와 최대 검증 주장

Outcome은 `PARTIALLY_REPRODUCED`로 유지한다. `BIP-FR-004-RC-R2`의 experiment validity는 `PASS`였지만 Evidence Sufficiency는 partial reproduction claim에 충분한 `PARTIAL`이었다. FS-1 fault authenticity, FS-2 upstream isolation과 FS-5 recovery/accountability는 충족됐고, FS-3 persistence failure/ownership retention과 FS-4 application-owned reclaim/ACK boundary는 부분 충족이었다. Conditional Retry/DLQ path는 `NOT OBSERVED / CODE PATH NOT REACHED`다.

> 승인된 로컬 BIP-FR-004 R2 topology와 bounded active traffic에서 MySQL persistence unavailable 상태가 Worker DB access failure와 Redis PEL ownership accumulation을 만들었고 비대상 subsystem은 healthy 상태를 유지했다. 동일 MySQL container/volume 복구 뒤 Worker restart나 설정 완화 없이 신규 persistence와 application-owned reclaim activity가 관찰됐으며, PEL은 0으로 소진되고 accepted identity 750건 전부가 DLQ, DLT, unaccounted 또는 conflict 없이 MySQL로 조정됐다. 다만 동일 Redis `RecordId`의 DB failure부터 최종 XACK까지의 전체 사슬은 직접 연결하지 못했다.

이 제한은 closure blocker나 필수 remediation이 아니다. BIP-FR-004는 `CLOSED / PARTIALLY_REPRODUCED`이며 RC-R3와 추가 Material Run은 필요하지 않다.

## 14. 명시적 비주장

- `REPRODUCED` Outcome 또는 동일 `RecordId` lifecycle의 직접 증명
- Redis만으로 recovery가 자동 완성된다는 주장
- MySQL health restoration만으로 Recovery Complete라는 주장
- 일반적인 exactly-once 또는 duplicate-free processing guarantee
- production availability, SLA, RTO/RPO 또는 capacity/soak 특성
- network partition, storage loss/corruption/full 또는 다른 database failure mode
- Kafka, Redis, Worker 또는 복합 장애에서 동일한 복구 동작
- 모든 retry/DLQ code path의 runtime 검증
- historical R1 Evidence를 R2 Outcome의 직접 Evidence로 재분류

## 15. 운영적 의미

첫째, dependency alert의 해제와 incident closure는 같은 사건이 아니다. MySQL health가 회복되면 persistence 시도가 다시 성공할 수 있지만, 장애 중 Worker가 이미 소유한 unfinished work는 PEL에 남을 수 있다.

둘째, lag dashboard 하나로 backlog를 판단하면 복구를 조기에 선언할 수 있다. `group lag=0`은 새 delivery backlog가 없다는 뜻이지 PEL completion을 보장하지 않는다. Redis 운영 관측은 lag와 PEL을 분리해야 한다.

셋째, reclaim은 ownership 이동이지 완료 자체가 아니다. 운영자는 claim activity, MySQL row 증가, XACK에 따른 PEL 감소와 최종 identity reconciliation을 함께 봐야 한다.

넷째, 최종 조정은 유실 여부뿐 아니라 상태 충돌도 찾는다. `750/750` 총계, pending `0`, unaccounted `0`, conflict `0`이 함께 맞아야 이 bounded run의 Recovery Complete를 선언할 수 있다.

## 16. Evidence Navigation

- [Reproduction Contract R2](./REPRODUCTION-CONTRACT-R2.md)
- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [주 Material Run Evidence](./evidence/BIP-FR-004-MR-20260908T055225Z/)
- [Run timeline](./evidence/BIP-FR-004-MR-20260908T055225Z/00-environment/timeline.tsv)
- [Outage state](./evidence/BIP-FR-004-MR-20260908T055225Z/03-fault/outage-state.txt)
- [Worker failure Evidence](./evidence/BIP-FR-004-MR-20260908T055225Z/04-worker/outage-worker.log)
- [PEL progression](./evidence/BIP-FR-004-MR-20260908T055225Z/05-redis/outage-progression.tsv)
- [Reclaim progression](./evidence/BIP-FR-004-MR-20260908T055225Z/07-recovery/reclaim-evidence.txt)
- [Final reconciliation](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/reconciliation.txt)
- [주 Run SHA-256 manifest](./evidence/BIP-FR-004-MR-20260908T055225Z/MANIFEST.sha256)
