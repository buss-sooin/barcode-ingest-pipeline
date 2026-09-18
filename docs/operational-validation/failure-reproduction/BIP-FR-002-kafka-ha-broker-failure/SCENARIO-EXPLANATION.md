# BIP-FR-002 장애 시나리오 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: Kafka를 운영하지만 이번 검증을 수행하지 않은 개발자

## 먼저 알아야 할 Kafka 구조

Kafka는 하나의 큰 log가 아니라 여러 partition으로 데이터를 나눈다. 각 partition에는 요청을 처리하는 leader와 그 데이터를 복제하는 follower가 있다.

```text
                         KRaft controller
                  broker 상태 확인·leader 선출
                              │
                              ▼
Producer ── write ──> barcode-events / partition 1 ── read ──> Consumer
                              │
                    ┌─────────┼─────────┐
                    │         │         │
              broker-2   broker-3   broker-1
                Leader    Follower   Follower
                 [ISR]      [ISR]      [ISR]
                    └────── data replication ──────┘
```

- **Partition**: 데이터를 나눠 저장하고 처리하는 단위다.
- **Leader**: 해당 partition의 생산과 소비 요청을 처리하는 기준 replica다.
- **Follower replica**: leader의 log를 복제하고, 필요할 때 새 leader 후보가 된다.
- **ISR(In-Sync Replicas)**: leader의 log를 충분히 따라가고 있는 replica 집합이다.
- **KRaft controller**: broker 상태와 metadata를 관리하고 leader 변경을 조정한다.

복제본 수가 3이라는 사실만으로 세 replica가 모두 최신이라는 뜻은 아니다. 장애 순간에는 새 leader가 될 수 있는 ISR 수와 쓰기 승인 조건이 중요하다.

FR-002의 설정과 전이는 다음과 같다.

```text
[정상]
leader=broker-2, ISR=[2,3,1], RF=3
                │ broker-2 실패
                ▼
[장애 감지와 전환]
controller가 broker-2 fencing → ISR의 broker-3을 clean leader로 선출
                ▼
[저하 상태]
leader=broker-3, ISR=[3,1]
ISR 2개가 min.insync.replicas=2를 충족하므로 acks=all 쓰기 가능
                │ broker-2 복구·log catch-up
                ▼
[중복성 복원]
leader=broker-3, ISR=[3,1,2], URP=0, unavailable=0
```

따라서 broker 한 대의 실패와 서비스 전체의 write outage는 같은 사건이 아니다. 남은 ISR과 설정 경계에 따라 Kafka는 저하 상태에서도 처리를 이어갈 수 있다.

## 장애를 유발할 수 있는 운영 원인

운영에서 leader broker가 사용할 수 없게 되는 원인은 하나가 아니다.

| 예상 원인 | 운영에서 보이는 공통 결과 | FR-002와의 관계 |
|---|---|---|
| Kafka process crash, JVM 오류 또는 OOM | broker 응답 중단, leader 재선출 필요 | process 종료라는 결과는 유사하지만 Strict Run은 OOM이 아니었음 |
| container·pod 강제 종료 또는 잘못된 배포 | broker session 상실과 client 재연결 | SIGKILL로 이 경계를 직접 재현 |
| host 재부팅·장애 | 해당 host의 broker와 storage/network 경로 상실 | broker unavailable 결과만 공통이며 host 장애 자체는 미검증 |
| network 단절·과도한 지연 | controller fencing, replica의 ISR 이탈 가능 | network partition과 지연 조건은 미검증 |
| disk full, I/O stall 또는 corruption | replica 지연, log directory 실패, broker 중단 가능 | storage failure와 데이터 손실은 미검증 |

FR-002는 이 원인을 모두 재현하지 않는다. 대신 여러 운영 장애가 공통으로 만드는 **단일 leader broker 사용 불가** 상태를 통제된 방식으로 만들고, Kafka와 애플리케이션이 그 상태에 어떻게 반응하는지를 검증했다.

## 로컬 검증이 운영에서도 가치가 있는 이유

FR-001부터 향후 FR-006까지의 공통 원칙은 production 환경 전체를 로컬 PC에 복제하는 것이 아니다. 제한된 자원에서도 운영 장애와 동일하게 판정할 수 있는 메커니즘과 불변조건(Invariant)을 추출해 검증하는 것이다.

```text
다양한 production 장애 원인
        │ 공통 실패 효과 추출
        ▼
로컬의 통제된 fault injection
        │ 실제 제품 설정·protocol·application flow 사용
        ▼
운영에서도 필요한 불변조건 검증
        │ 상태 전이 + 처리 지속성 + 최종 데이터 대사
        ▼
Evidence가 허용하는 범위만 주장
```

모든 FR 시나리오는 공통적으로 다음 세 계층을 확인한다.

1. 의도한 장애만 발생했고 실험 조건이 유효한가.
2. middleware와 application이 기대한 상태 전이와 복구를 수행했는가.
3. 최종 데이터가 유실·미정 상태 없이 수렴했는가.

FR-002의 차별점은 **복제 여유가 남은 상태의 단일 leader broker 실패**다. 실제 Kafka software, leader election, ISR, `acks=all`, client 재연결과 애플리케이션 dedupe를 사용했으므로 이 메커니즘과 확인 순서는 운영에서도 그대로 유효하다.

다만 검증 범위의 등가성과 환경 전체의 등가성은 구분해야 한다.

| 운영과 공통으로 검증한 것 | 로컬 환경 때문에 검증하지 못한 것 |
|---|---|
| 실제 clean leader election과 ISR 변화 | rack·AZ·host가 분리된 failure domain |
| `RF=3`, `min.insync.replicas=2`, `acks=all` 안전성 경계 | controller quorum HA |
| broker down 상태의 생산·소비와 downstream 처리 | production 규모의 부하·soak·failover 시간 |
| replica catch-up과 복구 완료 조건 | network partition, disk 손실·손상 |
| 요청 재전송, dedupe와 최종 identity 대사 | production SLA, RTO와 RPO |

따라서 이 실험은 production과 같은 시간 성능이나 전체 인프라 장애 내성을 증명하지 않는다. 대신 HA 설계가 실제로 작동하는지, 어떤 Evidence로 장애와 복구를 판단해야 하는지, 중복을 애플리케이션이 흡수하는지를 운영에 적용 가능한 수준으로 검증한다.

## 무엇을 검증했는가

BIP-FR-002는 active traffic 중 `barcode-events` partition 1의 leader인 broker 2를 강제 종료하고, 나머지 broker가 데이터 안전성 설정을 낮추지 않은 채 처리를 이어가는지 검증한 시나리오다.

leader 재선출뿐 아니라 broker down 상태의 새 쓰기와 downstream 처리, broker 복귀 후 replica 재동기화, 최종 데이터 수렴까지 검증했다. 최종 판정은 `STRICT PASS`다.

## 검증 경계

| 항목 | 검증 값 | 의미 |
|---|---:|---|
| Kafka broker | 3 | broker 한 대 실패 후 두 대가 남음 |
| KRaft controller | 1 | controller 장애는 이번 범위가 아님 |
| partition | 3 | partition별 leader와 ISR 관찰 |
| replication factor | 3 | 각 partition을 세 broker에 복제 |
| `min.insync.replicas` | 2 | ISR이 2개 미만이면 안전한 쓰기를 승인하지 않음 |
| producer `acks` | `all` | 현재 ISR의 승인을 받아야 쓰기 성공 |
| unclean leader election | `false` | 최신 상태가 보장되지 않는 replica 승격 금지 |

핵심 경계는 broker 한 대 실패 후에도 ISR 2개가 남아 `min.insync.replicas=2`를 충족하는 상태다. ISR을 2 미만으로 떨어뜨려 write availability 상실을 검증하는 것은 BIP-FR-003의 책임이다.

## 검증 도구와 기술

- Docker Compose: 시나리오 전용 Kafka와 애플리케이션 환경
- Kafka CLI: controller quorum, topic, ISR, URP, unavailable partition, consumer lag 확인
- bounded traffic driver: 장애 전·중·후 논리 이벤트 생성
- application logs: producer acknowledgment, processing, 중복 검출과 downstream 진행 확인
- Redis와 MySQL 대사: pending, DLQ와 최종 고유 identity 확인
- `capture-kafka-ha-state.sh`: 상태와 로그를 시각이 포함된 Evidence로 보존

## 어떻게 검증했는가

1. broker 3대, 전체 ISR과 정상 end-to-end flow를 확인했다.
2. partition 1의 leader가 broker 2임을 확인한 뒤 active traffic 중 SIGKILL했다.
3. broker 3의 clean leader 선출과 broker down 상태의 새 `acks=all` 쓰기·downstream 처리를 확인했다.
4. broker 2만 기존 volume으로 복구하고 ISR, URP, unavailable partition과 새 traffic을 확인했다.
5. 생성 identity와 최종 MySQL identity, DLT·DLQ·pending을 대조했다.

## 무엇이 관찰됐는가

### Kafka 상태 전이

| 관찰 항목 | 결과 |
|---|---|
| 장애 대상과 방식 | `broker-2`, SIGKILL, exit 137, OOM 아님 |
| leader 전환 | broker `2 → 3`; 새 leader는 장애 전 ISR 구성원 |
| ISR 변화 | `3,1,2 → 3,1 → 3,1,2` |
| 장애 중 가용성 | partition available, 새 쓰기와 downstream 처리 진행 |
| 최종 복제 상태 | URP `0`, unavailable partition `0` |

### 애플리케이션 결과

| 항목 | 결과 |
|---|---:|
| 논리적 입력 | 66 |
| Kafka transport record | 75 |
| transport duplicate | 9 |
| MySQL 고유 scan time | 66 |
| MySQL 고유 barcode | 66 |
| missing / extra | 0 / 0 |
| DLT / DLQ / pending / unaccounted | 모두 0 |

추가 transport record 9개는 Kafka가 저장된 record를 독립적으로 replay한 것으로 확인된 것이 아니다. 보존된 Evidence에서는 Scanner 단건 폴백 7회와 HTTP client 자동 재실행 2회가 추가 요청 9건과 연결됐고, Processing이 같은 수의 duplicate를 검출했다. Redis dedupe는 이를 새로운 비즈니스 결과로 전달하지 않았으며 MySQL은 66개의 고유 결과로 수렴했다.

## 결과를 어떻게 해석해야 하는가

`STRICT PASS`는 다음을 의미한다.

> 승인된 로컬 bounded run에서 단일 controller가 유지되는 동안 leader broker 한 대가 실패해도 clean leader election이 수행됐고, ISR 2개로 `acks=all` 생산과 downstream 처리가 재개됐다. broker 복구 후 복제 상태와 최종 데이터가 모두 수렴했다.

다음 의미로 확대하면 안 된다.

- production-grade HA 또는 SLA 보장
- controller 장애 내성
- broker 두 대 이상 동시 장애 내성
- network partition 또는 disk 손실 내성
- 정확히 한 번 처리(Exactly-Once Processing) 보장
- 모든 부하와 Kafka/client 버전에서 동일한 failover 시간 보장

## 이 시나리오에서 얻은 핵심 교훈

1. RF만으로 HA를 판단할 수 없다. ISR, `min.insync.replicas`, `acks`, leader election 정책이 함께 필요하다.
2. leader 전환 중 상위 계층 재전송이 transport duplicate를 만들 수 있으므로 애플리케이션 멱등성이 필요하다.
3. broker가 `running`이 된 시점은 복구 완료가 아니다. ISR, URP, lag, 새 traffic과 최종 데이터 대사를 함께 확인해야 한다.
