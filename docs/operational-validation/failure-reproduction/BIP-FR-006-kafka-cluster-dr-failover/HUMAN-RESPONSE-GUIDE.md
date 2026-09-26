# BIP-FR-006 인간 개발자 장애 대응 판단 안내서

> 상태: `FINAL — HUMAN CONFIRMED`
> 용도: Kafka cluster 전체 장애가 의심될 때 진단과 책임 이전을 결정하는 사고 순서
> 주의: 조직의 실제 DR 권한, 데이터 정책과 서비스 목표는 해당 운영 계약에서 확인한다.

## Symptom — 무엇이 멈췄는가

Producer acknowledgement 실패, consumer 진행 정지, Kafka 접속 오류가 동시에 나타날 수 있다. 먼저 새 요청의 수용 여부와 이미 수용된 요청의 처리 위치를 분리한다. HTTP 응답, application log, Kafka 상태, Redis와 MySQL 결과는 서로 다른 경계를 보여준다. 하나의 health 신호만으로 장애 영역을 확정하지 않는다.

## Initial Triage — 영향을 받는 범위

- Controller quorum과 broker process가 응답하는가?
- Topic별 leader, ISR, under-replicated/unavailable partition은 어떻게 변했는가?
- 새 `acks=all` 쓰기와 기존 consumer 진행이 가능한가?
- 문제는 A만인가, B 또는 공유 Redis/MySQL까지 번졌는가?
- 첫 실패 시각, 마지막 producer acknowledgement, 마지막 durable 저장 시각을 보존했는가?

명령은 해당 환경의 Kafka metadata/topic/group 조회, application log와 downstream 조회를 돕는 수단이다. 조회 결과가 어떤 책임 경계를 확인하는지 먼저 정한다.

## Failure-domain Narrowing — 어느 장애인가

| 가설 | 구별할 관측 | 대응 의미 |
|---|---|---|
| broker 한 대 또는 leader 장애 | controller와 다른 broker 가용, 새 leader·ISR 확인 | 같은 cluster의 broker-level HA 가능성을 먼저 평가 |
| insufficient ISR | leader는 있어도 ISR이 `min.insync.replicas` 아래로 감소 | 쓰기 거절은 데이터 안전성 경계일 수 있으므로 무리한 설정 완화 금지 |
| controller 문제 | metadata/quorum 이상, broker 관측과 불일치 가능 | controller 복구 가능성과 partition 상태를 함께 확인 |
| A whole-cluster 불가 | A controller와 모든 broker 사용 불가, A 경로 진전 없음 | A 내부 broker 교체만으로는 서비스 경로가 복구되지 않음 |
| 공유 downstream 장애 | Kafka는 진행하지만 Redis/MySQL 정체 | Kafka DR로 해결할 문제가 아님 |

FR-006은 A controller 1개와 broker 3개가 모두 불가해진 네 번째 경계를 재현했다. 실제 운영에서는 host, network, storage, 인증 또는 접속 경로 장애도 같은 증상을 낼 수 있으므로 관측으로 좁힌다.

## Hypothesis Verification — B가 책임을 받을 준비가 됐는가

A를 요구 서비스 시간 안에 복구할 수 있는지, B로 넘기는 편이 허용 가능한 위험인지 판단한다. B의 process가 healthy하다는 것만으로 준비가 끝나지 않는다.

1. B의 controller/broker/topic이 정상이고 새 쓰기를 승인할 수 있는가?
2. MM2 A→B 복제의 마지막 확인 시점과 B topic의 실제 레코드 집합은 무엇인가?
3. A가 승인한 식별자 중 B에 없고 downstream에도 durable하지 않은 것은 무엇인가?
4. B consumer group에 이미 active member가 있어 이중 처리가 일어나지 않는가?
5. checkpoint/offset-sync와 B group offset은 같은 처리 경계를 가리키는가?
6. B consumer의 예상 시작 위치에서 replay와 누락 위험은 각각 얼마인가?
7. Redis, persistence worker, MySQL이 새 책임을 감당할 수 있는가?

B에 데이터가 있어도 consumer가 어디서 이어야 할지 모르면 안전한 failover 결정을 내릴 수 없다. A/B raw offset 수치만 비교하지 말고 논리 식별자, checkpoint와 B의 실제 소비 시작을 연결한다.

| 확인 결과 | 다음 판단 |
|---|---|
| B의 데이터·시작 offset·미완료 identity가 함께 설명됨 | A의 이중 활성 위험을 차단한 뒤 B consumer 전환을 진행할 수 있다. |
| B는 가용하지만 checkpoint 또는 시작 offset이 설명되지 않음 | B consumer를 자동으로 시작하지 않는다. Evidence를 보존하고 replay·누락 가능 범위와 승인된 처리 방식을 결정한다. |
| RPO 노출 identity가 불명확함 | 노출을 0으로 보고하지 않는다. A 복구와 B 전환의 시간·데이터 위험을 비교하고 미설명 집합을 추적한다. |
| Redis 또는 MySQL이 가용하지 않음 | B의 쓰기 성공과 종단 간 복구를 분리해 판단하고 downstream 복구 책임을 연다. |

## Recovery Decision — 책임 이전을 결정하는 조건

사람의 판단은 허용 가능한 서비스 중단 시간, 잠재 RPO 노출, replay/중복 처리의 비즈니스 영향, 되돌리기 조건과 실제 운영 권한에 놓인다. A 복구가 서비스 시간 안에 가능하다면 그 경로의 위험을 비교한다. B를 택하면 A producer/consumer를 fencing하여 이중 활성 상태를 방지하고, 확인한 offset 경계와 Evidence를 보존한다. 불확실한 노출 식별자는 “손실 0”으로 단정하지 않고 조사 대상으로 남긴다.

FR-006의 재현 계약은 로컬 Active/Passive 환경에서 명시적 failover를 허용했다. 실제 운영의 자동 전환 정책이나 권한을 이 실험에서 유추해서는 안 된다.

## DR Failover — 무엇을 순서대로 확인하는가

1. A의 처리 책임을 중지하거나 격리하여 이중 쓰기·이중 소비 위험을 통제한다.
2. B producer 경로를 활성화하고 **새 identity의 acknowledgement**를 확인한다. 이것은 publication recovery다.
3. B consumer를 확인한 offset 경계에서 활성화하고 실제 첫 소비 위치를 확인한다.
4. Processing → Redis Streams → persistence worker → MySQL의 새 identity 진행을 추적한다.
5. Kafka lag, Redis lag/PEL/DLQ, 실패·격리된 identity와 재시도 결과를 관찰한다.

FR-006에서는 B producer 첫 acknowledgement까지 `103.613초`, 첫 post-failover MySQL 저장까지 `181.420272초`가 관측됐다. 이 값은 로컬 수동 절차의 결과이며 운영 목표나 보장이 아니다. [재현 기록](./REPRODUCTION-RECORD.md#7-fault-및-failover-타임라인).

## Recovery Complete — 무엇을 대사해야 하는가

`Cluster B healthy`는 복구 완료(Failover Complete)의 한 조건일 뿐이다. 다음을 함께 충족해야 한다.

- B의 새 쓰기와 consumer 진행이 확인된다.
- consumer 시작 위치가 checkpoint/offset 경계와 설명 가능하다.
- Kafka·Redis의 미처리 작업과 PEL/DLQ가 허용 기준으로 수렴한다.
- A가 승인한 pre-fault identity의 B 복제·downstream durable 여부와 RPO exposure가 집합으로 설명된다.
- replay와 duplicate가 식별되고 dedupe 또는 보정 결과가 검증된다.
- 최종 수용 identity마다 MySQL 저장, DLT/quarantine 또는 명시적 미완료 상태가 설명된다.

FR-006의 최종 대사는 accepted 41건, MySQL unique 41건, unaccounted 0건이었다. 관측된 RPO exposure와 replay는 각각 0건이다. 약 20초 quiet window 때문에 이 값으로 zero-RPO를 보장할 수 없고, Evidence Sufficiency는 `PARTIAL`이다. [정합성 집계](./evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/13-counts.txt), [재현 기록](./REPRODUCTION-RECORD.md#11-evidence-충분성).
