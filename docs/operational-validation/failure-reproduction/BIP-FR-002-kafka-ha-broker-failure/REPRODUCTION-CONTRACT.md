# BIP-FR-002 Kafka HA 단일 브로커 장애 재현 계약

## 1. 문서의 책임과 승인 경계

이 문서는 승인된 BIP-FR-002 설계를 구현과 실행보다 먼저 고정하는 재현 계약(Reproduction Contract)이다. 구현 산출물과 이후 Material Run은 이 계약을 충족해야 하며, 실행 결과가 계약과 다르면 결과를 유리하게 해석하지 않고 실험을 실패 또는 무효로 판정한다.

현재 승인 범위는 **Implementation Phase A**까지다. Phase A는 전용 HA 토폴로지, 명시적 토픽 초기화, 읽기 전용 증거 수집 도구의 구현과 정적 검증만 포함한다. Kafka 클러스터 시작, 트래픽 실행, 장애 주입과 복구 검증은 포함하지 않는다.

## 2. 시나리오와 Failure Question

### 2.1 시나리오

전용 KRaft 컨트롤러 1개와 broker-only Kafka 프로세스 3개로 구성한 로컬 검증 토폴로지에서 `barcode-events`를 3개 파티션, 복제 계수(Replication Factor, RF) 3, `min.insync.replicas=2`로 운용한다. 정상 상태와 트래픽 흐름을 확인한 뒤, 후속 승인 단계에서 브로커 하나의 프로세스/컨테이너만 실패시키고 나머지 두 브로커로 쓰기·읽기·후속 처리가 계속되는지 관측한다.

### 2.2 Failure Question

> `acks=all`, RF=3, `min.insync.replicas=2`, 비정상 리더 선출(unclean leader election) 비활성화 조건에서 ISR에 속한 브로커 하나가 중단될 때, Kafka가 정합성 경계를 낮추지 않고 리더를 재선출하여 `barcode-events`의 생산과 소비를 지속하며, 브로커 복귀 후 복제와 전체 바코드 파이프라인이 유실·미정 상태 없이 다시 수렴하는가?

이 질문은 한 번의 경계가 정해진 로컬 실험에만 답한다. Kafka 또는 전체 시스템의 일반적인 고가용성 보장으로 확대하지 않는다.

## 3. 장애 영역과 토폴로지 계약

### 3.1 주 장애 영역

주 장애 영역(Primary Failure Domain)은 **브로커 1개의 Kafka 프로세스와 그 컨테이너 실행 경계**다. 전용 KRaft 컨트롤러, 나머지 브로커 2개, 애플리케이션, Redis, MySQL은 장애 주입 대상이 아니다. 브로커 로컬 영구 볼륨은 브로커별로 분리하여 한 브로커의 저장소 경계가 다른 브로커와 공유되지 않게 한다.

### 3.2 KRaft 프로세스 분리

- controller: `process.roles=controller`인 전용 KRaft 컨트롤러 1개
- broker-1, broker-2, broker-3: 각각 `process.roles=broker`인 broker-only 프로세스
- 네 프로세스는 서로 다른 `node.id`를 사용한다.
- 모든 브로커는 동일한 단일 컨트롤러 quorum voter 구성을 참조한다.
- controller listener는 컨트롤러 quorum 통신에만 사용하고 애플리케이션 bootstrap으로 노출하지 않는다.

컨트롤러가 한 개인 구조는 **브로커 프로세스 하나의 실패**를 분리해 검증하기 위한 토폴로지다. 컨트롤러 고가용성이나 컨트롤러 장애 내성은 검증하지 않는다.

### 3.3 `barcode-events` 계약

| 항목 | 승인 값 | 책임 |
|---|---:|---|
| partitions | `3` | 세 파티션의 리더/복제 상태를 개별 관측한다. |
| replication factor | `3` | 각 파티션 replica를 세 브로커에 둔다. |
| `min.insync.replicas` | `2` | ISR 두 개 미만에서는 `acks=all` 쓰기를 성공으로 승인하지 않는다. |
| producer `acks` | `all` | Ingest가 현재 ISR의 승인 없이 성공을 반환하지 않게 한다. |
| `unclean.leader.election.enable` | `false` | 최신 상태가 보장되지 않는 replica의 리더 승격으로 가용성을 높이지 않는다. |
| automatic topic creation | `false` | 승인되지 않은 기본 partition/RF 값으로 계약 토픽이 선점되는 것을 막는다. |

`barcode-events`는 전용 topic initializer가 `partitions=3`, RF=3, `min.insync.replicas=2`로 명시적으로 생성하고 describe 결과로 계약을 검증한 뒤에만 Ingest와 Processing이 시작될 수 있어야 한다. 생성 명령의 성공만으로 충분하지 않으며, 실제 토픽 설정과 각 파티션의 replica 배치를 확인해야 한다.

### 3.4 내부 토픽 경계

- `offsets.topic.replication.factor=3`
- `transaction.state.log.replication.factor=3`
- `transaction.state.log.min.isr=2`

현재 애플리케이션이 Kafka 트랜잭션을 사용한다는 주장이 아니라, 세 브로커 토폴로지에서 Kafka 내부 토픽이 단일 브로커 경계로 축소되지 않도록 구성하는 방어적 설정이다.

### 3.5 listener와 bootstrap 경계

- 브로커 간 통신 및 Compose 네트워크 내부 클라이언트에는 broker별 내부 listener와 broker DNS 이름을 사용한다.
- 호스트 진단에는 broker별로 충돌하지 않는 host listener/port를 사용한다.
- advertised listener는 접속 경계별로 실제 도달 가능한 주소를 광고해야 한다. 컨테이너 클라이언트에 `localhost`를 광고하거나 호스트 클라이언트에 Compose 전용 DNS 이름만 광고해서는 안 된다.
- Ingest와 Processing은 `broker-1`, `broker-2`, `broker-3`의 내부 listener를 모두 포함한 다중 브로커 bootstrap 목록을 받는다.
- 이 override는 BIP-FR-002 Compose 환경 변수에만 둔다. 루트 단일 브로커 Compose와 BIP-FR-001 산출물은 변경하지 않는다.

## 4. 장애 주입 경계

후속 실행 단계에서 허용될 장애 주입은 사전에 식별한 **브로커 컨테이너 하나의 Kafka 프로세스 실패**뿐이다. 주입 전 대상 브로커의 node ID, container ID, `barcode-events` 파티션 리더/replica/ISR 상태를 기록해야 한다.

다음 조건을 지켜야 한다.

- 한 번에 브로커 하나만 실패시킨다.
- controller, 다른 브로커, Ingest, Processing, Scanner, Redis, MySQL, worker에는 장애를 주입하지 않는다.
- 브로커 데이터 볼륨을 삭제·초기화·교체하지 않는다.
- topic, partition, replica assignment, consumer offset, Redis PEL, DB row를 실험 중 수동 변경하지 않는다.
- 가용성을 만들기 위해 `min.insync.replicas`, RF, `acks`, unclean leader election 설정을 완화하지 않는다.

구체적인 실패 명령과 Material Run은 Phase A의 권한 밖이다.

## 5. 사전 조건(Preconditions)

Material Run 전 다음 조건이 모두 Evidence로 확인되어야 한다.

1. 실행 checkout과 승인 커밋/브랜치가 기록되고 작업 트리 오염 여부가 확인된다.
2. 전용 controller 1개와 broker 3개가 각자 승인된 role과 고유 node ID로 실행 중이다.
3. controller quorum 상태에서 leader와 voter가 확인되고 세 브로커가 controller에 등록되어 있다.
4. `barcode-events`가 정확히 3 partitions, RF=3, `min.insync.replicas=2`이고 모든 파티션의 ISR 크기가 3이다.
5. `unclean.leader.election.enable=false`와 automatic topic creation 비활성화가 유효 설정에서 확인된다.
6. Ingest producer의 `acks=all`과 Ingest/Processing의 3개 broker bootstrap 주소가 유효 설정 또는 startup log에서 확인된다.
7. application readiness뿐 아니라 실제 bounded healthy traffic이 Kafka → Processing → Redis → worker → MySQL로 진행되고 Kafka consumer lag, Redis group lag/PEL이 안정적으로 수렴한다.
8. 장애 전 생성 이벤트 식별자 집합과 Kafka offsets, Redis stream/group, MySQL, DLT/DLQ의 baseline을 보존한다.
9. 장애 대상은 현재 broker/partition 상태를 근거로 명확히 식별하며, 동시에 다른 failure signal이나 under-replicated partition이 없어야 한다.

하나라도 충족하지 못하면 장애를 주입하지 않고 실험을 무효로 판정한다.

## 6. 관측 증거(Observable Evidence)

Evidence는 wall-clock/UTC 시간과 명령을 함께 보존하며 최소한 다음을 포함한다.

| 계층 | 필수 증거 |
|---|---|
| 실행 정체성 | Git SHA/branch/status, Compose project/config, image/container/node ID, volume mapping |
| KRaft/controller | quorum status, leader/voter, broker registration 또는 이에 준하는 controller/broker log |
| 토픽 메타데이터 | `barcode-events`의 TopicId, partition별 Leader/Replicas/ISR, RF, partition 수, `min.insync.replicas` |
| 복제 건전성 | under-replicated partition 및 offline partition의 장애 전·중·복구 후 변화 |
| 생산 경로 | Ingest startup bootstrap/acks 설정, send 성공·실패·timeout, partition/offset, HTTP 결과 |
| 소비 경로 | Processing consumer assignment/rebalance, consume 성공·오류, group offset/end offset/lag, DLT |
| 후속 경로 | Redis stream length/group lag/PEL/DLQ, worker 처리·재시도, MySQL 고유 식별자 집합 |
| 장애 타임라인 | 주입 대상과 시각, broker/container 상태, leader 재선출, 영향 최초 관측, broker 복귀, ISR 복구 시각 |

프로세스가 `running`이라는 사실, 단일 health endpoint, 단일 lag 샘플 또는 단일 row count만으로 성공이나 복구를 확정하지 않는다.

## 7. 판정 기준

### 7.1 성공(Success)

다음 조건이 모두 충족되어야 한다.

1. 사전 조건과 장애 주입 경계가 지켜져 실험이 유효하다.
2. 브로커 하나의 실패 뒤 `barcode-events`의 영향받은 파티션이 ISR에 있던 다른 replica를 clean leader로 선출한다.
3. 장애 중 ISR은 각 파티션에서 2로 축소될 수 있으나 2 미만으로 내려가지 않고 offline partition이 없다.
4. `acks=all` 생산과 Processing 소비가 허용된 관측 시간 안에 나머지 두 브로커로 지속 또는 자동 재개되며, 단일 bootstrap endpoint 실패 때문에 애플리케이션을 재설정하거나 재시작하지 않는다.
5. 실패 브로커 복귀 후 모든 파티션의 ISR이 3으로 회복되고 under-replicated partition이 0으로 안정된다.
6. Recovery Complete와 end-to-end reconciliation 기준을 모두 통과한다.

### 7.2 실패(Failure)

유효한 실험에서 다음 중 하나라도 발생하면 실패다.

- clean leader를 선출하지 못해 허용 시간 동안 partition이 offline으로 남는다.
- ISR이 2 이상인데도 단일 브로커 실패가 지속적인 생산/소비 불능을 만든다.
- `acks=all` 또는 `min.insync.replicas=2` 경계를 완화해야만 흐름이 재개된다.
- 브로커 복귀 후 ISR/under-replicated partition이 허용 시간 안에 수렴하지 않는다.
- 생성한 논리 이벤트에 최종 missing, unaccounted, 예상 밖 extra/final duplicate가 남거나 DLT/DLQ/PEL/retry가 해소되지 않는다.

### 7.3 무효 실험(Invalid Experiment)

다음은 시스템 실패가 아니라 실험 무효다.

- 승인된 Git/Compose/config가 아닌 상태로 실행했다.
- `barcode-events`가 자동 생성됐거나 partitions/RF/minISR 중 하나라도 계약과 다르다.
- 장애 전 세 broker, 전체 ISR, healthy flow가 성립하지 않았다.
- 둘 이상의 broker 또는 controller/애플리케이션/데이터 저장소가 함께 실패했다.
- 데이터 볼륨 삭제, topic 재생성, offset reset, replay, PEL/DB 수동 변경 등 금지된 조치가 개입했다.
- 대상·시각·broker/topic/application evidence가 부족하여 인과관계를 판정할 수 없다.
- 호스트 자원 고갈 또는 검증 토폴로지 밖의 장애가 결과를 지배했다.

## 8. Recovery Complete 기준

브로커 컨테이너가 다시 `running`인 것만으로 복구 완료(Recovery Complete)를 선언하지 않는다. 다음 네 계층이 모두 연속된 terminal sample에서 안정적으로 충족되어야 한다.

1. **구성 요소 복구(Component Recovery)**: 복귀한 broker의 동일 node ID와 broker-local volume 경계가 확인되고 controller에 등록된다. 모든 `barcode-events` partition의 ISR이 3, under-replicated/offline partition이 0이다.
2. **흐름 복구(Flow Recovery)**: 새 bounded post-recovery 이벤트가 Kafka에 append되고 Processing, Redis, worker, MySQL까지 진행한다.
3. **백로그 소진(Backlog Drain)**: Kafka consumer lag, Redis group lag/PEL, Scanner retry, DLT/DLQ가 0 또는 사전에 설명된 terminal 값으로 연속 수렴한다.
4. **전체 정합성 확인(End-to-end Reconciliation)**: 아래 식별자 집합 기반 정합성 기준이 통과한다.

## 9. End-to-end reconciliation 기준

healthy, broker-failure, post-recovery 구간별 생성 논리 이벤트의 고유 barcode 식별자 manifest를 보존하고, 단순 건수뿐 아니라 집합으로 대조한다.

```text
generated unique identities
  = final MySQL unique identities
  + explicitly accounted terminal DLQ identities
  + explicitly accounted terminal DLT identities
  + explicitly accounted pending/retry identities
  + unaccounted identities
```

성공 시 generated identity 집합과 최종 MySQL identity 집합이 일치하고, missing, unaccounted, 예상 밖 extra, final duplicate, terminal DLQ/DLT/pending/retry가 모두 0이어야 한다. Kafka transport record 수는 확인 불확실성이나 재시도로 논리 이벤트 수보다 클 수 있으므로 별도로 계량하며, 이를 곧바로 business duplicate 또는 데이터 유실로 해석하지 않는다. Redis dedupe와 MySQL unique 제약의 관측 결과를 함께 사용한다.

## 10. Maximum Intended Claim

모든 기준을 충족한 경우 허용되는 최대 주장(Maximum Intended Claim)은 다음과 같다.

> 승인된 로컬 BIP-FR-002 토폴로지와 bounded traffic/run에서, 전용 controller가 유지되는 동안 3-broker Kafka cluster의 broker 하나가 실패해도 RF=3, `min.insync.replicas=2`, producer `acks=all`, unclean leader election 비활성화 경계 안에서 `barcode-events`가 clean leader election을 거쳐 생산·소비를 지속 또는 자동 재개했고, 동일 broker 복귀 후 ISR과 전체 바코드 처리 흐름이 식별자 수준에서 수렴했다.

이 주장은 해당 run의 직접 Evidence와 관측 시간 경계에만 적용된다.

## 11. Explicit Non-Claims

이 실험과 문서는 다음을 주장하지 않는다.

- production-grade Kafka 또는 전체 시스템의 고가용성, SLA, RTO, RPO
- controller 장애 내성 또는 controller quorum 고가용성
- broker 2개 이상 동시 장애, 네트워크 partition, disk corruption/full, host 장애, rack/AZ 장애 내성
- broker 데이터 볼륨 삭제·유실·재생성 상황의 durability
- 모든 Kafka topic 또는 모든 partition assignment에서 동일한 결과
- Kafka → Redis → MySQL의 exactly-once 보장
- 각 논리 이벤트의 transport record가 정확히 한 번만 생성·처리된다는 보장
- 임의 부하, 장시간 soak, capacity, 성능 또는 failover 시간의 운영 보장
- Scanner/Processing/Redis/MySQL/worker 장애가 결합된 경우의 복구 능력
- 단일 로컬 Material Run 결과를 다른 Kafka 버전, 이미지, 인프라 또는 운영 환경에 일반화

## 12. Implementation Phase A 금지 행위

Phase A에서는 다음을 수행하지 않는다.

- Docker Compose `up`, `start`, `run` 또는 이에 준하는 healthy-cluster startup
- `SIGKILL`, `docker kill`, broker stop/restart 등 장애 주입
- Material Run 또는 트래픽 생성
- probe scan과 런타임 readiness/health 수집
- 최종 reconciliation 또는 결과 보고서 작성
- root single-broker Compose, BIP-FR-001 문서·Compose·evidence 수정
- 전역 애플리케이션 source/config를 HA 시나리오 때문에 변경
- topic/offset/replica/Redis/MySQL 상태 변경 도구를 증거 수집 스크립트에 포함
- 승인된 토폴로지·실패 영역·판정 기준을 확장하거나 완화

Phase A 종료점은 전용 산출물의 구현과 정적 검증 결과를 사람이 검토할 수 있게 보고한 시점이다. 다음 Human Gate 전에는 healthy-cluster startup으로 진행하지 않는다.
