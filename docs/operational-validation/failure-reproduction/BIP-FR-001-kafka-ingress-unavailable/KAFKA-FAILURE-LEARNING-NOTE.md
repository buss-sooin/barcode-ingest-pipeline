# BIP-FR-001 Kafka Failure Learning Note

## 1. 문서 목적과 책임 경계

이 문서의 단일 책임은 BIP-FR-001 판정 대상 실행에서 관측한 Kafka, Redis, MySQL 수치가 **왜 함께 성립할 수 있는지**를 설명하는 것이다. 설명은 다음 인과 구조를 따른다.

```text
관측된 BIP 현상
→ 관련 저장소 구현
→ Kafka / Redis / 분산 시스템 의미론
→ BIP-FR-001 해석
→ 이 증거가 입증하지 않는 것
```

이 문서는 장애 조치 절차, 진단 가이드, Runbook, 실험 보고서 또는 README가 아니다. 운영 명령, 판정 절차, 경보 임계값, 아키텍처 개선안도 제시하지 않는다. 결론의 적용 범위는 BIP 프로젝트의 `BIP-FR-001 / 20260829T073503Z` 로컬 단일 실행으로 제한한다.

학습 질문은 다음 절에서 추적할 수 있다.

| 질문 | 핵심 질문 | 설명 위치 |
|---|---|---|
| LQ-A | 애플리케이션 타임아웃이 왜 Kafka 저장 실패를 입증하지 않는가 | [5. 확인 불확실성](#5-확인-불확실성acknowledgment-uncertainty) |
| LQ-B | 재시도가 왜 유실 위험을 낮추면서 중복 위험을 높일 수 있는가 | [6. 재시도 Trade-off](#6-재시도retry가-loss와-duplicate-사이에-만드는-trade-off) |
| LQ-C | 논리 이벤트 수와 Kafka 전송 레코드 수를 왜 구분해야 하는가 | [4. 논리 이벤트와 전송 레코드](#4-논리-이벤트logical-event와-전송-레코드transport-record) |
| LQ-D | 반복 전달·처리가 어떻게 MySQL 820건으로 수렴했는가 | [7. At-least-once Processing과 멱등성](#7-at-least-once-processing과-멱등성idempotency), [8. BIP의 계층별 Duplicate Containment](#8-bip의-계층별-duplicate-containment) |
| LQ-E | Kafka 장애 중 미완료 작업이 어디에 존재하며 왜 backlog drain이 필요한가 | [9. Backpressure와 백로그의 위치](#9-backpressure와-백로그의-위치), [10. Recovery 이후 Backlog Drain](#10-recovery-이후-backlog-drain이-필요한-이유) |
| LQ-F | Redis PEL, redelivery, `XACK`이 persistence lifecycle에서 무엇을 뜻하는가 | [11. Redis PEL, Redelivery, XACK](#11-redis-pel-redelivery-xack의-의미) |
| LQ-G | broker availability 또는 소비자 지연 정상화가 왜 Recovery Complete를 입증하지 못하는가 | [12. 종단 간 조정](#12-종단-간-조정end-to-end-reconciliation) |

## 2. BIP-FR-001 판정 대상 실행(Material Run) 학습 Anchor

판정 대상은 `20260829T073503Z` 실행이다. 아래 값은 일반론이 아니라 이 실행에서 수집한 실행 증거(Material Run Evidence, MR)다.

| 경계 | MR 관측값 | 직접 근거 |
|---|---:|---|
| 생성된 논리 이벤트 | 820 unique | [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| Kafka 전송 레코드 | 1,235 | [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| 재시도 유발 중복 레코드 | 415 | [29-detect-impact-recovery-summary.txt](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt), [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| Processing 처리 | received 1,235 / new 820 / duplicate 415 / error 0 | [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| Redis Stream 최종 상태 | length 820 / group lag 0 / PEL 0 | [22-backlog-drain-observation.txt](./evidence/20260829T073503Z/22-backlog-drain-observation.txt), [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| MySQL 최종 상태 | 820 rows / 820 unique persisted / final duplicate 0 | [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |
| 실패·미완료 경로 | DLQ 0 / DLT 0 / retry pending 0 / unaccounted 0 | [22-backlog-drain-observation.txt](./evidence/20260829T073503Z/22-backlog-drain-observation.txt), [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) |

핵심 산술은 다음과 같다.

```text
Kafka records 1,235 = logical events 820 + retry-induced duplicate records 415
```

그러나 이 식은 “Kafka가 임의로 415건을 복제했다”는 뜻이 아니다. MR은 220개 outage event에 대해 batch 확인 실패 후 single 경로가 활성화되었고, single response가 415회였으며, 원래 배치 전송의 백그라운드 Future와 별도 single 전송 시도가 복구 후 함께 완료된 사실을 기록한다. Scanner 로그에는 HTTP client의 자동 재실행도 관측된다. 다만 415건 각각을 Scanner의 명시적 fallback, scheduled retry, HTTP client 재실행 중 하나로 완전히 분해한 실행 증거는 없다. 이 문서에서 “재시도 유발”은 이러한 별도 애플리케이션 전송 시도 전체가 만든 전송 증폭을 가리키며, 각 하위 메커니즘의 개별 기여도를 확정하지 않는다.

상세 실행 판정과 제한은 [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)의 `Material Failure Run — 20260829T073503Z`에 있다.

## 3. Evidence와 설명을 구분하는 방법

이 문서는 다음 지식·증거 분류를 구분한다.

| 분류 | 의미 | 사용 경계 |
|---|---|---|
| MR | 판정 대상 Material Run에서 직접 수집하거나 그 실행 자료에서 산출한 값 | `20260829T073503Z`에만 직접 적용한다. |
| REPO | 현재 저장소 코드·설정에서 확인한 구현 사실 | 구현 revision이 바뀌면 다시 검증해야 한다. |
| SEM | Kafka·Redis 공식 문서가 정의하는 일반 의미론 | 특정 BIP 사건이 실제 발생했다는 증거로 사용하지 않는다. |
| INT | MR, REPO, SEM을 연결한 해석 | 직접 관측이 아니라는 점을 드러낸다. |
| Non-claim | 현재 증거가 입증하지 않는 범위 | 보장 범위의 과도한 확장을 막는다. |

예를 들어 “Ingest가 HTTP `503`을 반환했다”는 MR과 REPO로 확인할 수 있다. “따라서 해당 레코드는 Kafka에 없다”는 결론은 성립하지 않는다. 저장 성공 여부를 응답 시점에 확정하지 못했다는 사실과 실제 append 실패는 서로 다른 상태이기 때문이다.

## 4. 논리 이벤트(Logical Event)와 전송 레코드(Transport Record)

논리 이벤트는 업무 관점에서 한 번의 스캔을 나타낸다. 이 실행은 `scanTimeMs`를 generated manifest의 identity로 사용해 서로 겹치지 않는 healthy 300건, outage 220건, post-recovery 300건을 합산했다. 따라서 논리 이벤트 수는 820이다. 바코드 값은 Processing의 Redis dedupe key로도 사용되지만, 실행 reconciliation의 생성 identity는 `scanTimeMs`였다는 차이를 유지해야 한다.

전송 레코드는 Kafka partition log에 append된 개별 record다. 동일한 논리 이벤트를 담더라도 애플리케이션이 `KafkaTemplate.send(...)`를 다시 호출하면 별도 전송 시도가 되고, 성공한 각 시도는 별도 Kafka record가 될 수 있다.

- **MR:** Kafka final end offset 합계는 1,235이고 Processing은 1,235 records를 수신했다.
- **REPO:** Ingest의 `BarcodeProducer.sendBarcodeEvent(...)`는 호출마다 `KafkaTemplate.send(...)`를 실행한다. Scanner의 batch fallback과 retry queue 경로는 `/ingest/barcode`를 새로 호출하므로 Ingest에서 새로운 send 시도를 만든다.
- **INT:** 이 실행의 `1,235 - 820 = 415`는 논리 이벤트가 늘어난 것이 아니라 transport-level submission이 증폭된 결과다.
- **Non-claim:** Kafka record count만으로 unique business event 수를 알 수 없다. 반대로 logical event count만으로 실제 transport 시도 횟수도 알 수 없다.

따라서 이 시스템에서는 다음 관계가 정상적으로 가능하다.

```text
logical_event_count != kafka_record_count
```

## 5. 확인 불확실성(Acknowledgment Uncertainty)

확인 불확실성은 호출자가 정한 대기 경계 안에서 작업의 최종 성공·실패를 확인하지 못한 상태다.

- **REPO:** `BarcodeIngestController`는 batch의 `CompletableFuture.allOf(...)`와 single record Future를 각각 최대 5초 동안 기다린다. timeout 후 `cancel(...)`을 호출하지 않는다. batch는 아직 완료되지 않은 Future의 index를 실패로 반환하고, single은 HTTP `503`을 반환한다. 반환된 Future에는 `whenComplete(...)` callback이 계속 연결되어 있다.
- **SEM:** Kafka 공식 Message Delivery Semantics는 producer가 응답을 받지 못한 경우 오류가 message commit 전인지 후인지 확신할 수 없는 상황을 설명한다. `delivery.timeout.ms`는 Kafka producer가 `send()` 반환 이후 성공 또는 실패를 보고할 전체 상한이며, BIP controller의 별도 5초 `Future.get(...)` 대기와는 다른 경계다.
- **INT:** BIP의 HTTP `207` 또는 `503`은 “5초 안에 Kafka 발행 성공을 확인하지 못함”이다. Future가 취소되지 않았으므로 원래 send는 그 뒤에도 완료될 수 있다. 이 상태에서 Scanner가 같은 logical event를 다시 보내면 원래 시도와 별도 시도가 모두 성공할 수 있다.
- **MR:** 복구 후 원래 background Future와 fallback/retry 시도가 함께 성공했고, Kafka record 1,235와 Processing duplicate 415로 나타났다.
- **Non-claim:** timeout, HTTP `207`, HTTP `503` 중 어느 것도 그 자체로 “Kafka에 record가 저장되지 않았다”를 입증하지 않는다. 반대로 timeout이 항상 eventual success를 뜻하지도 않는다.

확인 대기 5초와 Ingest producer 설정의 `max.block.ms=5000`도 구분해야 한다. 전자는 반환된 Future의 완료를 controller가 기다리는 시간이고, 후자는 producer `send()`가 metadata 또는 buffer allocation 때문에 block될 수 있는 시간을 제한한다. 값이 같아도 책임과 상태 전이가 다르다.

## 6. 재시도(Retry)가 Loss와 Duplicate 사이에 만드는 Trade-off

불확실한 원래 시도에 대해 선택지는 대칭적이지 않다.

```text
재시도하지 않음
→ 원래 시도가 실제 실패했다면 logical event 유실 가능성

재시도함
→ 원래 시도가 실제 성공했다면 duplicate transport record 가능성
```

- **SEM:** Kafka는 응답을 확인하지 못한 송신자가 record를 다시 보내면 at-least-once 성격이 되고, 원래 요청이 이미 성공했다면 log에 다시 기록될 수 있다고 설명한다. Producer의 `retries`는 일시 오류에 대한 동일 producer request의 재전송을 제어한다.
- **REPO:** Ingest producer에는 `acks=all`, `retries=3`, `max.block.ms=5000`이 설정되어 있다. 그 바깥에서 Scanner는 batch failed index를 single 경로로 fallback하고, single 실패를 process-local queue에 넣어 5초 간격으로 다시 HTTP 요청한다. 각 성공한 별도 HTTP 요청은 새로운 `KafkaTemplate.send(...)` 호출로 이어질 수 있다.
- **MR:** outage 220 logical events에서 batch failed index 합계는 220이었다. single response는 415회였고, 최종 Kafka record 증폭도 415였다. Processing은 같은 바코드 415건을 duplicate로 판정했다.
- **INT:** 이 실행의 duplicate 위험은 Kafka가 원인 없이 record를 복제한 것이 아니라, 확인 불확실성 상태에서 손실 위험을 줄이기 위해 시작된 별도 전송 시도와 원래 미취소 시도가 함께 성공하면서 현실화되었다.
- **Non-claim:** 재시도는 항상 duplicate를 만들지 않는다. 원래 시도가 실제 실패했다면 재시도는 하나의 record만 남길 수 있다. 또한 이 문서는 Kafka client 내부 retry와 애플리케이션의 별도 `send()` 호출을 같은 메커니즘으로 취급하지 않는다.

Kafka producer의 멱등적 전송 설정은 producer protocol 수준에서 retry duplicate를 억제하는 의미를 갖는다. 그러나 현재 저장소는 `enable.idempotence`의 effective runtime 값을 명시적으로 고정하거나 Material Run evidence에 캡처하지 않았다. 따라서 이 문서는 그 effective 값이나 내부 producer retry 기여도를 단정하지 않는다. 더 중요한 경계는 Scanner의 별도 HTTP 요청이 Ingest의 별도 `send()` 호출을 만든다는 REPO 사실이다. Kafka producer idempotence가 business identity를 해석하여 서로 독립된 application send 호출을 합치는 종단 간 dedupe라고 보아서는 안 된다.

## 7. At-least-once Processing과 멱등성(Idempotency)

At-least-once processing에서는 하나의 record 또는 logical event가 반복 전달·처리될 수 있다. 이때 목표는 “모든 계층에서 물리적으로 한 번만 실행”이 아니라, 반복을 허용하되 멱등성 경계에서 최종 business state가 하나로 수렴하도록 하는 것이다.

- **SEM:** Kafka는 consumer가 처리 후 offset을 저장하기 전에 실패하면 새 consumer가 같은 message를 다시 처리할 수 있는 at-least-once window를 설명한다. 외부 시스템에 쓰는 결과와 Kafka offset은 자동으로 하나의 transaction이 되지 않는다.
- **REPO:** Processing의 `@KafkaListener`는 Redis 처리 예외를 삼키지 않는다. 예외는 listener container로 전파되고 `DefaultErrorHandler`가 재시도한 뒤 DLT recovery를 시도한다. 성공 경로에서는 Redis Lua 결과가 duplicate여도 listener invocation 자체는 정상 완료된다.
- **REPO:** Redis-side Lua dedupe, Redis consumer-group PEL과 redelivery, Worker의 safe duplicate ACK, MySQL unique constraint가 서로 다른 반복 가능성을 흡수한다.
- **MR:** Kafka 1,235 records 전부가 Processing에서 성공 처리되었지만 Redis Stream에는 820 entries만 생성되었고 MySQL에도 820 unique rows만 남았다.
- **INT:** 이 실행은 가능한 반복 전달·처리가 계층별 dedupe 및 idempotency boundary를 거쳐 수렴한 사례다.
- **Non-claim:** 이 결과는 Kafka → Redis → MySQL 전체가 end-to-end exactly-once임을 뜻하지 않는다. 특정 bounded run에서 최종 상태가 수렴했다는 증거다.

## 8. BIP의 계층별 Duplicate Containment

### 8.1 Kafka / Application Retry Boundary

Ingest의 한 `sendBarcodeEvent(...)` 호출과 Scanner가 다시 만든 다음 호출은 같은 business event를 담더라도 서로 다른 application send attempt다. 5초 confirmation timeout은 첫 attempt의 terminal result를 변경하거나 취소하지 않는다. Scanner fallback과 retry는 loss exposure를 줄이는 대신 두 attempt가 모두 성공할 수 있는 중복 창을 연다.

Kafka의 producer retry·idempotence 의미론과 BIP의 business dedupe 책임은 구분해야 한다. 전자는 producer protocol의 record delivery를 다루고, 후자는 동일 바코드라는 업무 identity를 판단한다. 이 실행에서 415건을 business duplicate로 식별한 직접 경계는 Processing의 Redis key이지 Kafka broker가 아니다.

### 8.2 Redis Lua Atomic Dedupe Boundary

Processing은 `barcode:processed:{originalBarcode}` key와 `barcode:stream`을 하나의 Lua script에 전달한다. script는 다음 Redis-side 동작을 한 번의 실행으로 구성한다.

```text
duplicate key EXISTS
→ 이미 있으면 0 반환
→ 없으면 XADD
→ 7일 TTL의 duplicate marker SET
→ 1 반환
```

- **REPO:** `BarcodeEventConsumer.processEvent(...)`가 script를 실행하며, `dedupe-and-publish.lua`는 `EXISTS`, `XADD`, `SET ... EX`를 순서대로 호출한다.
- **SEM:** Redis는 Lua script 실행의 원자성(Atomicity)을 보장한다. script 실행 중 다른 server activity가 중간 상태를 관측하거나 끼어들지 않는다.
- **INT:** 동일 Redis instance 안에서는 dedupe decision, stream publish, marker 생성 사이의 경쟁 창이 제거된다. 그래서 1,235 Processing invocation 중 최초 820건만 Stream entry를 만들고 415건은 duplicate로 종료될 수 있었다.
- **Non-claim:** 이 원자성은 해당 Redis script의 Redis-side 실행 격리 경계에만 적용된다. 임의의 runtime error에 대한 RDBMS식 rollback을 뜻하지 않으며, Kafka offset commit, Redis Stream consumer state, MySQL transaction까지 묶는 `Kafka → Redis → MySQL` 분산 transaction도 아니다. 7일 TTL 밖의 모든 duplicate를 영구히 막는다는 보장도 아니다.

### 8.3 Redis PEL / Redelivery Boundary

Worker는 `barcode-persistence-group`에서 `ReadOffset.lastConsumed()`로 새 Stream entry를 읽는다. consumer group으로 전달된 entry는 확인 전까지 미확인 항목 목록(Pending Entries List, PEL)에 속한다. Worker는 60초 간격으로 pending summary를 확인하고, 5분 이상 idle인 entry를 현재 consumer 이름으로 claim하여 다시 처리한다.

이 구조에는 다음과 같은 **가능한** 실패 창이 있다.

```text
MySQL transaction commit 성공
→ Worker가 XACK 전에 실패
→ entry가 PEL에 남음
→ 이후 claim / redelivery
→ MySQL unique constraint가 이미 저장된 logical identity를 검출
→ safe duplicate로 분류한 뒤 XACK 가능
```

이 창은 Redis 의미론과 저장소 구현에서 도출한 가능한 failure mode다. BIP-FR-001 MR에서 실제로 이 순서가 발생했다는 증거는 없다. 최종 PEL 0은 run 종료 시 미확인 entry가 없었다는 뜻일 뿐, 실행 중 redelivery가 전혀 없었다거나 모든 시스템 backlog가 항상 0이었다는 뜻이 아니다.

### 8.4 MySQL Unique Persistence Boundary

`BarcodeEntity`는 `internalBarcodeId`와 `originalBarcode` 각각에 unique constraint를 선언한다. `BarcodeRepositoryImpl.batchInsert(...)`는 transaction 안에서 insert를 수행한다. Worker는 duplicate key가 발생하면 DB에서 두 identity의 존재를 재조회하고, 이미 저장된 record의 Redis entry를 safe duplicate로 간주해 ACK 대상에 포함한다. 건별 삽입의 duplicate key도 ACK 대상으로 분류한다.

이 경계는 redelivery 또는 동시 처리로 같은 identity의 insert가 다시 시도될 때 final duplicate row를 차단한다. 그러나 unique constraint는 그 두 column에 대한 중복만 막는다. 누락, 잘못된 field mapping, 잘못된 logical identity 선택, upstream backlog 또는 모든 business invariant를 검증하지 않는다.

## 9. Backpressure와 백로그의 위치

백로그는 시스템 전체에 하나의 숫자로 존재하지 않는다. component boundary마다 “아직 다음 책임 경계를 통과하지 못한 작업”의 형태가 다르다.

| 위치 | outstanding work의 의미 | 이 위치만 보아서는 알 수 없는 것 |
|---|---|---|
| Scanner buffer / retry queue | 아직 Ingest에서 확정 응답을 받지 못한 logical event | 원래 Kafka send가 나중에 성공할지 여부 |
| Ingest producer / unresolved Future | `send()` 이후 terminal callback을 기다리는 전송 시도 | Scanner가 별도 retry를 시작했는지 여부 |
| Kafka retained records / consumer lag | log에 있으나 consumer group progress가 따라가지 못한 records | Redis publish, MySQL commit, business reconciliation 완료 여부 |
| Redis Stream group lag | group에 아직 전달되지 않은 Stream entries | 이미 전달되어 PEL에 있는 entries |
| Redis PEL | 전달되었지만 아직 `XACK`되지 않은 entries | 처리 중인지, MySQL 실패인지, ACK 직전인지 정확한 원인 |
| Worker persistence work | Redis에서 읽어 DB 처리·분류·ACK를 진행 중인 entries | upstream에 남은 logical events |
| DLQ / DLT | 정상 성공 경로 밖에서 별도 정리가 필요한 terminal candidates | 아직 retry queue나 transport에 남은 work |
| Terminal reconciliation | generated identity 중 어느 terminal state에도 설명되지 않은 항목 | 개별 component metric 하나로 대체할 수 없음 |

Kafka unavailable 동안 이 실행에서는 Scanner fallback과 retry queue, Ingest의 unresolved Future에 outstanding work가 존재했다. broker가 멈춰 새 record가 append되지 않는 동안의 work를 Kafka consumer lag 하나로 표현할 수 없는 이유다. 복구 후에는 원래 Future와 separate retry attempt가 Kafka로 유입되고, 그 뒤 Kafka consumer, Redis Stream, Worker, MySQL 순으로 outstanding work의 위치가 이동했다.

## 10. Recovery 이후 Backlog Drain이 필요한 이유

복구는 다음 네 상태를 구분해야 한다.

```text
Component Recovery
→ Flow Recovery
→ Backlog Drain
→ End-to-end Reconciliation
```

- **Component Recovery:** Kafka broker가 다시 요청에 응답할 수 있다.
- **Flow Recovery:** 신규 publish와 consume가 다시 진행된다.
- **Backlog Drain:** retry queue, unresolved send, Kafka lag, Redis group lag, PEL, persistence work가 더는 남지 않고 수렴한다.
- **End-to-end Reconciliation:** generated logical identity가 MySQL, DLQ, DLT, pending 또는 명시적 unaccounted 상태로 모두 설명된다.

앞 단계는 뒤 단계를 자동으로 보장하지 않는다. Broker가 살아나도 Scanner retry queue가 멈춰 있거나, Kafka records가 Redis로 이동하지 못하거나, Redis entry가 PEL에 남거나, MySQL insert가 완료되지 않을 수 있다.

- **MR:** recovery 후 첫 Kafka publish, Processing consume, Scanner retry success가 서로 다른 시점에 재개되었다. 최종 두 sample에서 Kafka lag 0, Redis group lag 0, PEL 0, retry remaining 0, MySQL 820이 연속 확인되었고 manifest reconciliation도 820/820이었다.
- **INT:** 이 run의 Recovery Complete 설명은 broker start가 아니라 flow 재개, backlog drain, identity reconciliation이 함께 성립한 데 근거한다.
- **Non-claim:** 동일 흐름이 모든 failure mode에서 제한 시간 안에 수렴한다는 보장은 아니다.

## 11. Redis PEL, Redelivery, XACK의 의미

Redis consumer-group lifecycle은 다음과 같다.

```text
XREADGROUP에 대응하는 group read
→ consumer에게 entry 전달
→ PEL에 미확인 상태로 기록
→ Worker의 mapping / MySQL persistence / failure classification
→ 허용 가능한 terminal 처리 뒤 XACK
→ 해당 group의 PEL에서 제거
```

Redis 공식 의미론에서 `XREADGROUP`은 전달했지만 아직 acknowledge하지 않은 message를 PEL로 추적한다. `XPENDING`은 이 목록과 owner·idle·delivery 정보를 관측한다. 오래 idle한 pending entry는 `XCLAIM` 계열의 claim 의미론으로 다른 consumer 또는 재기동한 consumer가 소유권을 가져와 처리할 수 있으며 delivery counter가 증가할 수 있다. `XACK`은 해당 consumer group의 PEL에서 entry를 제거한다.

BIP Worker는 이 lifecycle을 다음처럼 구체화한다.

- 새 entry를 group consumer 이름으로 읽는다.
- mapping failure는 Redis DLQ 적재가 성공한 뒤 ACK한다.
- MySQL insert 성공은 ACK 대상이 된다.
- 이미 저장된 `internalBarcodeId` 또는 `originalBarcode`는 safe duplicate로 분류하여 ACK 대상이 된다.
- DLQ 적재가 실패하면 원본 ACK를 보류한다.
- 처리 예외로 ACK되지 않은 entry는 pending에 남고 이후 claim/reprocessing 대상이 될 수 있다.

`XACK`의 책임은 Redis consumer group의 미확인 추적을 끝내는 것이다. `XACK` 자체가 MySQL transaction의 정확성, field 값의 business correctness 또는 end-to-end reconciliation을 증명하지 않는다. 그 의미는 Worker가 저장소 구현상 ACK 가능한 terminal branch로 분류했다는 데 제한된다.

## 12. 종단 간 조정(End-to-end Reconciliation)

소비자 지연(Consumer Lag)은 Kafka log end와 consumer group progress 사이의 전송 계층 backlog를 나타내는 지표다. Kafka 공식 monitoring 문서도 lag를 consumer가 producer보다 뒤처진 message 수로 다룬다. 이 지표는 중요하지만 관측 범위가 Kafka consumer boundary에서 끝난다.

따라서 다음 추론은 성립하지 않는다.

```text
broker available
→ 반드시 모든 이전 send 완료

Kafka consumer lag = 0
→ 반드시 Redis PEL = 0
→ 반드시 MySQL에 모든 logical identity 저장
→ 반드시 final duplicate / missing / unaccounted = 0
```

BIP-FR-001에서 종단 간 조정은 generated manifest 820건을 final MySQL set과 대조하고, 동시에 Scanner retry remaining, Kafka lag, Redis group lag, PEL, DLQ, DLT, unaccounted를 확인한 결과다.

```text
Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

이 식의 `pending 0`은 terminal reconciliation에서 설명되지 않은 미완료 경로가 없었다는 run-level 결과다. Redis PEL 하나와 동의어가 아니다. MR에는 Scanner retry remaining 0, Kafka lag 0, Redis group lag 0, Redis PEL 0이 별도 값으로 존재한다.

## 13. BIP-FR-001 Causal Walkthrough: 820 → 1,235 → 820

### 13.1 820 logical events가 생성됨

Material Run은 서로 겹치지 않는 `scanTimeMs` range로 healthy 300, Kafka unavailable 220, post-recovery 300 events를 생성했다. 여기서 820은 business input identity 수다.

### 13.2 Kafka unavailable 동안 confirmation uncertainty가 발생함

Ingest는 broker connection failure를 기록했고, 5초 안에 batch Future 완료를 확인하지 못한 index를 Scanner에 반환했다. 원래 Future는 취소되지 않았다. 따라서 “HTTP 응답 시점에 미확인”과 “Kafka append의 최종 실패”가 분리되었다.

### 13.3 별도 fallback / retry attempt가 transport를 증폭함

Scanner는 failed index를 `/ingest/barcode`로 다시 보냈고, single 실패를 memory retry queue에 넣어 다시 요청했다. HTTP client 자동 재실행도 MR log에 나타났다. 각 별도 Ingest request는 새로운 `KafkaTemplate.send(...)`를 만들 수 있었다.

Broker recovery 후 원래 background send와 별도 attempt가 함께 완료되면서 Kafka에는 1,235 records가 남았다.

```text
1,235 transport records
= 820 logical events
+ 415 retry-induced duplicate records
```

이는 Kafka가 415건을 자의적으로 생성한 것이 아니라, 같은 logical identity를 담은 여러 application send attempt가 성공한 결과로 해석된다.

### 13.4 Redis Lua가 transport duplicate를 contain함

Processing은 Kafka 1,235 records를 모두 수신했다. 최초 original barcode는 Lua script에서 Redis Stream entry와 duplicate marker를 원자적으로 생성했다. 같은 key의 이후 415 records는 duplicate로 반환되어 새 Stream entry를 만들지 않았다. Redis Stream length는 820으로 수렴했다.

### 13.5 Worker idempotency와 MySQL uniqueness가 persistence duplicate를 방어함

Stream의 820 unique entries는 consumer group을 통해 Worker로 전달되었다. Worker는 성공 또는 safe duplicate terminal branch 뒤 ACK하도록 구현되어 있고, MySQL은 `internalBarcodeId`와 `originalBarcode`를 각각 unique하게 제한한다. 이 run의 최종 MySQL rows와 두 identity distinct count는 모두 820이었다.

### 13.6 Terminal reconciliation이 최종 상태를 설명함

마지막 두 sample에서 Kafka lag, Redis group lag, PEL, retry remaining은 0이었고 DLQ/DLT도 0이었다. Manifest의 820 logical identities는 MySQL 820과 정확히 일치했으며 final duplicate와 unaccounted는 0이었다.

따라서 `820 → 1,235 → 820`은 모순이 아니다. 중간의 1,235는 transport attempt의 수이고, 양 끝의 820은 각각 generated logical identity와 converged persisted business identity의 수다.

## 14. 보장과 비보장(Guarantees and Non-guarantees)

### 이 실행에서 확인된 것

- BIP-FR-001 bounded run에서 generated unique event는 820, Kafka record는 1,235, Processing duplicate는 415였다.
- 별도 fallback/retry attempt와 미취소 background Future가 함께 성공할 수 있는 구현 경계가 존재한다.
- 같은 run에서 Redis Lua dedupe 결과는 new 820 / duplicate 415였고 Stream length는 820이었다.
- MySQL은 820 unique rows로 수렴했고 final duplicate, DLQ, DLT, pending, unaccounted는 모두 0이었다.
- Component Recovery 뒤 flow recovery, backlog drain, terminal reconciliation이 모두 관측되었다.

### 이 실행이 입증하지 않는 것

- timeout 또는 HTTP 실패가 Kafka storage failure나 record absence를 입증하지 않는다.
- Kafka record count가 logical event count와 같다는 규칙은 없다.
- Kafka가 원인 없이 415 records를 복제했다고 입증하지 않는다.
- retry가 항상 duplicate를 만들거나 항상 loss를 방지한다고 입증하지 않는다.
- transport duplicate가 final business duplicate와 같지 않다.
- BIP가 end-to-end exactly-once를 보장하지 않는다.
- Redis Lua atomicity가 Kafka, Redis, MySQL을 하나의 transaction으로 만들지 않는다.
- PEL은 Redis Stream backlog의 일부이며, 전체 시스템 backlog를 대표하지 않는다.
- PEL 0, consumer lag 0 또는 broker availability 하나만으로 Recovery Complete를 입증하지 않는다.
- `XACK`은 MySQL transaction 또는 business correctness의 독립 증거가 아니다.
- MySQL unique constraint는 모든 business correctness나 completeness를 입증하지 않는다.
- DLQ/DLT 0은 이 run의 결과이며 다른 실행에서도 항상 0이라는 보장이 아니다.
- 이 run은 모든 failure mode에서 lossless behavior를 보장하지 않는다.

## 15. References

### 15.1 Material Run Evidence

- [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md) — `Material Failure Run — 20260829T073503Z` 실행 기록과 verified claim boundary
- [22-backlog-drain-observation.txt](./evidence/20260829T073503Z/22-backlog-drain-observation.txt) — 연속 terminal sample과 backlog convergence
- [23-scanner-material-logs.txt](./evidence/20260829T073503Z/23-scanner-material-logs.txt) — fallback, HTTP client 재실행, retry queue와 drain log
- [24-ingest-material-logs.txt](./evidence/20260829T073503Z/24-ingest-material-logs.txt) — confirmation timeout과 recovery 후 send completion log
- [25-processing-material-logs.txt](./evidence/20260829T073503Z/25-processing-material-logs.txt) — Kafka receive와 Redis duplicate 판정 log
- [26-worker-1-material-logs.txt](./evidence/20260829T073503Z/26-worker-1-material-logs.txt), [27-worker-2-material-logs.txt](./evidence/20260829T073503Z/27-worker-2-material-logs.txt) — Redis Stream read, persistence, ACK log
- [29-detect-impact-recovery-summary.txt](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt) — 820 input, 1,235 received, new 820, duplicate 415 및 recovery timeline
- [30-final-event-reconciliation.txt](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) — manifest, Kafka offset, Redis, MySQL, DLQ/DLT, pending 최종 조정

### 15.2 Repository Implementation

- [BarcodeIngestController.java](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/controller/BarcodeIngestController.java) — 5초 confirmation wait, non-cancelled Future, HTTP response mapping
- [BarcodeProducer.java](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/service/BarcodeProducer.java), [application.yml](../../../../barcode-ingest-service/src/main/resources/application.yml) — `KafkaTemplate.send(...)`, callback, producer configuration
- [ApiGatewayTransmitter.java](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/ApiGatewayTransmitter.java), [FailureRetryService.java](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/FailureRetryService.java) — batch fallback, separate single request, memory retry queue
- [BarcodeEventConsumer.java](../../../../barcode-processing-service/src/main/java/com/barcode/barcode_processing_service/service/BarcodeEventConsumer.java), [dedupe-and-publish.lua](../../../../barcode-processing-service/src/main/resources/scripts/dedupe-and-publish.lua), [KafkaConfig.java](../../../../barcode-processing-service/src/main/java/com/barcode/barcode_processing_service/config/KafkaConfig.java) — Kafka consume, Redis Lua dedupe, error propagation과 DLT recovery
- [RedisStreamConsumer.java](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/service/RedisStreamConsumer.java) — group read, pending claim, persistence result classification, safe duplicate ACK
- [BarcodeRepositoryImpl.java](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/repository/BarcodeRepositoryImpl.java), [BarcodeEntity.java](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/entity/BarcodeEntity.java) — transactional batch insert와 MySQL unique constraint

### 15.3 Authoritative External Semantics

- Apache Kafka, [Message Delivery Semantics](https://kafka.apache.org/43/design/design/#message-delivery-semantics) — publish acknowledgment uncertainty, at-least-once consumption, external-system exactly-once boundary
- Apache Kafka, [Producer Configs](https://kafka.apache.org/43/configuration/producer-configs/) — `retries`, `delivery.timeout.ms`, `enable.idempotence`, `acks`
- Apache Kafka, [Monitoring](https://kafka.apache.org/43/operations/monitoring/) — consumer lag의 관측 책임
- Redis, [Scripting with Lua](https://redis.io/docs/latest/develop/programmability/eval-intro/) — Redis script atomic execution
- Redis, [`XREADGROUP`](https://redis.io/docs/latest/commands/xreadgroup/) — consumer-group delivery와 PEL 등록
- Redis, [`XPENDING`](https://redis.io/docs/latest/commands/xpending/) — pending entry 관측과 recovery 의미
- Redis, [`XCLAIM`](https://redis.io/docs/latest/commands/xclaim/) — idle pending entry claim과 redelivery
- Redis, [`XACK`](https://redis.io/docs/latest/commands/xack/) — consumer-group acknowledgment와 PEL 제거
