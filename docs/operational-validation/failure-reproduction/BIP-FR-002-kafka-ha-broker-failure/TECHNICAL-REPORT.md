# BIP-FR-002 기술 보고서 — Kafka HA 단일 브로커 장애

## 1. 요약 결과

주 검증 실행 `BIP-FR-002-MR-20260902T053228Z`의 판정은 `STRICT PASS`다. 승인된 로컬 bounded traffic run에서 partition 1의 leader broker 2를 active traffic 도중 SIGKILL하자, 전용 KRaft controller가 broker 2를 fencing하고 장애 전 동기화 복제본 집합(In-sync Replicas, ISR)에 있던 broker 3을 clean leader로 선출했다. ISR이 3개에서 2개로 줄어든 상태에서도 `min.insync.replicas=2`와 producer `acks=all` 조건을 충족해 새 쓰기 확인, Kafka offset 증가와 downstream 처리가 재개됐다. broker 2만 같은 container와 volume으로 복구한 뒤 ISR 3, 복제 부족 파티션(Under-replicated Partition, URP) 0, unavailable partition 0으로 수렴했다.

실행 범위 결과는 다음과 같다.

```text
66 logical events
→ 75 application/Kafka send records
→ 9 duplicate logical identities detected
→ 66 MySQL unique business identities
```

9개 추가 record는 Kafka leader election이 저장된 record를 독립적으로 다시 보낸 증거가 아니다. 로그와 요청 경로를 대조한 결과 Scanner의 명시적 단건 폴백 7회와 HTTP client의 503 자동 재실행 2회가 추가 HTTP 요청을 만들었고, Ingest는 각 요청에 대해 `KafkaTemplate.send()`를 한 번 호출했다. Processing의 중복 제거(Deduplication)가 9개 중복 논리 식별자를 차단해 최종 비즈니스 중복은 0이었다.

최초 실행 `BIP-FR-002-MR-20260902T043510Z`도 폐기하지 않는다. Kafka 고가용성(High Availability, HA)·복구·정합성은 확인했지만 active traffic이 SIGKILL 201초 전에 끝나 엄격한 시간 조건을 증명하지 못했으므로 `Partial / Inconclusive Evidence`로 보존한다.

## 2. 장애 질문(Failure Question)

> `acks=all`, RF=3, `min.insync.replicas=2`, unclean leader election 비활성화 조건에서 ISR의 broker 하나가 active traffic 중 중단될 때, Kafka가 정합성 경계를 낮추지 않고 clean leader를 선출하여 새 생산과 소비를 재개하고, 같은 broker 복구 뒤 복제와 전체 파이프라인이 유실·미정 상태 없이 수렴하는가?

이 질문은 일반적인 Kafka 보증이 아니라 승인된 로컬 토폴로지, 특정 partition 매핑, bounded traffic과 단일 Material Run의 관측에 답한다.

## 3. 승인된 토폴로지와 검증 경계

```text
Scanner → Ingest → Kafka(RF=3) → Processing → Redis Streams → Worker → MySQL
                         ↑
                  KRaft controller 1개
```

| 경계 | 승인 조건 | 검증 의미 |
|---|---|---|
| Kafka 역할 | 전용 KRaft controller 1개 + broker-only 3개 | broker 실패와 controller 실패를 분리한다. controller HA는 범위 밖이다. |
| `barcode-events` | partitions 3, RF=3 | 각 partition replica가 broker 3개에 배치된다. |
| 쓰기 정합성 | `min.insync.replicas=2`, producer `acks=all` | ISR이 2개 이상일 때만 현재 ISR 전체의 확인을 받아 성공시킨다. |
| leader 안전성 | `unclean.leader.election.enable=false` | ISR 밖 replica를 가용성 목적으로 leader로 올리지 않는다. |
| 장애 영역 | partition 1 leader broker 2의 프로세스/container | controller, 다른 broker, 애플리케이션, Redis, MySQL, worker는 주입 대상이 아니다. |
| 복구 | broker 2만 기존 container와 기존 data volume으로 시작 | 저장 상태 삭제·교체 없이 catch-up과 재합류를 확인한다. |

사전 계약은 [REPRODUCTION-CONTRACT.md](./REPRODUCTION-CONTRACT.md)에 보존돼 있다.

## 4. 건전한 사전 조건

Strict Run은 장애 주입 전에 다음을 직접 확인했다.

- controller leader 100이 사용 가능하고 broker 1, 2, 3이 등록됨
- broker 3/3 healthy
- 모든 `barcode-events` partition의 ISR 크기 3, URP 0, unavailable partition 0
- RF=3, `min.insync.replicas=2`, unclean leader election 비활성화
- Ingest와 Processing에 broker 3개 bootstrap 주소 적용
- Ingest producer `acks=all`
- Kafka consumer lag 0, Redis group lag 0, pending 0, 실패 격리 큐(Dead Letter Queue, DLQ) 0, Kafka 실패 격리 토픽(Dead Letter Topic, DLT) offset 0
- 애플리케이션 health `UP`과 healthy mapping event의 end-to-end 진행

직접 근거는 [healthy preconditions](./evidence/BIP-FR-002-MR-20260902T053228Z/02-healthy-preconditions.txt)와 [before evidence](./evidence/BIP-FR-002-MR-20260902T053228Z/before/)다.

## 5. Material Run 이력과 증거 충분성

| Run | 관측 결과 | 증거 충분성(Evidence Sufficiency) |
|---|---|---|
| `BIP-FR-002-MR-20260902T043510Z` | clean leader 전이, ISR 저하/복구, broker DOWN 중 15건 새 쓰기, downstream 진행, generated/MySQL unique 91 일치 | active traffic 종료 `04:48:18Z`, SIGKILL `04:51:39Z`; 201초 불일치 때문에 시간 중첩 주장에는 불충분. `Partial / Inconclusive Evidence` |
| `BIP-FR-002-MR-20260902T053228Z` | active traffic `05:36:46–05:37:54Z` 내부인 `05:36:59Z`에 SIGKILL, 전체 인과 사슬과 최종 정합성 확인 | 계약의 시간 술어와 나머지 성공 기준을 충족. `STRICT PASS` |

최초 실행이 노출한 문제는 Kafka 동작 실패가 아니라 traffic loop와 승인·장애 명령 사이의 시간 오케스트레이션이었다. bounded rerun은 성공 기준을 바꾸지 않고 SIGKILL을 같은 traffic loop 안에 배치해 이 증거 공백만 닫았다. 상세 실행 이력은 [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)를 따른다.

## 6. Strict Run 인과 시간선

```text
active traffic 시작
→ partition 1 leader broker 2 SIGKILL
→ broker 2 fencing
→ clean leader 2 → 3
→ ISR 3 → 2
→ broker 2 DOWN 유지
→ acks=all 새 쓰기 성공
→ Kafka offset 증가
→ downstream 진행
→ 기존 volume의 broker 2 복구
→ ISR 2 → 3
→ URP 0 / unavailable 0
→ 실행 범위 정합성 확인
```

| UTC | 사건 | 직접 관측 |
|---|---|---|
| `05:36:46` | active traffic 시작 | 60개 active event 중 첫 요청 |
| `05:36:59` | SIGKILL | 대상 leader 2 재검증 후 broker 2 exit 137, OOM 아님 |
| `05:37:08.439` | fencing | controller log가 broker 2 fencing 기록 |
| `05:37:08.504` | leader 전이 | partition 1 leader `2 → 3`, leader epoch `2 → 3`, ISR `3,1,2 → 3,1` |
| `05:37:12.210` | 첫 post-kill 확인 | partition 1 offset 103 producer acknowledgment |
| `05:37:54.451` | 마지막 broker-down 확인 | partition 1 offset 161, broker 2는 계속 DOWN |
| `05:39:32` | broker 2 복구 시작 | 같은 container ID와 data volume 유지 |
| `05:39:35.305–05:39:36.143` | 등록·catch-up·unfence·ISR 합류 | ISR `3,1 → 3,1,2` |
| `05:39:47` | 복구 완료(Recovery Complete) | 두 회복 sample 뒤 ISR 3, URP 0, unavailable 0 |
| `05:43:04–05:43:09` | 최종 정합성과 terminal 확인 | 66 unique identity 일치, backlog 0 |

근거: [derived timeline and verdict](./evidence/BIP-FR-002-MR-20260902T053228Z/23-derived-timeline-and-verdict.txt).

## 7. Leader, follower와 ISR 동작

장애 직전 partition 1의 replica는 `2,3,1`, ISR은 `3,1,2`, leader는 broker 2였다. ISR은 leader의 로그를 허용 범위 안에서 따라잡은 replica 집합이다. broker 2가 SIGKILL된 뒤 controller는 이를 fencing했고, pre-failure ISR member인 broker 3이 새 leader가 됐다. 남은 broker 1은 follower로서 새 leader와 동기화된 상태를 유지했고 ISR은 `3,1`로 줄었다.

여기서 직접 증명된 것은 leader·ISR 상태와 controller/broker log의 전이다. producer와 consumer가 정확히 어떤 metadata refresh 요청을 몇 회 수행했는지 같은 client 내부 세부 동작은 별도 protocol capture가 없어 강한 추론으로만 다룬다.

## 8. Clean leader 선출과 쓰기 지속 조건

새 leader broker 3은 장애 전 ISR member였고 unclean leader election은 비활성화돼 있었다. 따라서 관측된 `2 → 3`은 ISR 밖의 뒤처진 replica를 승격한 것이 아닌 clean leader election이다.

`acks=all`은 RF의 모든 replica가 항상 살아 있어야 한다는 뜻이 아니다. 해당 시점의 leader가 현재 ISR 전체의 확인을 기다린다는 뜻이다. 이 실행에서는 broker 2가 빠진 뒤에도 ISR이 broker 3과 1의 두 개였고, 이는 `min.insync.replicas=2`를 정확히 충족했다. 따라서 새 leader가 두 ISR의 확인을 받은 쓰기는 성공할 수 있었다. 반대로 ISR이 1로 줄었다면 같은 설정에서 가용성을 위해 정합성 경계를 낮추지 않고 쓰기를 거부해야 한다. 그 반대 조건은 이번 실행에서 주입하거나 검증하지 않았다.

## 9. 애플리케이션에서 보인 장애 동작

SIGKILL 직후 leader 전이와 client 재연결 구간에서 Ingest의 5초 전송 확인 대기가 끝나지 않은 요청이 발생했다. 배치 endpoint는 실패 인덱스를 반환했고 Scanner는 그 항목을 단건 경로로 폴백했다. 단건 endpoint의 확인 실패는 HTTP 503으로 보였으며 HTTP client가 두 요청을 자동 재실행했다. 이후 새 leader에 대한 producer acknowledgment가 시작되고 Processing과 downstream이 진행했다.

최상위 traffic driver가 기록한 Scanner 응답 200은 Scanner가 요청을 수용했다는 경계이지, 각 Kafka write의 동기식 확인을 의미하지 않는다. Scanner에서 Ingest로 이어지는 비동기 전송·폴백 경계의 상태는 별도로 해석해야 한다.

## 10. 전송 중복: `66 → 75 → 66`

Strict Run의 실행 범위에는 mapping 1개, active 60개, post-recovery 5개로 총 66개의 고유 논리 이벤트가 있었다. partition 1의 기준 end offset 92가 최종 167이 됐으므로 application/Kafka send record는 75개다. Processing은 같은 논리 식별자의 중복 9개를 감지했다.

```text
66 logical events
+ 7 Scanner explicit single-request fallback attempts
+ 2 HTTP client automatic 503 re-executions
= 75 Kafka records

75 received records
→ 66 first logical identities
+ 9 duplicate identity detections
→ 66 final unique business results
```

이는 전송 계층의 중복과 비즈니스 계층의 고유 결과가 서로 다른 일관성 경계임을 보여준다. 전송 중복이 있었다는 사실은 프로젝트 결함이라는 판정도, 최종 데이터 중복이라는 뜻도 아니다. 이 실행에서 확인된 설계 책임은 확인 모호성 때문에 다시 제출될 수 있는 요청을 Processing dedupe가 논리 식별자 기준으로 흡수하는 것이다.

## 11. 재시도와 재전송 책임 경계

| 구성 요소 | 직접 확인한 책임 | 이 실행의 수량/결과 |
|---|---|---|
| Traffic driver | 생성 sequence마다 Scanner API를 한 번 호출한다. driver-level retry loop는 없다. | 고유 논리 이벤트 66개 |
| Scanner | 배치 확인 실패 항목을 단건 HTTP 요청으로 명시적으로 폴백한다. HTTP client는 503 두 건을 자동 재실행했다. | 명시적 폴백 7회 + 자동 재실행 2회 |
| Ingest | HTTP 요청마다 `KafkaTemplate.send()` 한 번. 최대 5초 동안 confirmation을 기다리지만 timeout 시 underlying Future를 취소하지 않는다. 별도 애플리케이션 Kafka retry loop는 확인되지 않았다. | 추가 HTTP 요청 9건이 추가 send 9건으로 이어짐 |
| Kafka Producer | repository 설정은 `acks=all`, `retries=3`이다. 실제 client 내부 retry 횟수와 모든 효과적 기본값은 캡처하지 않았다. | 내부 retry 횟수 미해결 |
| Processing | 75 record를 수신하고 66개 최초 논리 식별자와 9개 중복 식별자를 구분했다. | dedupe 후 downstream 고유 결과 66개 |

설정과 구현 경계는 [Ingest producer 설정](../../../../barcode-ingest-service/src/main/resources/application.yml), [Ingest controller](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/controller/BarcodeIngestController.java), [BarcodeProducer](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/service/BarcodeProducer.java), [Scanner transmitter](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/ApiGatewayTransmitter.java)에서 확인할 수 있다. 실행 중 관측은 [material window logs](./evidence/BIP-FR-002-MR-20260902T053228Z/down/01-material-window-application-logs.txt)에 보존돼 있다.

## 12. Kafka 독립 replay로 해석할 수 없는 이유

추가 record 9개는 요청 계층에서 수량과 identity가 닫힌다. Scanner의 단건 폴백 7회와 HTTP client 자동 재실행 2회의 합이 정확히 transport delta 9와 일치하며, 그 결과 Ingest가 동일 identity의 새 send를 수행한 로그와 Processing의 9개 중복 검출이 연결된다.

따라서 이 증거는 leader election 자체가 이미 처리된 저장 record를 독립적으로 replay했다는 해석을 지지하지 않는다.

Kafka client 내부에서 어떤 produce attempt가 재시도됐는지, SIGKILL 직전 특정 record가 old leader에 append됐지만 acknowledgment만 유실됐는지는 protocol-level 증거가 없어 미해결이다. 그러나 이 미해결 질문을 Kafka의 독립 replay로 바꿔 말할 수는 없다.

## 13. 중복 제거와 최종 비즈니스 정합성

Processing은 수신한 75개 record 중 9개에 대해 `Duplicate barcode detected`를 기록했고, Redis 기반 dedupe 경계가 이들을 downstream 신규 결과로 만들지 않았다. 최종 MySQL에는 실행 범위 고유 scan time 66개와 고유 barcode 66개가 있었고 business duplicate scan time과 barcode는 각각 0이었다.

```text
Generated unique 66
= MySQL unique 66
+ DLQ 0
+ DLT 0
+ Pending 0
+ Unaccounted 0

Missing 0
Extra 0
Business duplicate 0
```

이 결과는 이 run에서 application resend가 만든 중복을 식별자 기반 dedupe가 흡수했다는 직접 증거다. 일반적인 exactly-once 또는 모든 중복 원인에 대한 보증으로 확장하지 않는다.

## 14. 증거 분류별 결론

### 14.1 직접 증명(Directly Proven)

- active traffic `05:36:46–05:37:54Z`와 SIGKILL `05:36:59Z`의 시간 중첩
- `SEOUL-CENTER-PC-001 → partition 1 → leader broker 2` 런타임 매핑
- broker 2 exit 137, OOM 아님, controller fencing
- pre-failure ISR member broker 3의 clean leader 선출과 leader `2 → 3`, ISR `3 → 2`
- broker 2 DOWN 중 `acks=all` producer acknowledgment, partition offset 증가와 downstream 진행
- repository의 producer `acks=all`, `retries=3` 설정
- Scanner 폴백 7회, HTTP client 503 자동 재실행 2회, Ingest 요청당 단일 send 구현
- Processing의 75 record 수신 경계, 중복 9건 검출과 최종 unique 66건
- broker 2만 같은 container/volume으로 복구, catch-up·unfence·ISR 3 복원
- 최종 URP 0, unavailable 0, DLQ/DLT/pending/unaccounted/missing/extra/business duplicate 0

### 14.2 강한 추론(Strongly Inferred)

- producer와 consumer가 broker 실패 뒤 metadata를 갱신하고 새 leader/coordinator 경로로 전환한 세부 과정
- 사용된 Kafka client 버전 기본값에 따른 효과적 런타임 `enable.idempotence=true`
- runtime snapshot으로 직접 캡처하지 않은 producer timeout, max-in-flight 등 client 기본값

이 항목들은 관측 결과·버전 기본값과 일관되지만, 효과적 `ProducerConfig` dump나 protocol trace가 없으므로 직접 증명으로 승격하지 않는다.

### 14.3 미해결(Unresolved)

- SIGKILL 직전 특정 record가 old leader에 append된 뒤 acknowledgment만 유실됐는지 여부
- 정확한 Kafka producer 내부 retry 횟수
- producer ID, epoch, sequence의 wire-level 이력
- SIGKILL 순간 in-flight produce request의 request-level acknowledgment 모호성
- 일반적인 production failover latency

이 질문은 관측 범위를 넘지만, 계약상 필요한 상태 전이·새 쓰기·복구·정합성이 직접 확인됐으므로 승인된 `STRICT PASS`를 무효화하지 않는다.

## 15. 복구와 수렴

복구는 broker 2 하나에만 수행됐다. restart 전후 container ID와 `bip-fr-002-kafka-ha_kafka-broker-2-data` volume이 동일했고, 다른 broker·controller·애플리케이션·Redis·MySQL은 재시작하거나 상태를 조작하지 않았다.

broker 2는 controller 등록 후 뒤처진 replica를 catch-up하고 unfence됐으며 partition 1 ISR에 다시 합류했다. 복구 완료는 단순 `running` 상태가 아니라 다음을 함께 충족한 시점으로 판정했다.

- 모든 `barcode-events` partition ISR 크기 3
- URP 0, unavailable partition 0
- post-recovery event 5개 모두 HTTP 200 및 downstream 진행
- Kafka consumer lag 0, Redis group lag/PEL 0
- DLQ/DLT 0과 실행 범위 identity reconciliation 완료

근거: [restart](./evidence/BIP-FR-002-MR-20260902T053228Z/09-broker-restart.txt), [replica catch-up timeline](./evidence/BIP-FR-002-MR-20260902T053228Z/10-replica-catch-up-timeline.txt), [terminal convergence](./evidence/BIP-FR-002-MR-20260902T053228Z/final/22-terminal-convergence-sample.txt).

## 16. 최종 판정

Strict Run은 건전한 사전 조건, 단일 장애 영역, active traffic 시간 중첩, clean leader 선출, ISR 2 상태의 새 `acks=all` 쓰기와 downstream 진행, 같은 volume 복구, 복제 수렴, 실행 범위 정합성을 모두 충족했다. 최종 판정은 `STRICT PASS`다.

9개 transport duplicate는 설명되지 않은 데이터 이상이 아니다. application/HTTP resend 책임과 정확히 연결되고 Processing에서 검출·제거됐으며 최종 비즈니스 identity 집합이 일치한다. 따라서 transport duplicate의 존재만으로 이 시나리오를 결함이나 실패로 판정하지 않는다.

## 17. 최대 검증 주장

> 승인된 로컬 BIP-FR-002 토폴로지와 bounded traffic run에서, 단일 전용 KRaft controller가 유지되는 동안 active scan traffic과 시간적으로 겹쳐 partition 1의 leader broker 2를 SIGKILL했을 때, RF=3, `min.insync.replicas=2`, producer `acks=all`, unclean leader election 비활성화 경계 안에서 pre-failure ISR member인 broker 3이 새 leader가 됐다. broker 2가 down인 상태에서도 새 producer acknowledgments, partition offset 증가와 downstream 처리가 재개됐으며, broker 2를 기존 volume으로 복구한 뒤 ISR 3, URP 0, unavailable partition 0으로 수렴했다. 이 과정에서 66개 logical event가 75개 Kafka transport record를 만들었으나 9개 duplicate는 application/HTTP resend 경계에서 발생했고 Processing dedupe 후 66개 MySQL unique identity로 최종 reconciliation됐다.

이 주장은 Strict Run의 직접 증거와 해당 로컬 환경·버전·관측 시간에만 적용된다.

## 18. 명시적 비주장

이 보고서는 다음을 주장하지 않는다.

- 일반적인 정확히 한 번 처리(exactly-once) 보장
- 중복 없는 transport
- production 고가용성(High Availability, HA) 또는 서비스 수준 협약(Service Level Agreement, SLA)
- production 복구 시간 목표(Recovery Time Objective, RTO) 또는 복구 시점 목표(Recovery Point Objective, RPO)
- controller HA
- broker 2개 동시 실패 내성
- 네트워크 partition 동작
- storage 유실·손상·용량 고갈 내성
- 임의 Kafka topic·partition·replica 배치의 장애 내성
- old leader에서 SIGKILL 순간 이미 in-flight였던 특정 produce 요청의 성공·실패 보장
- 다른 Kafka/client 버전이나 infrastructure에서 동일한 동작
- Scanner, Processing, Redis, MySQL 또는 worker 장애가 결합된 복구
- 성능, capacity, failover 시간 또는 장시간 soak 보장

## 19. 운영적 의미

첫째, RF=3만으로 쓰기 가용성이 성립하지 않는다. `min.insync.replicas`, producer `acks`, unclean leader election, 다중 bootstrap과 실제 ISR 상태가 함께 경계를 만든다. 운영에서는 이 설정과 URP·unavailable partition·broker fencing 상태를 같은 관측 체계에서 확인해야 한다.

둘째, leader 전이 동안 “확인하지 못함”은 “확정 실패”와 다르다. Ingest의 5초 timeout이 underlying send를 취소하지 않으므로 상위 계층 재전송은 중복 가능성을 만든다. 요청 식별자와 재시도 소유권, HTTP client 자동 재실행 정책, 중복 검출 지표를 함께 관리해야 한다.

셋째, 복구 완료는 broker process가 다시 실행된 시점이 아니다. replica catch-up, unfence, ISR 복원, URP/unavailable 0, 새 traffic 진행, backlog 소진과 identity reconciliation을 모두 확인해야 한다.

넷째, 이번 결과는 로컬 단일 controller 경계다. production 적용 판단에는 controller quorum HA, 네트워크와 storage failure domain, RTO/RPO 목표, 부하·soak와 client effective config capture가 별도 검증 과제로 남는다. 이 문서는 그러한 범위를 자동 승인하거나 Candidate Practice로 승격하지 않는다.

## 20. 산출물과 증거 탐색

| 산출물 | 책임 |
|---|---|
| [Reproduction Contract](./REPRODUCTION-CONTRACT.md) | 실행 전에 승인된 질문·조건·성공 기준 |
| [Reproduction Record](./REPRODUCTION-RECORD.md) | 두 Material Run의 실행 이력, 편차와 Evidence → Claim mapping |
| [최초 실행 evidence](./evidence/BIP-FR-002-MR-20260902T043510Z/) | `Partial / Inconclusive Evidence` 원본과 manifest |
| [Strict Run evidence](./evidence/BIP-FR-002-MR-20260902T053228Z/) | `STRICT PASS` 주 증거와 manifest |
| [Operational Validation index](../../README.md) | BIP-FR-001/BIP-FR-002 독립 탐색 경계 |
