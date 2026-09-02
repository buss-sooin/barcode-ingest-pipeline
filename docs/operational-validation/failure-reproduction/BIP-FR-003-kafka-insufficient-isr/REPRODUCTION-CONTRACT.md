# BIP-FR-003 Kafka insufficient ISR 쓰기 불가 재현 계약

## 1. 계약 식별과 책임

- Contract ID: `BIP-FR-003-RC`
- Current Revision: `BIP-FR-003-RC-R1`
- Scenario: `BIP-FR-003 — Kafka Insufficient ISR Write Unavailability During Active Scan`
- Workflow: Failure Reproduction Workflow v0.1 (`Effective`, 2026-08-28)
- 상태: 승인 의도 기록 완료, 최초 판정 대상 실행(Material Run) 준비

이 문서는 판정 대상 실행 전에 승인된 실행·검증 경계를 고정하는 재현 계약(Reproduction Contract)이다. 실행 결과에 맞춰 실패 징후(Failure Signature), 성공 기준 또는 주장 경계를 사후 완화하지 않는다.

<a id="bip-fr-003-rc-r1"></a>

### 1.1 `BIP-FR-003-RC-R1` — Initial Revision

| 항목 | 값 |
|---|---|
| Contract Revision | `BIP-FR-003-RC-R1` |
| Previous Revision | 없음 — Initial Revision |
| Effective Point | 이 Revision을 포함하는 준비 commit부터 최초 Material Run에 적용 |
| Revision Reason | 승인된 BIP-FR-003 의도, 실패 징후, 검증·Evidence·안전 경계를 첫 실행 전에 고정 |
| 기존 Human Gate 경계 안의 변경 | 해당 없음. 승인된 최초 경계를 그대로 기록 |

정확한 승인 시각과 별도 승인 식별자는 제공되거나 독립 Evidence로 확인되지 않았다. 이를 생성하지 않는다. 승인 근거는 `Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation`에서 권한 있는 사용자가 명시한 Human Gate 승인과 실행 경계다.

## 2. 실패 질문(Failure Question)

> 승인된 로컬 3-broker Kafka 토폴로지에서 전용 KRaft controller와 target partition의 현 리더가 살아 있는 동안, follower 하나를 추가로 SIGKILL하여 ISR을 1로 낮추면 RF=3, `min.insync.replicas=2`, producer `acks=all`, unclean leader election 비활성화 조건 때문에 새 application produce가 성공 확인을 받지 못하는가? 이어서 두 번째로 중단한 follower만 같은 volume으로 먼저 복구해 ISR이 1에서 2가 되면 설정 완화나 애플리케이션 재시작 없이 새 쓰기 성공이 회복되고, 최초 중단 broker까지 복구한 뒤 복제와 전체 파이프라인이 수렴하는가?

이 질문은 한 번의 경계가 정해진 로컬 검증 실행만 대상으로 하며 production 보장으로 일반화하지 않는다.

## 3. Scope와 Non-goals

### 3.1 포함 Scope

- 기존 전용 KRaft controller 1개와 broker-only Kafka node 3개
- `barcode-events`: partitions 3, 복제 계수(Replication Factor, RF) 3, `min.insync.replicas=2`
- Ingest producer `acks=all`, broker별 영속 volume 유지, unclean leader election 비활성화
- 런타임 메타데이터로 선택한 target partition과 `L0 → L1`, `ISR 3 → 2 → 1 → 2 → 3`
- 정상 쓰기, ISR=2 쓰기, ISR=1 실패 witness, ISR=2 복구 쓰기, 최종 정합성
- 논리 이벤트, HTTP/Scanner 재전송, Kafka record, 중복 제거(Deduplication), 최종 business identity 계량

### 3.2 Non-goals와 명시적 비주장

- production 고가용성(High Availability, HA), SLA, 복구 시간 목표(Recovery Time Objective, RTO), 복구 시점 목표(Recovery Point Objective, RPO)
- controller HA 또는 controller 장애
- 세 번째 broker 장애, 세 broker 동시 장애, network partition, host/rack/AZ 장애
- volume 삭제, 저장소 유실·손상·full, topic 재생성 또는 offset reset
- 일반적인 exactly-once, duplicate-free transport 또는 모든 Kafka/client/version/인프라의 동일 동작
- 특정 request가 SIGKILL 순간 정확히 in-flight였다는 조건이나 보장
- Scanner, Processing, Redis, MySQL, worker 장애를 결합한 복구
- 성능, 장시간 soak, capacity 또는 일반적인 failover latency 보장

## 4. 승인 토폴로지와 사전 조건

### 4.1 고정 조건

| 항목 | 승인 값 |
|---|---|
| 환경 | local/dev validation topology |
| controller | 전용 KRaft controller node `100`, 실행 유지 |
| brokers | broker-only node `1`, `2`, `3` |
| broker storage | broker별 기존 persistent volume 유지 |
| topic | `barcode-events`, partitions `3`, RF `3` |
| topic minISR | `min.insync.replicas=2` |
| producer | `acks=all`, 다중 broker bootstrap |
| leader election | `unclean.leader.election.enable=false` |

### 4.2 Material Run 사전 조건

1. 실행 branch, HEAD, working tree와 Contract Revision을 기록한다.
2. controller와 broker 3개가 승인된 role/node ID로 실행 중이고 모든 broker가 healthy다.
3. `barcode-events`의 모든 partition이 ISR=3이며 복제 부족 파티션(Under-replicated Partition, URP)과 unavailable partition이 0이다.
4. topic의 유효 `min.insync.replicas=2`와 broker의 유효 unclean leader election 비활성화를 확인한다.
5. 실제 Ingest `ProducerConfig`에서 필수 producer 속성과 bootstrap을 보존한다.
6. 정상 application write가 Kafka acknowledgment, downstream 처리와 MySQL까지 진행한다.
7. Kafka consumer lag, Redis group lag·보류 항목(Pending Entries List, PEL), DLQ와 DLT가 정상 terminal 상태다.

충족하지 못하면 broker를 중단하지 않고 실행 편차 또는 무효 실험으로 기록한다.

## 5. Target partition과 런타임 역할

과거 broker 번호를 고정하지 않는다. 정상 Scanner mapping probe를 실행하고 Ingest acknowledgment의 실제 partition을 사용한다.

- `P`: `SEOUL-CENTER-PC-001` key가 런타임에 매핑된 target partition
- `L0`: healthy 상태에서 `P`의 현재 leader이며 첫 번째 SIGKILL 대상
- `L1`: `L0` 중단 후 pre-failure ISR에서 선출되어 ISR=2를 이끄는 새 leader
- `F1`: 첫 실패 뒤 `P`의 ISR=2에 남은 replica 중 `L1`이 아닌 follower이며 두 번째 SIGKILL 대상

두 번째 장애 직전에 `leader=L1`, ISR size=2, `F1 ∈ ISR`, `F1 != L1`, `L0 ∉ ISR`를 다시 확인한다. 조건이 다르면 guessed broker를 중단하지 않는다.

## 6. 장애 주입과 시간 술어

### 6.1 실행 순서

1. healthy 상태와 baseline write를 검증하고 `P`, `L0`를 발견한다.
2. `L0`에 SIGKILL을 보내고 `leader=L1`, ISR=2가 안정될 때까지 기다린다.
3. 고유한 degraded-state witness로 ISR=2 쓰기 성공을 확인한다.
4. bounded Scanner traffic을 시작하고 `T_active_start`를 기록한다.
5. `L1`/ISR/`F1`를 다시 읽어 안전 술어를 검증한다.
6. follower `F1`에만 SIGKILL을 보내고 `leader=L1`, ISR=1을 직접 확인한다.
7. active traffic이 계속되는 동안 `P`로 매핑되는 고유 application request를 한 번만 전송한다.
8. `F1`을 같은 container/volume으로 먼저 복구하고 ISR 1→2 뒤 recovery witness 성공을 확인한다.
9. `L0`를 같은 container/volume으로 복구하고 ISR=3, URP=0, unavailable=0을 확인한다.
10. Scanner backlog·재시도와 downstream을 수렴시킨 뒤 identity reconciliation을 수행한다.

### 6.2 승인 시간 술어

```text
active traffic
∩ target partition ISR=1
∩ leader exists
∩ new application/Kafka produce attempt
```

구체적으로 `T_active_start < T_failure_witness_attempt < T_active_end`이고, witness 직전·직후 Evidence에서 `leader=L1`, ISR size=1을 확인한다. 특정 request가 SIGKILL 순간 in-flight일 필요는 없다.

## 7. 예상 Kafka 의미와 실패 징후

### 7.1 예상 의미

- ISR=2에서는 `min.insync.replicas=2`와 `acks=all`을 함께 충족하므로 새 쓰기는 성공할 수 있다.
- leader가 존재해도 ISR=1은 minISR=2보다 작으므로 새 produce는 성공 acknowledgment를 받지 않아야 한다.
- 이 상태는 partition leader 부재와 다르다. 핵심 인과 경계는 `leader exists + ISR=1 < minISR=2 + acks=all`이다.
- `F1` 복구로 ISR=2가 되면 설정 완화나 application restart 없이 새 write acceptance가 회복되어야 한다.

### 7.2 실패 징후(Failure Signature)

다음 구성 요소를 모두 직접 연결한다.

1. `P`의 leader `L1`이 살아 있고 ISR=1이며 topic minISR=2다.
2. 이 구간이 active Scanner traffic과 시간적으로 겹친다.
3. 같은 구간에 정상 Ingest 경로로 고유한 새 produce witness를 제출한다.
4. Ingest 수신과 `KafkaTemplate.send()` 경계, 성공 acknowledgment 부재, producer exception/timeout/error, HTTP non-success를 보존한다.
5. witness 전후 partition offset과 downstream identity를 확인한다.

HTTP 오류 하나만으로 재현을 판정하지 않는다.

## 8. 판정 기준

### 8.1 성공 기준

- 사전 조건·runtime target discovery·두 SIGKILL 안전 술어와 시간 술어가 모두 충족된다.
- `L0` 중단 뒤 clean leader `L0 → L1`, ISR 3→2가 확인되고 ISR=2 witness가 성공한다.
- `F1` 중단 뒤 동일 leader `L1`과 ISR=1이 확인되며 새 witness가 성공 acknowledgment를 받지 못한다.
- `F1`의 same-volume 복구로 ISR 1→2 뒤 새 recovery witness가 성공한다.
- `L0` 복구 뒤 모든 예상 ISR=3, URP=0, unavailable=0으로 수렴한다.
- retry queue drop이 없고 backlog/retry, Kafka/Redis lag, PEL, DLQ/DLT가 terminal 상태로 수렴한다.
- 실행 범위 logical identities가 MySQL 또는 명시적으로 입증된 expected rejection에 모두 귀속되며 unaccounted=0, final business duplicate=0이다.

### 8.2 실패 기준

유효하고 Evidence가 충분한 실행에서 다음 중 하나면 정의된 기대를 충족하지 못한 것이다.

- ISR=2인데 degraded/recovery witness가 지속적으로 성공하지 못한다.
- ISR=1인데 failure witness가 성공 acknowledgment를 받는다.
- 설정 완화나 application restart 없이는 ISR 1→2 뒤 쓰기가 회복되지 않는다.
- 복구 순서 준수 후 ISR/URP/unavailable 또는 downstream 정합성이 수렴하지 않는다.
- retry queue가 capacity에 도달하거나 request drop이 발생한다.

### 8.3 실행 편차(Deviation)

- 두 번째 kill 직전 `L1`/ISR=2/`F1` follower 술어가 성립하지 않는다.
- active traffic, ISR=1, leader 존재와 witness 시도가 겹치지 않는다.
- 고유 witness가 `P`에 매핑되었음을 입증하지 못한다.
- 필수 timestamp, metadata, application log 또는 identity Evidence가 누락된다.

편차는 숨기지 않으며 실험 유효성과 증거 충분성 평가에 반영한다.

### 8.4 무효 실험(Invalid Experiment)

- 승인되지 않은 Git/config/topology로 실행하거나 controller가 중단된다.
- 현재 leader가 아닌 것으로 검증되지 않은 broker를 두 번째로 중단한다.
- 세 번째 broker, application, Redis, MySQL 또는 worker에 장애가 함께 발생한다.
- volume 삭제, topic 재생성, offset reset, minISR/acks 완화, unclean election 활성화 또는 destructive cleanup이 개입한다.
- 외부 자원 고갈이나 범위 밖 장애가 결과를 지배한다.

## 9. 복구와 정합성 기준

복구 순서는 반드시 `F1 same-volume start → ISR 1→2 → recovery witness → L0 same-volume start → ISR 2→3`이다. 두 broker container의 ID, node ID와 volume mount를 전후 비교한다. controller와 application은 재시작하지 않는다.

최종 정합성은 scanTime과 barcode 집합으로 검증한다.

```text
generated unique identities
  = final MySQL unique identities
  + directly evidenced expected-rejected identities
  + terminal DLQ/DLT/pending identities
  + unaccounted identities
```

성공하려면 unaccounted, 예상 밖 extra, business duplicate, terminal DLQ/DLT/pending이 0이어야 한다. Kafka transport record 수는 logical event 수와 별도로 계량한다. application/HTTP 재전송으로 transport duplication이 생길 수 있으며, 이를 business duplicate나 Kafka의 독립 replay로 단정하지 않는다.

## 10. 유효 설정과 Evidence 요구사항

| 계층 | 필수 Evidence |
|---|---|
| 실행 정체성 | branch/HEAD/status, Contract ID/Revision, Run ID, Compose asset hash |
| topology | controller/broker role·node ID·status, container ID, volume mapping |
| Kafka | `P` leader/replicas/ISR 전이, topic minISR, unclean election, offsets, URP, unavailable, quorum |
| Producer | 실제 runtime `ProducerConfig`의 `acks`, `enable.idempotence`, `retries`, `delivery.timeout.ms`, `request.timeout.ms`, `retry.backoff.ms`, `bootstrap.servers` |
| application witness | unique identity, request/response time, Ingest receive/send success·failure, HTTP result, downstream 관측 |
| retry/amplification | logical unique, driver HTTP, Scanner fallback·retry, queue high-water/drop, Kafka records, duplicate detection |
| recovery/integrity | same-volume recovery, ISR 1→2→3, consumer/Redis lag·PEL, DLQ/DLT, MySQL identity reconciliation |

직접 런타임 캡처가 있는 값은 직접 증명(Directly Proven)으로 분류한다. 버전 기본값이나 일관된 정황만 있는 설명은 강한 추론(Strongly Inferred), protocol-level로 결정할 수 없는 항목은 미해결(Unresolved)로 유지한다.

## 11. 재시도와 증폭 관측 경계

- traffic driver: 생성 sequence당 한 번만 Scanner endpoint를 호출하고 driver retry를 사용하지 않는다.
- failure witness: Ingest 단건 endpoint를 `curl --retry 0`으로 한 번 호출해 Scanner retry와 분리한다.
- Scanner: batch fallback, 단건 재시도 queue, queue high-water와 drop을 로그에서 계량한다.
- Ingest: HTTP request당 한 번의 `KafkaTemplate.send()`와 5초 확인 대기 경계를 관측한다. timeout은 underlying Future를 취소하지 않는다.
- Kafka Producer: runtime config와 client error를 보존하되 내부 exact retry count나 wire-level producer sequence를 직접 캡처하지 않으면 단정하지 않는다.
- Processing: 수신 record와 duplicate detection, 최종 business identity를 구분한다.

`logical = HTTP = send = Kafka record`를 성공 조건으로 요구하지 않는다. 예상 밖 amplification은 Observation으로 보존한다.

## 12. 안전과 승인된 Human Gate 경계

### 12.1 허용 action

- 승인된 local/dev Compose topology의 읽기·상태 캡처
- runtime role discovery와 witness/Scanner bounded traffic
- `L0` SIGKILL 후 `F1` SIGKILL
- `F1` 우선, `L0` 후순위의 same-container/same-volume start
- Evidence 생성·manifest 검증과 정본 문서 동기화

### 12.2 금지 action

- controller failure, volume 삭제, storage-loss test, topic recreation, offset reset
- minISR 또는 `acks` 완화, unclean leader election 활성화
- current leader인 `L1` 또는 세 번째 broker 중단
- production/non-local 실행, destructive cleanup, unrelated application change

### 12.3 Human Gate

- 상태: 승인됨
- Approval reference: `Task #52 — BIP-FR-003 Approved Intent Recording & Execution Preparation`
- Authority reference: 이 개인 repository/project와 local validation execution에 대한 권한 있는 Human 사용자
- 승인 대상: 두 broker가 동시에 down이고 한 broker가 남는 상태를 의도적으로 포함한 본 계약의 local bounded sequence
- 승인 시각/별도 식별자: 독립적으로 확인할 수 없어 기록하지 않음

승인된 Engineering Intent, Scope, authority/access, 위험/영향 반경(Risk/Blast Radius), irreversible/high-impact action 또는 execution boundary가 material하게 바뀌면 실행을 중단하고 새 Human Gate를 요청한다.

## 13. Contract Revision과 Material Run 규칙

- 조건, 절차, 실패 징후, Verification Criteria 또는 Evidence 요구사항의 material redesign은 기존 Revision을 덮어쓰지 않고 후속 Revision으로 기록한다.
- 후속 Revision에는 predecessor, effective point, reason, 정확한 변경과 기존 Human Gate 경계 안인지 여부를 남긴다.
- 승인 경계를 바꾸지 않는 Revision은 새 Human Gate를 자동 요구하지 않는다.
- 모든 Material Run은 정확히 하나의 식별 가능한 Contract Revision을 직접 참조한다.
- 최초 할당은 `BIP-FR-003-MR-20260902T112532Z → BIP-FR-003-RC-R1`이다.
