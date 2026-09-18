# BIP-FR-001 인간 개발자 장애 대응 가이드

> 상태: `FINAL — HUMAN CONFIRMED`
> Scenario: Kafka Broker Unavailable During Active Scan
> 문서 책임: 공통 장애 대응 역량, Kafka ingress unavailable 메커니즘, BIP-FR-001 실행 Adapter를 하나의 독립 문서로 제공한다.

## 문서 구조

```text
1. 공통 장애 대응 핵심
   소스코드와 실행 환경을 자세히 몰라도 적용할 수 있는 기본 판단 방식

2. FR-001 장애 메커니즘
   Kafka ingress unavailable에서 특별히 알아야 하는 기술 지식

3. BIP 프로젝트 실행 Adapter
   현재 Repository에서 확인된 Service·Queue·Topic·복구 경계
```

FR-001부터 FR-005까지는 각 Scenario 문서가 독립적으로 읽힐 수 있도록 공통 내용을 의도적으로 포함한다. FR-005 완료 후 반복 내용과 Scenario별 차이를 비교해 공통 문서화 여부를 결정한다. FR-006은 장애 시나리오인지 기능 개선인지 확정될 때까지 이 비교 범위에서 제외한다.

# Part 1. 공통 장애 대응 핵심

## 1. 재시작보다 현재 상태 확인이 먼저다

장애 발생 직후 모든 Service를 재시작하면 최초 오류, 장애 전후 연결 상태, 종료 원인, 재시도 횟수, 처리되지 않은 입력과 최초 장애 경계를 보여주는 시간 관계를 잃을 수 있다.

```text
현재 상태 확인
→ 로그와 시간 보존
→ 최초 장애 경계 추정
→ 독립 조회로 검증
→ 영향 범위 계산
→ 복구 대상 결정
→ 최소 복구
→ 처리 흐름과 데이터 수렴 검증
```

## 2. 처음 기록할 정보

- 최초 증상 발견 UTC 시각과 마지막 정상 처리 시각
- 사용자 또는 Client가 경험한 증상
- 현재 입력 지속 여부
- 영향받을 가능성이 있는 입력 식별자 또는 시간 범위
- 관련 Application과 Middleware 상태
- 최근 배포·설정·인프라 변경
- 아직 실행하지 않은 복구 조치
- 현재 허용된 조회·실행 범위

여러 Service 로그를 비교하려면 시각을 가능하면 UTC로 통일한다.

## 3. Process와 Container 상태 확인

```bash
docker ps
docker compose ps --all
```

특정 Container 상태:

```bash
docker inspect \
  --format '{{json .State}}' \
  <container>
```

순간 자원 사용량:

```bash
docker stats --no-stream <container>
```

확인할 항목은 `running`·`exited`·`restarting`, Exit Code, `OOMKilled`, Restart Count, Health Check, CPU와 Memory다.

```text
Container running
≠ Application 정상
≠ Kafka 연결 정상
≠ 업무 처리 정상
```

## 4. 기동 중인 서비스 로그 확인

```bash
docker logs \
  --since 15m \
  --timestamps \
  --tail 1000 \
  <container>
```

```bash
docker compose logs \
  --since 15m \
  --timestamps \
  --tail 1000 \
  <service>
```

관련 Service를 함께 보면 시간 관계를 파악하기 쉽다.

```bash
docker compose logs \
  --since 15m \
  --timestamps \
  <producer-service> \
  <consumer-service>
```

실시간 확인은 기존 로그를 보존한 뒤 수행한다.

```bash
docker logs --since 5m --timestamps --follow <container>
```

Kubernetes에서는 `kubectl get pods`, `kubectl logs --since`, `kubectl logs --previous`, `kubectl describe pod`를 같은 목적으로 사용한다. systemd 환경에서는 다음 형태를 사용한다.

```bash
journalctl -u <service> --since "-15 min" -o short-iso
```

도구는 달라도 목적은 장애 전후의 상태와 로그를 같은 시간축으로 보존하는 것이다.

## 5. 최초 오류와 연쇄 오류 구분

```text
Kafka 연결 실패
→ Producer 전송 확인 실패
→ HTTP 실패 응답
→ Application 재시도
→ Consumer 신규 처리 중단
→ Redis·DB 신규 처리 감소
```

다음 질문을 사용한다.

1. 같은 시간대에서 가장 먼저 발생한 오류는 무엇인가
2. 오류 직전 마지막 성공 작업은 무엇인가
3. 어느 경계까지 정상이고 어느 경계부터 실패하는가
4. 여러 Client가 동시에 같은 의존성 오류를 기록하는가
5. 일정한 간격의 재시도가 있는가
6. 복구 후 어떤 성공 신호가 먼저 돌아오는가

## 6. Kafka 상태의 독립 확인

Topic과 Partition Metadata:

```bash
kafka-topics \
  --bootstrap-server <broker:port> \
  --describe \
  --topic <topic>
```

Consumer Group:

```bash
kafka-consumer-groups \
  --bootstrap-server <broker:port> \
  --describe \
  --group <consumer-group>
```

기본 TCP 연결 확인:

```bash
nc -vz <host> <port>
```

TCP 연결 성공은 Kafka Protocol, 인증과 Produce 성공을 보장하지 않는다.

### Kafka CLI 기본 해석

Topic 조회에서는 Broker가 Metadata 요청에 응답하는지, Topic·Partition·Leader·Replica·ISR 상태가 예상과 같은지 확인한다.

Consumer Group 조회의 주요 값은 다음과 같다.

- `CURRENT-OFFSET`: Consumer Group이 처리한 위치
- `LOG-END-OFFSET`: Partition에 기록된 최신 위치
- `LAG`: 아직 처리하지 않은 Record 수

Lag 증가는 Consumer 지연, Downstream 저장소 지연, 입력 급증, Rebalance와 Consumer 정지에서도 발생한다. Broker가 완전히 응답하지 않으면 최신 Lag 자체를 조회하지 못할 수 있다.

## 7. 최초 장애 경계 찾기

```text
입력 Client
→ Edge 또는 Scanner
→ Ingest API
→ Kafka Producer
→ Kafka Broker
→ Kafka Consumer
→ 내부 Queue·Stream
→ Worker
→ 최종 저장소
```

각 경계에서 다음을 반복한다.

```text
마지막으로 정상임을 확인한 경계는 어디인가?
처음으로 비정상임을 확인한 경계는 어디인가?
```

Kafka를 최초 장애 경계로 판단하려면 Application 생존, Producer 연결·전송 실패, 독립 Kafka Probe 실패, Consumer 진행 중단과 Downstream 자체 상태를 함께 본다. Application 로그 하나만으로 Kafka를 확정하지 않는다.

## 8. 영향 범위 계산

- Application이 받아들인 논리 입력
- 성공이 확인된 입력
- 성공 여부가 불확실한 입력
- 재시도 대상
- Kafka에 기록된 전송 Record
- Consumer가 처리한 Record
- 내부 Queue의 미완료 작업
- 최종 저장된 업무 식별자
- DLQ·DLT
- 설명되지 않은 입력

```text
논리 이벤트 수
≠ Kafka Record 수
```

재시도가 있으면 하나의 업무 입력이 여러 Kafka Record가 될 수 있다.

## 9. 최소 복구와 위험 조치

Kafka 관련 오류가 있다는 이유만으로 모든 Component를 재시작하지 않는다. Broker Process, Network·DNS, 인증·인가, Topic·Partition, Producer 자원, Consumer 지연, Downstream 장애와 복수 장애를 구분하고 확인된 최초 장애 경계에 한정한다.

원인 확인 전에 다음을 피한다.

- Topic 삭제 또는 재생성
- Consumer Offset Reset
- Kafka Data Directory 또는 Volume 삭제
- Container 강제 재생성
- Retry Queue Purge
- DLQ·DLT 삭제
- Redis PEL 임의 제거 또는 수동 `XACK`
- DB 직접 수정
- 모든 Component 동시 재시작

## 10. 복구 완료의 네 단계

```text
Component Recovery
→ Flow Recovery
→ Backlog Drain
→ End-to-end Reconciliation
```

- **Component Recovery:** 실패한 Component가 다시 Protocol 요청에 응답한다.
- **Flow Recovery:** Producer부터 최종 저장소까지 새 Event가 다시 흐른다.
- **Backlog Drain:** Application Retry, Kafka Lag, 내부 Queue·PEL, DLQ·DLT와 저장 대기 작업이 수렴한다.
- **End-to-end Reconciliation:** 입력 식별자와 성공 저장·실패 격리·미완료·미설명 상태를 집합으로 대조한다.

```text
Generated logical identities
= Successfully persisted identities
+ DLQ·DLT identities
+ still-pending identities
+ unaccounted identities
```

```text
Component Healthy
≠ Flow Recovered

Flow Recovered
≠ Backlog Drained

Backlog Drained
≠ Data Reconciled
```

# Part 2. FR-001 장애 메커니즘

## 11. 전체 Kafka Ingress unavailable

```text
Scanner
→ Ingest
→ [Kafka unavailable]
→ Processing
→ Redis
→ MySQL
```

직접 재현한 원인은 단일 Kafka Container 중단이다. 운영에서는 Broker Crash, Host·Network·DNS·Firewall·인증 문제와 과도한 지연도 유사한 결과를 만들 수 있지만 FR-001이 모두 검증한 것은 아니다.

## 12. Application Timeout과 전송 결과

Ingest가 제한 시간 안에 Kafka 전송 성공을 확인하지 못해도 원래 Kafka Future가 계속 살아 있을 수 있다.

```text
Application timeout
≠ Kafka append 실패 확정
```

상위 Application이 같은 Event를 다시 보내면 원래 전송과 별도 재전송이 복구 후 모두 성공해 Transport Duplicate를 만들 수 있다.

## 13. 재시도의 Trade-off

재시도는 일시적 장애에서 입력 소실 위험을 낮추지만 중복 가능성을 만든다.

```text
Kafka Client Retry
≠ HTTP Client Retry
≠ Application Retry Queue
```

## 14. 장애 중 입력 위치

- 입력 Application의 배치 버퍼
- 비동기 HTTP 요청
- Ingest의 미완료 Kafka Future
- Kafka Producer 내부 Buffer
- Application Retry Queue

확인해야 할 질문:

- JVM Memory인가, 파일·DB·Redis에 영속화되는가
- Process 재시작 후 복구되는가
- Queue 상한과 초과 정책은 무엇인가
- 같은 입력을 어떤 Key로 식별하는가

## 15. Kafka 복구 후 중복 제거

Kafka가 복구되면 원래 Producer Future, HTTP Client 재실행, Application fallback, Scheduled Retry와 신규 입력이 함께 진행될 수 있다. 중복은 업무 식별자를 이해하는 계층에서 처리해야 하며 Kafka 전송 프로토콜이 서로 다른 Application Send를 하나의 업무 Event로 합칠 수 있다고 가정해서는 안 된다.

## 16. FR-001 복구 완료 조건

- 원래 또는 재시도 전송이 다시 성공한다.
- Processing Consumer가 진행한다.
- Application Retry Queue가 수렴한다.
- Kafka Consumer Lag와 내부 Queue·PEL이 수렴한다.
- Transport Duplicate가 식별되고 흡수된다.
- 최종 저장소가 논리 입력 식별자와 일치한다.
- Drop, Missing과 Unaccounted 입력이 없다.

# Part 3. BIP-FR-001 실행 Adapter

## 17. 실제 처리 경로

```text
BarcodeController
→ BarcodeBatchSender
→ ApiGatewayTransmitter
→ BarcodeIngestController
→ BarcodeProducer
→ Kafka barcode-events
→ BarcodeEventConsumer
→ Redis barcode:stream
→ RedisStreamConsumer
→ MySQL barcodes
```

## 18. 핵심 구현 특성

### Scanner 수락과 배치 버퍼

Scanner HTTP `200`은 메모리 버퍼 수락이며 Kafka 또는 MySQL 저장 완료가 아니다. `BarcodeBatchSender`는 JVM `LinkedBlockingQueue`를 사용하고 배치 크기 또는 1초 주기로 전송한다. Scanner Process 재시작 시 소실되며 Scanner MySQL 영속화는 없다.

### 재시도 Queue

`FailureRetryService`는 JVM `ConcurrentLinkedQueue`를 사용한다.

- 5초마다 재시도
- 설정상 최대 10,000건
- 포화 시 Drop 가능
- Process 재시작 시 소실

### Kafka Producer

- Topic: `barcode-events`
- `acks=all`
- `retries=3`
- `max.block.ms=5000`

Application 5초 확인 Timeout과 Kafka Producer의 최종 결과를 동일하게 보지 않는다.

### 중복 제거

Processing은 Redis Lua Script로 `originalBarcode` 중복 확인, 고유 Event의 Stream `XADD`와 7일 TTL 중복 표시를 원자적으로 수행한다. MySQL은 `internalBarcodeId`와 `originalBarcode`에 고유 제약을 둔다.

## 19. 실제 조회 대상

| 계층 | BIP-FR-001 대상 |
|---|---|
| Scanner | `scanner` |
| Ingest | `ingest` |
| Kafka | `kafka` |
| Processing | `processing` |
| Redis | `redis` |
| Persistence Worker | `worker-1`, `worker-2` |
| MySQL | `mysql` |
| Kafka Topic | `barcode-events` |
| Consumer Group | `barcode-processing-group` |
| Redis Stream | `barcode:stream` |
| Redis Consumer Group | `barcode-persistence-group` |
| Redis DLQ | `barcode:stream:dlq` |

## 20. BIP-FR-001 Read-only Probe

Kafka Topic:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec kafka kafka-topics \
  --bootstrap-server kafka:29092 \
  --describe \
  --topic barcode-events
```

Kafka Consumer Group:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec kafka kafka-consumer-groups \
  --bootstrap-server kafka:29092 \
  --describe \
  --group barcode-processing-group
```

Redis Group과 PEL:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec redis redis-cli XINFO GROUPS barcode:stream
```

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec redis redis-cli XPENDING \
  barcode:stream barcode-persistence-group
```

## 21. 승인된 로컬 복구

FR-001 Material Run에서는 중단됐지만 보존된 동일 Kafka Container를 한 번 시작했다.

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  start kafka
```

이 명령은 FR-001 로컬 검증 환경의 승인된 복구다. 다중 Broker, Kubernetes, Managed Kafka, Storage 손실, Network Partition과 Production Cluster에 일반화하지 않는다.

## 22. Material Run 결과

```text
정상 구간 논리 입력             300
Kafka 장애 구간 논리 입력        220
복구 이후 논리 입력              300
전체 논리 입력                   820

Kafka transport records        1,235
Transport duplicates             415
Redis Stream unique              820
MySQL unique                     820

DLQ                                0
DLT                                0
Pending                            0
Unaccounted                        0
```

명시적 Scanner Retry Queue 관측:

```text
Retry enqueue                     90
Maximum observed queue            89
Scheduled retry success           90
Final retry remaining              0
```

220건 전체가 특정 순간에 Retry Queue에 있었다는 Evidence는 없다. 입력은 Scanner Buffer, 비동기 HTTP, Ingest Future, Kafka Producer와 Retry Queue에 분산돼 있었다.

## 23. BIP-FR-001 복구 완료 판정

```text
동일 Kafka Container 시작
→ Kafka Topic Probe 성공
→ 첫 Kafka Publish 성공
→ 첫 Processing Consume
→ 첫 Scanner Retry 성공
→ Scanner Retry Queue 0
→ Kafka Consumer Lag 0
→ Redis Group Lag 0
→ Redis PEL 0
→ DLQ 0 / DLT 없음
→ MySQL unique 820
→ Missing·Extra·Final Duplicate·Unaccounted 0
```

```text
Kafka records 1,235
= logical events 820
+ retry-induced transport duplicates 415

Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

## 24. 적용 한계

- Scanner Process·PC 재시작 내구성
- Retry Queue 포화
- 장시간 Kafka 장애
- Broker Storage 손실과 Container 재생성
- Replicated Kafka HA와 Network Partition
- Production SLA·RTO·RPO
- 일반적인 Exactly-once 처리

## 관련 자료

- [SCENARIO-EXPLANATION.md](./SCENARIO-EXPLANATION.md)
- [OPERATIONAL-DIAGNOSTIC-GUIDE.md](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)
- [RUNBOOK.md](./RUNBOOK.md)
- [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md)
- [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)
- [TECHNICAL-REPORT.md](./TECHNICAL-REPORT.md)
- [Material Run Evidence](./evidence/20260829T073503Z/)
