# BIP-FR-006 장애 시나리오 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: Kafka HA와 cluster-level DR의 차이를 이해하고 FR-006 Evidence를 해석하려는 개발자

## 이 장애가 다른 이유

`broker-level HA ≠ cluster-level DR`

FR-002는 같은 Kafka cluster에서 leader broker 하나가 실패할 때 동기화된 다른 broker가 leader가 되는 경계를 다뤘다. cluster의 controller, 나머지 broker와 공통 접속 경로가 살아 있다는 전제가 있다. FR-003의 insufficient ISR은 복제본 수가 쓰기 승인 조건에 못 미치는 별도 쓰기 안전성 문제다. 어느 쪽도 **Cluster A 전체를 사용할 수 없을 때** A 밖에서 데이터를 읽고 새 쓰기를 받을 책임을 자동으로 제공하지 않는다.

FR-006에서는 A의 controller 1개와 broker 3개를 함께 중단했다. B는 별도 Kafka cluster ID와 접속 경로를 가진 DR 대상이다. 다만 같은 호스트의 Docker 위에 있어 물리적 장애 영역 분리는 검증하지 않았다.

## 토폴로지와 평상시 책임

`Scanner → Ingest A → Kafka A → Processing A → Redis Streams → Persistence Worker → MySQL`

- Primary Cluster A: dedicated controller 1개와 broker 3개, application topic RF=3, `min.insync.replicas=2`.
- DR Cluster B: broker/controller 1개, application topic RF=1. B의 broker HA는 검증 대상이 아니다.
- MirrorMaker 2(MM2): `barcode-events`와 `barcode-events-dlt`를 A에서 B로 단방향 복제하고, consumer group의 checkpoint와 offset-sync 정보를 만든다.
- Active/Passive: 장애 전 producer와 consumer 책임은 A에 있고 B consumer는 비활성이다. B에 데이터가 있다는 사실만으로 B가 처리 책임을 갖는 것은 아니다.
- Redis, persistence worker, MySQL은 두 Kafka 경로가 공유하는 downstream이다. FR-006 fault 동안 이 경로가 가용하다는 전제가 있다.

자세한 고정 구성과 정량 정의는 [재현 계약](./REPRODUCTION-CONTRACT.md)에 있다.

## 데이터 복제와 소비 위치는 다른 문제

MM2가 B에 레코드를 복제해도 B consumer가 **어느 partition의 어느 위치부터** 처리할지 별도로 결정해야 한다. A의 raw offset을 B의 offset으로 그대로 복사할 수 있다고 가정하면 복제 지연, topic의 기존 레코드, checkpoint 시점 때문에 replay 또는 누락 위험이 생긴다. checkpoint/offset translation과 B의 실제 group offset, topic end offset, application 시작 로그를 함께 확인해야 한다.

이번 fault 경계에는 A에서 승인된 pre-fault 식별자 30건이 B와 MySQL에도 모두 확인됐다. B의 `barcode-processing-group`에는 active member가 없었고, partition 1의 current offset과 log end offset이 모두 37이었다. Material Run 전 Preflight의 레코드 7건 뒤에 이번 Run에서 A가 승인한 30건이 이어졌으므로, offset 37은 Material Run 식별자 37건이 아니라 다음 소비 위치다. B consumer는 partition 1 offset 37에서 시작해 B로 새로 발행한 레코드를 처음 소비했다. 따라서 이번 실행에서 관측된 replay는 0건이다. [경계 Evidence](./evidence/BIP-FR-006-MR-20260923T042048Z/04-b-boundary.txt), [시작 로그](./evidence/BIP-FR-006-MR-20260923T042048Z/09-b-processing-start-and-first-consumption.log).

## 장애부터 책임 이전까지

1. 정상 A/B 상태와 MM2 복제를 확인하고 A 경로로 트래픽을 발행했다.
2. A controller와 broker 3개를 모두 중단했다. B, Redis, MySQL은 계속 가용했다.
3. B의 데이터와 consumer offset 경계를 확인한 뒤 A application 책임을 정지했다.
4. Ingest B를 시작해 B에 대한 새 producer acknowledgement를 확인했다.
5. Processing B를 시작해 offset 37에서 소비가 재개되고 MySQL에 새 식별자가 저장되는 것을 확인했다.
6. Kafka group/Redis 백로그와 식별자 집합을 대사했다.

이것은 명시적·수동 운영 failover다. B가 healthy하다는 사실이나 producer의 첫 응답만으로 처리 책임 이전 또는 복구 완료를 선언할 수 없다.

## 시간과 데이터 손실 노출의 해석

[재현 계약](./REPRODUCTION-CONTRACT.md#정량-정의)은 두 시간을 분리한다.

| 지표 | 시작과 끝 | 관측값 |
|---|---|---:|
| Publication Recovery | `t_A_unavailable` → B producer의 첫 acknowledgement | `103.613초` |
| Observed Failover RTO | `t_A_unavailable` → 첫 post-failover MySQL 저장 | `181.420272초` |

복구 시점 목표(RPO) 노출은 A가 승인한 pre-fault 논리 식별자 중 B에서도 확인되지 않고 이미 downstream에 durable하게 완료되지도 않은 집합으로 계산한다. 이는 raw A/B offset 차이나 최종 손실 건수와 동일하지 않다. 이번 실행의 관측된 RPO exposure는 **0건**이지만, 마지막 A 요청 완료와 fault 사이 약 20초 quiet window가 있어 복제 중인 레코드가 끊기는 경계를 강하게 시험하지 못했다. 따라서 zero-RPO 보장은 성립하지 않는다.

## 중복과 downstream 완료

B transport duplicate identity, Processing duplicate observation, Redis dedupe 재처리, replay는 이번 실행에서 각각 0건이었다. 이는 특정 시점과 트래픽에서 관측된 값이다. checkpoint 주기와 장애 시점이 달라지면 replay 또는 RPO 노출이 생길 수 있고, exactly-once failover를 뜻하지 않는다.

최종 대사는 accepted logical identities 41건 = B 확인 41건 = MySQL unique 41건으로 수렴했다. fault 전 30건이 저장됐고 failover 후 11건이 B에 직접 발행되어 저장됐다. DLT, quarantine, 미설명 식별자는 각각 0건이었다. [정합성 집계](./evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/13-counts.txt).

복구 완료(Failover Complete)는 B cluster 가용성, producer의 B 쓰기 성공, consumer의 설명 가능한 위치에서의 재개, Processing → Redis → MySQL 진행, 백로그 수렴과 전체 식별자 대사가 함께 성립하는 상태를 뜻한다. Redis나 MySQL의 실패가 남아 있다면 Kafka failover 성공만으로 종단 간 서비스 복구를 주장할 수 없다.

## 검증 범위와 남은 공백

Material Run의 Outcome은 `REPRODUCED`, Experiment Validity는 `PASS`, Evidence Sufficiency는 `PARTIAL`이다. fault 후 A-targeted HTTP 실패는 별도로 실행하지 않았고, MM2 REST status 및 raw checkpoint record 대신 process/log, internal topic, target group offset과 실제 소비 시작으로 연속성을 확인했다.

이 로컬 결과는 물리적 multi-DC/multi-region DR, B cluster HA, 자동 failover, production-scale RTO, zero-RPO 또는 exactly-once failover를 입증하지 않는다. 자세한 판정과 제한은 [재현 기록](./REPRODUCTION-RECORD.md#12-검증된-재현-주장과-제한)을 따른다.
