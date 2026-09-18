# BIP-FR-001 장애 시나리오 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: BIP-FR-001을 직접 수행하지 않은 Java/Spring 개발자
> 기준 실행: Material Run `20260829T073503Z`

## 한눈에 보기

BIP-FR-001은 바코드 입력이 계속되는 동안 Kafka Broker 하나를 의도적으로 중단하고, 애플리케이션이 전송 실패를 어떻게 처리하는지 검증한 시나리오다.

```text
논리 입력                    820
Kafka transport records    1,235
재시도로 인한 추가 전송       415
Processing unique             820
MySQL unique                  820
DLQ / DLT / pending             0
unaccounted                     0
```

이 결과가 의미하는 것은 “Kafka 장애 중 모든 데이터가 Kafka에 안전하게 보존됐다”가 아니다. Kafka가 중단된 동안 입력은 Scanner와 Ingest 프로세스의 여러 JVM 메모리 영역에 머물렀다. Kafka가 복구된 뒤 원래 전송과 재시도 전송이 함께 성공하면서 동일한 논리 이벤트가 Kafka에 여러 번 기록됐다. Processing은 Redis 기반 중복 제거를 적용해 최종적으로 820개의 고유 이벤트만 Redis Stream과 MySQL에 전달했다.

이 시나리오에서는 Scanner 프로세스가 종료되지 않았고 재시도 큐도 포화되지 않았다. JVM 재시작이나 큐 초과 상황에서 입력을 보존할 수 있다는 사실은 검증하지 않았다.

## 무엇이 실패했는가

직접 재현한 장애는 다음과 같다.

```text
활성 synthetic scan traffic
→ 단일 Kafka Container stop
→ Kafka Broker 57초 unavailable
→ 동일 Kafka Container start
```

최초로 확인된 비정상 경계는 `barcode-ingest-service → Kafka Broker` 구간이다. Kafka가 멈추자 Ingest의 Kafka Producer가 Broker와 연결하지 못했다. 전송 완료를 기다리던 요청은 제한 시간 안에 성공을 확인하지 못했고, Scanner는 해당 이벤트를 재전송 대상으로 분류했다.

Redis와 MySQL이 직접 실패한 것은 아니다. Kafka 뒤쪽에 있었기 때문에 새로운 이벤트가 도착하지 않은 상태였다.

## 전체 데이터 흐름

```text
바코드 입력
  ↓
BarcodeController
  ↓
BarcodeBatchSender의 메모리 버퍼
  ↓
ApiGatewayTransmitter
  ↓ HTTP batch
BarcodeIngestController
  ↓
BarcodeProducer / KafkaTemplate
  ↓
Kafka barcode-events
  ↓
BarcodeEventConsumer
  ↓
Redis 원자적 중복 제거와 Stream 발행
  ↓
RedisStreamConsumer
  ↓
MySQL barcodes
```

Kafka 장애가 발생하면 Scanner와 Ingest 사이에 별도 경로가 활성화된다.

```text
Kafka 전송 확인 실패
  ↓
Ingest가 실패 인덱스 또는 HTTP 503 반환
  ↓
Scanner의 FailureRetryService 호출
  ↓
건별 전송 실패
  ↓
Scanner JVM 재시도 큐 적재
  ↓
5초 뒤 재시도
```

## Scanner의 입력 수락

외부 입력은 `BarcodeController.receiveBarcode()`로 들어온다. 이 메서드는 `BarcodeBatchSender.addBarcodeToBuffer()`를 호출한 뒤 즉시 HTTP `200`을 반환한다.

```text
HTTP 200
= Scanner 메모리 버퍼가 요청을 받아들임

HTTP 200
≠ Kafka 저장 완료
≠ MySQL 저장 완료
```

`BarcodeBatchSender`의 초기 버퍼는 JVM 메모리의 `LinkedBlockingQueue`다. 큐 크기가 배치 임계값에 도달하면 즉시 전송하고, 임계값에 도달하지 않아도 1초마다 전송을 시도한다. 이 초기 버퍼는 영속 저장소가 아니므로 Scanner 프로세스가 종료되면 남아 있던 데이터는 소실된다.

## FR-001 역사 상태의 MySQL 경계

FR-001 역사 상태의 `barcode-scanner-service`에는 MySQL 저장 기능이 없다. Scanner의 `build.gradle`에는 JDBC, JPA 또는 MySQL Driver 의존성이 없고 `application.yml`에도 DataSource 설정이 없다.

이 시나리오의 MySQL은 Scanner 로컬 저장소가 아니라 downstream 최종 저장소다.

```text
Scanner
→ Ingest
→ Kafka
→ Processing
→ Redis Stream
→ Persistence Worker
→ MySQL
```

따라서 Kafka 장애 시 Scanner가 입력을 MySQL에 임시 보존했다고 설명하면 안 된다.

## Scanner에서 Ingest로 전송

`ApiGatewayTransmitter.transmitBatch()`는 Scanner 배치를 `POST /ingest/barcodes`로 보낸다. `BarcodeIngestController.ingestBarcodes()`는 각 이벤트에 대해 Kafka 전송 Future를 만들고 최대 5초간 완료를 기다린다.

- 모두 확인됨: HTTP `200`
- 일부가 확인되지 않음: HTTP `207 Multi-Status`
- 실패한 인덱스: Scanner의 건별 전송 경로로 이동

5초 타임아웃은 원래 Kafka 전송을 취소하지 않는다.

```text
5초 안에 확인하지 못함
≠ Kafka 전송이 확정적으로 실패함
```

Ingest의 원래 Kafka 전송 Future는 백그라운드에서 계속 살아 있을 수 있다. Kafka가 복구되면 이 전송이 나중에 성공할 가능성이 있다.

## 애플리케이션 재시도 큐

Scanner는 실패한 이벤트를 `POST /ingest/barcode`로 다시 보낸다. Ingest는 건별 Kafka 전송 완료도 최대 5초간 기다리고, 확인하지 못하면 HTTP `503`을 반환한다.

`FailureRetryService.sendWithRetry()`는 HTTP 전송 실패를 `ConcurrentLinkedQueue<BarcodeRequest>`에 넣는다.

- JVM 메모리에만 존재한다.
- 5초마다 소비된다.
- 한 번의 실행에서는 시작 시점의 큐 크기만큼만 처리한다.
- 첫 연속 실패가 발생하면 다시 큐에 넣고 다음 주기까지 기다린다.
- 설정상 최대 크기는 `10,000`이다.
- 큐가 가득 찬 것으로 판단되면 이벤트를 로그에 남기고 버린다.
- Scanner 프로세스가 재시작되면 큐 내용은 소실된다.

코드는 `size()` 확인과 `offer()`를 별도 연산으로 수행한다. 여러 스레드가 동시에 적재하는 상황에서 `10,000`은 엄격한 원자적 상한이라기보다 애플리케이션이 의도한 보호 한계에 가깝다.

## 장애 중 데이터가 있었던 위치

“장애 중 220건이 모두 재시도 큐에 있었다”고 설명하면 정확하지 않다.

| 위치 | 의미 | 영속성 |
|---|---|---|
| `BarcodeBatchSender.buffer` | 아직 배치 전송을 시작하지 않은 입력 | JVM 메모리 |
| `ApiGatewayTransmitter`의 배치 객체 | 비동기 HTTP 전송 중인 입력 | JVM 메모리 |
| Ingest HTTP 요청 또는 Future | Kafka 결과를 기다리는 입력 | JVM 메모리 |
| Kafka Producer 내부 상태 | Broker 연결·재시도·확인을 기다리는 전송 | Kafka Client 메모리 |
| `FailureRetryService.failedQueue` | 다음 주기를 기다리는 입력 | JVM 메모리 |
| Kafka | Broker 복구 후 실제 기록된 이벤트 | Kafka Storage |

Material Run의 직접 관측치는 다음과 같다.

```text
장애 구간 논리 입력               220
실패로 분류된 배치 이벤트          220
명시적 재시도 큐 적재               90
최대 관측 재시도 큐 크기            89
최종 재시도 큐 잔량                  0
```

220건의 모든 이벤트가 특정 순간에 `failedQueue` 안에 있었다는 Evidence는 없다. 일부는 원래 Kafka 전송 Future, HTTP 호출, Scanner 배치 처리 또는 Kafka Producer 내부 상태에서 복구를 기다렸고 일부가 명시적 재시도 큐까지 도달했다. 각 이벤트가 어느 메모리 위치에 얼마나 오래 있었는지를 개별적으로 추적한 Evidence는 없다.

## 재시도 계층의 구분

### Kafka Client 재시도

Ingest Producer에는 `acks=all`, `retries=3`, `max.block.ms=5000`이 설정돼 있다. Kafka Client 수준의 재시도는 Scanner 재시도 큐와 별개다.

### Scanner 애플리케이션 재시도

`FailureRetryService`가 `@Scheduled`와 JVM Queue로 직접 구현한 애플리케이션 수준 재시도다. Spring Retry를 사용한 선언적 재시도가 아니다.

### HTTP Client 자동 재실행

실행 로그에서는 HTTP Client 자동 재실행도 관측됐다. 다만 415개의 추가 Kafka Record를 원래 Future, 명시적 fallback, scheduled retry, HTTP Client 재실행과 Kafka Client 내부 재시도로 완전히 분해한 Evidence는 없다.

### Kafka Consumer 처리 재시도

Processing의 `BarcodeEventConsumer`는 처리 예외를 삼키지 않는다. 예외가 Listener Container까지 전달돼 오프셋이 커밋되지 않도록 하고 Spring Kafka의 Consumer 오류 처리 경로가 재소비를 담당한다. 이 경로는 Scanner 입력 보존 재시도와 다른 책임이다.

## Kafka 복구 후 경로

Kafka Container는 같은 identity와 저장 상태를 유지한 채 다시 시작됐다.

```text
07:46:32Z      Kafka start 시작
07:46:48.405Z 첫 Kafka publish 성공
07:46:48.823Z 첫 Processing consume
07:46:49.398Z 첫 Scanner scheduled retry 성공
07:46:50Z      Broker probe 완료
07:46:57.034Z Scanner retry queue 0
```

복구 후 Kafka Producer 내부에서 기다리던 원래 전송, Scanner의 건별 fallback, scheduled retry와 신규 입력이 함께 진행됐다. 이 때문에 논리 입력보다 많은 Kafka Record가 생성됐다.

## 820건이 1,235건이 된 이유

```text
정상 구간          300
Kafka 장애 구간    220
복구 이후          300
----------------------
논리 입력 합계      820
```

```text
Kafka records 1,235
= logical events 820
+ retry-induced transport duplicates 415
```

전송 결과가 불확실한 상태에서 Scanner가 같은 논리 이벤트를 다시 전송했고, Kafka 복구 후 원래 전송과 재전송이 모두 성공할 수 있었다. 이는 최소 한 번(At-least-once)에 가까운 전달 특성이다.

## 중복 제거와 MySQL 수렴

`BarcodeEventConsumer`는 Redis Lua Script로 `barcode:processed:{originalBarcode}` 중복 키 확인, 고유 이벤트의 Redis Stream `XADD`, 중복 표시 키 저장과 7일 TTL 적용을 하나의 Redis 원자 실행으로 처리한다.

```text
Processing received       1,235
Processing new              820
Processing duplicate        415
Redis Stream length         820
```

Persistence Worker는 Redis Stream의 이벤트를 MySQL에 저장한다. `barcodes` 테이블은 `internalBarcodeId`와 `originalBarcode`에 고유 제약을 둔다. Redis 중복 제거가 주된 수렴 지점이고 MySQL 고유 제약은 최종 저장 경계의 추가 방어선이다.

```text
MySQL rows                     820
MySQL distinct internal ID     820
MySQL distinct original code   820
MySQL distinct scan time       820
```

## 복구 완료 조건

Kafka Process가 다시 실행됐다는 사실만으로 복구 완료를 선언하지 않았다.

1. **Component Recovery:** 동일 Kafka Container와 Topic probe 응답
2. **Flow Recovery:** Kafka publish, Processing consume, Scanner retry와 downstream 진행
3. **Backlog Drain:** retry, Kafka lag, Redis lag·PEL, DLQ·DLT 수렴
4. **End-to-end Reconciliation:** generated identity와 terminal identity 집합 대조

```text
Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

## 직접 확인된 사실과 해석

### 직접 확인된 사실

- 활성 입력 중 Kafka Container가 57초 동안 unavailable했다.
- Ingest에서 Kafka 연결 실패와 전송 확인 실패가 발생했다.
- Scanner에서 batch fallback과 재시도 큐 적재가 발생했다.
- 장애 중 Processing과 Worker의 신규 진행은 0이었다.
- 재시도 큐 최대 관측값은 89였다.
- Kafka 복구 후 publish, consume과 scheduled retry가 재개됐다.
- Kafka에 1,235개 Record가 기록됐다.
- Processing은 820개를 new, 415개를 duplicate로 분류했다.
- Redis Stream과 MySQL은 820개 고유 이벤트로 수렴했다.
- DLQ, DLT, pending과 unaccounted는 0이었다.
- FR-001 Scanner 서비스에는 MySQL 영속화 기능이 없었다.

### Engineering Interpretation

- Kafka 장애 중 입력은 하나의 큐가 아니라 여러 JVM 내부 상태에 분산돼 있었다.
- 전송 결과의 불확실성과 애플리케이션 재시도가 Kafka Record 증폭의 핵심 조건이었다.
- 손실 회피를 위한 재시도 정책은 중복 가능성을 허용하고 downstream 멱등성에 의존한다.
- Redis Lua Script가 이 실행의 주된 중복 수렴 지점이었다.
- Scanner의 HTTP `200`은 내구성 있는 수락 확인으로 해석할 수 없다.

## 같은 장애 효과를 만들 수 있지만 검증하지 않은 원인

- Scanner 또는 Ingest와 Kafka 사이의 Network 단절
- DNS 또는 Service Discovery 오류
- Firewall 또는 보안 정책 오류
- Kafka Broker 과부하
- 인증·인가 설정 오류
- Kafka Metadata 획득 지연
- Producer Buffer 고갈
- TLS 또는 인증서 오류

같은 오류 메시지가 보인다는 이유만으로 동일한 원인이라고 판단해서는 안 된다.

## 검증하지 않은 사항

- Scanner 프로세스 재시작 후 입력 보존
- Scanner 로컬 PC 전원 장애
- 초기 배치 버퍼의 포화
- 재시도 큐 10,000건 초과와 Drop 복구
- JVM Memory 부족
- 장시간 Kafka 장애
- Network Partition
- Kafka Storage 손실과 Container 재생성
- Replicated Kafka HA
- Redis 또는 MySQL 동시 장애
- Production traffic 규모와 SLA·RTO·RPO
- 일반적인 End-to-end exactly-once 보장

## 관련 소스

- `BarcodeController.receiveBarcode()`
- `BarcodeBatchSender.addBarcodeToBuffer()`
- `ApiGatewayTransmitter.transmitBatch()`
- `FailureRetryService.sendWithRetry()`
- `FailureRetryService.retryFailedRequests()`
- `BarcodeIngestController.ingestBarcodes()`
- `BarcodeIngestController.ingestBarcode()`
- `BarcodeProducer.sendBarcodeEvent()`
- `BarcodeEventConsumer.consumeBarcodeEvent()`
- `dedupe-and-publish.lua`
- `RedisStreamConsumer.saveWithRetry()`
- `BarcodeEntity`

## 관련 검증 자료

- [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)
- [TECHNICAL-REPORT.md](./TECHNICAL-REPORT.md)
- [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md)
- [Fault·Recovery Timeline](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt)
- [Backlog Drain Observation](./evidence/20260829T073503Z/22-backlog-drain-observation.txt)
- [Detect·Impact·Recovery Summary](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt)
- [Final Event Reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt)
