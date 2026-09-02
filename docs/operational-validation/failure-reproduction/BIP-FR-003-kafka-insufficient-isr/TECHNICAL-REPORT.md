# BIP-FR-003 Kafka insufficient ISR 쓰기 불가 기술 보고서

## 1. 결론

주 검증 실행 `BIP-FR-003-MR-20260902T114420Z`의 Failure Reproduction Workflow Outcome은 `REPRODUCED`다. 승인된 로컬 3-broker 토폴로지에서 partition 1의 leader broker 2를 먼저 SIGKILL한 뒤 clean leader broker 3과 ISR=2가 안정된 상태에서는 `acks=all` 새 쓰기가 성공했다. active Scanner traffic 중 남은 follower broker 1을 SIGKILL해 leader broker 3은 살리고 ISR만 1로 낮추자, 고유 application witness가 5초 안에 성공 acknowledgment를 받지 못하고 HTTP 503과 `NotEnoughReplicasException`을 남겼다.

broker 1을 같은 volume으로 먼저 복구해 ISR이 2가 되자 설정 완화와 application restart 없이 새 write가 다시 성공했다. broker 2까지 복구한 뒤 모든 `barcode-events` partition은 ISR=3, 복제 부족 파티션(Under-replicated Partition, URP) 0, unavailable partition 0으로 수렴했다. 실행 범위 54 logical identity는 MySQL unique 53개와 직접 입증된 expected rejection 1개로 모두 귀속됐고 unaccounted는 0이었다.

## 2. Failure Question

> leader가 존재하는 target partition의 ISR이 `min.insync.replicas=2`보다 작은 1이 되었을 때, runtime producer `acks=all`의 새 application produce가 성공 확인을 받지 못하며, follower 복구로 ISR이 2가 되면 설정 완화 없이 쓰기 acceptance가 회복되는가?

이 질문은 “Kafka 전체가 unavailable인가”가 아니라 “leader는 있으나 정합성 계약을 만족할 동기화 replica 수가 부족한가”를 구분한다.

## 3. 승인 토폴로지와 bounded 조건

| 경계 | 실행 값 | Evidence 상태 |
|---|---|---|
| 환경 | local/dev Docker validation topology | 직접 증명 |
| controller | 전용 KRaft controller node 100, 실행 유지 | 직접 증명 |
| brokers | broker-only node 1·2·3, 개별 persistent volume | 직접 증명 |
| topic | `barcode-events`, partitions 3, RF=3 | 직접 증명 |
| topic config | `min.insync.replicas=2` | dynamic topic config로 직접 증명 |
| producer | `acks=-1(all)`, `enable.idempotence=true`, `retries=3` | runtime `ProducerConfig`로 직접 증명 |
| leader election | `unclean.leader.election.enable=false` | topic/broker runtime config로 직접 증명 |
| application bootstrap | broker-1·2·3 | runtime `ProducerConfig`로 직접 증명 |

Broker 기본 `min.insync.replicas` 로그에는 `1`도 보이지만, 이 실험의 대상 topic에는 dynamic topic config `min.insync.replicas=2`가 적용되어 우선한다. 보고서는 broker default와 target topic effective config를 혼동하지 않는다.

## 4. 건전한 사전 조건(Healthy Preconditions)

실행 전 controller와 broker 3개, Ingest, Processing, Scanner, Redis, MySQL, worker가 실행 중이었고 broker는 모두 healthy였다. 세 `barcode-events` partition의 ISR size는 3, URP와 unavailable partition은 0이었다. Kafka consumer lag, Redis group lag·보류 항목(Pending Entries List, PEL), DLQ, DLT도 0이었으며 정상 mapping request가 Kafka acknowledgment와 MySQL까지 진행했다.

Runtime mapping은 역사적 broker 번호를 사용하지 않았다.

```text
SEOUL-CENTER-PC-001
→ P = partition 1
→ L0 = broker 2
```

## 5. Material Run 역사와 Contract Revision

| Run | Revision | Outcome | Engineering 의미 |
|---|---|---|---|
| `...112532Z` | `BIP-FR-003-RC-R1` | `INCONCLUSIVE` | controller health key inspection 오류로 주입 전 종료. SIGKILL 0회 |
| `...113950Z` | `BIP-FR-003-RC-R1` | `INCONCLUSIVE` | 첫 ISR=2 sample 즉시 witness를 보내 안정화 조건 미확립. HTTP 503 뒤 2.229초 후 late ack 관측 |
| `...114420Z` | `BIP-FR-003-RC-R2` | `REPRODUCED` | 연속 ISR=2 sample과 10초 안정화 뒤 승인된 전체 인과 사슬 검증 |

R1 첫 결함은 inspection 호환성만 고쳐 R1을 유지했다. 두 번째 실행은 material procedure redesign이 필요해 R2를 만들었다. R2는 topology, failure target 규칙, 두 broker 동시 down 위험, acceptance 또는 claim boundary를 바꾸지 않았으므로 기존 Human Gate 안에서 실행했다.

## 6. Strict causal timeline

```text
healthy ISR=3 / leader L0=2
→ L0 SIGKILL
→ clean leader L1=3 / ISR=2
→ stabilized ISR=2 write 200 / offset 170
→ active Scanner traffic
→ F1=1 follower SIGKILL
→ same leader L1=3 / ISR=1
→ unique application witness 503 / NotEnoughReplicas / offset 177 unchanged
→ F1 same-volume recovery
→ ISR 1→2 / recovery write 200 / offset 213
→ L0 same-volume recovery
→ ISR=3 / URP=0 / unavailable=0
→ retry drain / reconciliation
```

| UTC | 사건 |
|---|---|
| `11:48:12` | partition 1 current leader `L0=2` SIGKILL |
| `11:48:23–11:48:26` | pre-failure ISR member broker 3이 leader, ISR `3,1` 연속 관측 |
| `11:48:26–11:48:37` | R2 10초 안정화 후 같은 leader/ISR 재검증 |
| `11:48:37` | ISR=2 degraded witness HTTP 200, offset 170 |
| `11:48:40–11:49:33` | active traffic 50개 |
| `11:48:46` | follower `F1=1` 재검증 후 SIGKILL; `L1=3` alive |
| `11:48:59` | partition 1 `leader=3`, `ISR=3`(broker ID 3 하나) |
| `11:49:07–11:49:12` | failure witness, HTTP 503, offset `177→177` |
| `11:49:18–11:49:23` | F1 same-volume 복구, ISR `3→3,1` |
| `11:49:24` | recovery witness HTTP 200, offset 213 |
| `11:49:27–11:49:37` | L0 same-volume 복구, 전체 ISR=3 |
| `11:50:21` | reconciliation 완료 |

`ISR=3`이라는 표기는 문맥에 따라 혼동될 수 있다. 위 `11:48:59`의 `ISR=3`은 Kafka metadata의 broker ID 목록 `Isr: 3`, 즉 ISR size 1을 뜻한다. 전체 복구의 `ISR=3`은 ISR size 3을 뜻한다.

## 7. leader / follower / ISR 의미

동기화 복제본 집합(In-sync Replicas, ISR)은 leader의 로그를 허용 범위 안에서 따라잡은 replica 집합이다. 첫 실패 전 partition 1은 replicas `2,3,1`, ISR `3,1,2`, leader 2였다. broker 2가 fencing된 뒤 ISR member broker 3이 새 leader가 되었고 ISR은 `3,1`로 줄었다. 이는 unclean election이 아니라 이미 동기화되어 있던 replica의 clean leader election이다.

두 번째 실패에서는 새 leader broker 3을 유지하고 follower broker 1만 중단했다. 따라서 partition은 offline이 되지 않았고 leader는 요청을 받을 수 있었지만 ISR size는 1이었다. “leader 존재”와 “`acks=all` write acceptance 가능”이 서로 다른 상태라는 점이 이 시나리오의 핵심이다.

## 8. 왜 ISR=2에서는 쓰고 ISR=1에서는 거부되는가

Target topic의 `min.insync.replicas=2`는 성공을 승인할 때 필요한 최소 ISR 수를 2로 둔다. Producer `acks=all`은 현재 ISR이 요구하는 acknowledgment 경계를 사용한다.

- ISR size 2: 최소 수 2를 충족한다. 안정화 뒤 새 write가 HTTP 200과 offset 170 acknowledgment를 받았다.
- ISR size 1: 최소 수 2보다 작다. leader가 있어도 새 write를 성공으로 승인할 수 없다. Failure witness는 HTTP 503, `NotEnoughReplicasException`, offset 불변으로 관측됐다.

이 동작은 정합성 조건을 낮춰 가용성을 만드는 것이 아니라, 설정된 replica 승인 경계를 지키기 위해 write availability를 제한한 결과다.

## 9. application-visible failure

Primary failure witness는 Scanner retry를 배제하기 위해 정상 Ingest 단건 endpoint를 `curl --retry 0`으로 한 번 호출했다.

| 항목 | 값 |
|---|---|
| barcode | `9913497463030` |
| scanTime | `1788349746303` |
| request | `11:49:07Z` |
| Ingest 결과 | 5초 confirmation timeout, HTTP 503 |
| async producer 결과 | `NotEnoughReplicasException` |
| target offset | `177→177` |
| Kafka/MySQL identity | 없음 |

HTTP 503만으로 판정하지 않았다. 같은 구간의 active traffic, leader broker 3의 healthy 상태, ISR size 1, topic minISR 2, producer `acks=all`, request identity, producer exception, offset와 downstream 부재를 함께 연결했다.

## 10. Transport duplicate: `54 logical → 54 records → 53 business`

정합성 관계는 다음 두 경계를 분리해 읽어야 한다.

```text
54 logical identities
= 53 MySQL unique
+ 1 directly evidenced expected rejection

54 Kafka records
= 53 Kafka unique identities
+ 1 transport duplicate
```

Logical 54개 중 failure witness 1개는 의도한 insufficient ISR rejection으로 Kafka에 들어가지 않았다. 나머지 accepted logical identity는 53개다. Kafka record는 54개였으므로 accepted logical 대비 1개가 추가됐고, Processing이 duplicate 1회를 검출했다. 최종 MySQL business identity는 53개이며 duplicate row는 0이다.

따라서 transport-level duplication과 business-level deduplication은 서로 다른 일관성 경계다. Transport duplicate가 있다는 사실은 프로젝트 결함 판정 자체가 아니며, business integrity는 identity reconciliation으로 따로 판단한다.

## 11. 재시도(Retry)·재전송 책임

### Traffic driver

- generated sequence마다 Scanner endpoint 한 번
- direct witness마다 Ingest endpoint 한 번
- 모든 호출 `curl --retry 0`
- manifest 결과: HTTP 200 53건, 의도한 failure witness HTTP 503 1건

### Scanner / HTTP

- batch HTTP 38회, item 합계 51개는 mapping 1 + active 50과 일치한다.
- partial failure가 보고된 fallback log event는 21회이며 31개 failed index를 단건 경로로 넘겼다.
- retry queue high-water는 16/10000, drop은 0, 마지막 summary는 remaining 0이다.
- Ingest는 single HTTP 74회를 받았다. 이 중 3회는 직접 witness이고 71회는 Scanner fallback, retry queue와 HTTP client 재실행 경계에 속한다.

### Ingest

- source 구현은 request item마다 `KafkaTemplate.send()` 한 번을 호출한다.
- Material window에는 batch item 51 + single 74 = 125 send result가 있으며 success callback 53, failure callback 72다.
- HTTP controller는 5초만 확인을 기다리고 timeout이 나도 underlying Future를 취소하지 않는다.

### Kafka Producer

Runtime snapshot으로 다음이 직접 확인됐다.

- `acks=-1` (`all`)
- `enable.idempotence=true`
- `retries=3`
- `delivery.timeout.ms=120000`
- `request.timeout.ms=30000`
- `retry.backoff.ms=100`
- `max.in.flight.requests.per.connection=5`
- `bootstrap.servers=[broker-1, broker-2, broker-3]`

그러나 각 send가 실제로 몇 번 내부 retry됐는지는 protocol trace가 없어 직접 증명하지 않는다.

### Processing

- Kafka record 54개 수신 범위에서 53개가 최초 logical identity였다.
- barcode `8800168838857`가 offsets 177과 198에서 반복됐고 두 번째를 duplicate로 검출했다.
- Redis 원자 중복 제거와 MySQL unique 경계 뒤 business duplicate는 0이다.

## 12. Duplicate가 Kafka 독립 replay 증거가 아닌 이유

중복 identity는 Scanner-origin 단건 HTTP request가 여러 번 Ingest에 도달한 Evidence와 함께 나타난다. 첫 Kafka record offset 177에는 같은 attempt의 성공 acknowledgment가 보존되지 않았고, 후속 단건 재제출은 offset 198 성공 acknowledgment를 남겼다. 즉 확인 불확실성 뒤 application/HTTP resend가 동일 logical identity를 다시 제출한 경계가 직접 보인다.

어느 개별 send가 offset 177을 append했고 acknowledgment가 정확히 어디서 소실됐는지는 미해결이다. 하지만 Kafka가 저장된 record를 leader election 때문에 스스로 새 record로 replay했다는 로그·protocol Evidence는 없다. 관측된 두 record를 그처럼 해석하지 않는다.

## 13. 복구(Recovery)

기능 복구와 전체 복구를 분리했다.

1. 기능 복구: 두 번째로 중단한 `F1=1`을 같은 container ID와 volume으로 먼저 시작했다. ISR이 `3→3,1`이 된 뒤 recovery witness가 HTTP 200과 offset 213 acknowledgment를 받았다. minISR·acks 변경과 application restart는 없었다.
2. 전체 복구: 최초 중단한 `L0=2`를 같은 container ID와 volume으로 시작했다. `11:49:37Z`에 세 target partition 모두 ISR size 3, URP 0, unavailable 0, broker 3개 healthy였다.
3. 흐름 수렴: Scanner retry queue remaining 0, Kafka target lag 0, Redis group lag/PEL 0, DLQ/DLT 0을 확인했다.

## 14. 최종 reconciliation

| 항목 | 결과 |
|---|---:|
| generated unique | 54 |
| Kafka records | 54 |
| Kafka unique identities | 53 |
| transport duplicates | 1 |
| MySQL rows / unique identities | 53 / 53 |
| directly evidenced expected rejection | 1 |
| missing / extra / unaccounted | 0 / 0 / 0 |
| business duplicate | 0 |
| DLT / DLQ / pending | 0 / 0 / 0 |
| Kafka target lag / Redis group lag | 0 / 0 |

## 15. Evidence 분류

### 직접 증명(Directly Proven)

- runtime topology, topic config와 ProducerConfig
- P/L0/L1/F1, 두 SIGKILL target, leader/ISR 전이
- active traffic과 ISR=1 failure witness 시간 중첩
- HTTP timeout/503, `NotEnoughReplicasException`, offset/identity 부재
- F1/L0 same-volume 복구와 write/replication 회복
- retry queue high-water/drop/final, Kafka/MySQL identity와 duplicate 수

### 강한 추론(Strongly Inferred)

- client metadata refresh·재연결이 R1 late acknowledgment와 전이 지연에 관여했다는 설명
- 반복 HTTP 제출과 confirmation ambiguity가 transport duplicate를 만든 구체적 인과 경로

### 미해결(Unresolved)

- send별 exact Kafka 내부 retry count
- offset 177의 exact request attempt, append/ACK wire-level 순서
- producer ID/epoch/sequence history와 `OutOfOrderSequenceException`의 세부 원인
- Scanner-origin single HTTP 71회의 fallback/retry/automatic re-execution별 정확한 분해
- production 또는 다른 환경의 일반적인 failover/recovery latency

이 미해결 항목은 사전 실패 징후와 R2 Outcome을 무효화하지 않지만, 더 강한 protocol-level 주장을 제한한다.

## 16. Maximum Verified Claim

> 승인된 로컬 BIP-FR-003 토폴로지와 bounded R2 run에서, 전용 KRaft controller가 유지되고 `barcode-events` partition 1의 leader가 broker 3으로 존재하는 동안 follower broker 1을 두 번째로 SIGKILL해 ISR이 1로 내려갔다. RF=3, topic `min.insync.replicas=2`, runtime producer `acks=all`, unclean leader election 비활성화 조건에서 active Scanner traffic과 겹쳐 제출한 고유 application produce witness는 5초 안에 성공 acknowledgment를 받지 못하고 HTTP 503과 `NotEnoughReplicasException`을 남겼으며 partition offset과 downstream identity도 증가하지 않았다. broker 1을 같은 volume으로 먼저 복구해 ISR이 2가 되자 application 재시작이나 설정 완화 없이 새 write가 성공했고, 최초 중단 broker 2까지 같은 volume으로 복구한 뒤 모든 `barcode-events` partition이 ISR 3, URP 0, unavailable partition 0으로 수렴했다. 54개 logical identity는 최종 MySQL unique 53개와 직접 입증된 expected rejection 1개로 모두 귀속됐고, transport duplicate 1개는 Processing dedupe 뒤 business duplicate를 만들지 않았다.

## 17. Explicit Non-Claims

- 일반적인 exactly-once guarantee 또는 duplicate-free transport
- production HA / SLA / RTO / RPO
- controller HA
- 세 번째 broker failure 또는 세 broker 동시 failure tolerance
- network partition, storage loss/corruption/full
- arbitrary Kafka/topic/partition failure tolerance
- SIGKILL 순간 특정 produce request가 정확히 in-flight였다는 보장
- callback timeout이 언제나 Kafka append 실패를 뜻한다는 일반화
- 다른 Kafka/client version 또는 infrastructure의 동일 동작
- Scanner/Processing/Redis/MySQL/worker 결합 장애 복구
- performance, capacity 또는 long-duration soak guarantee
- 관측된 `OutOfOrderSequenceException`의 Root Cause 확정

## 18. 운영적 의미

첫째, broker health와 partition leader 존재만으로 write availability를 판단할 수 없다. `leader + ISR size + topic minISR + producer acks`를 함께 봐야 한다.

둘째, ISR=1 구간의 503은 확정적 business loss와 같은 뜻이 아니다. 이번 고유 witness는 offset과 identity 대조로 실제 rejection을 확인했지만, R1처럼 HTTP timeout 뒤 underlying send가 늦게 성공할 수도 있다. Retry 설계는 acknowledgment ambiguity와 duplicate 가능성을 전제로 해야 한다.

셋째, 기능 복구는 모든 broker 복귀보다 앞설 수 있다. 이 실행에서는 F1 복구로 ISR=2가 된 시점에 write acceptance가 먼저 회복됐고, L0 복구 뒤 replication health가 완전히 수렴했다. Alert와 runbook은 두 경계를 구분해야 한다.

넷째, Scanner retry queue는 유실을 막는 완충 역할을 했지만 high-water 16과 많은 application send failure를 만들었다. Queue capacity/drop, retry amplification과 business dedupe를 함께 관측해야 한다.

## 19. Evidence Navigation

- [Reproduction Contract](./REPRODUCTION-CONTRACT.md)
- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [주 Material Run Evidence](./evidence/BIP-FR-003-MR-20260902T114420Z/)
- [주 Run SHA-256 manifest](./evidence/BIP-FR-003-MR-20260902T114420Z/MANIFEST.sha256)
- [정합성 요약](./evidence/BIP-FR-003-MR-20260902T114420Z/final/42-run-scoped-reconciliation-summary.txt)
- [R1 preflight INCONCLUSIVE](./evidence/BIP-FR-003-MR-20260902T112532Z/)
- [R1 stabilization INCONCLUSIVE](./evidence/BIP-FR-003-MR-20260902T113950Z/)
