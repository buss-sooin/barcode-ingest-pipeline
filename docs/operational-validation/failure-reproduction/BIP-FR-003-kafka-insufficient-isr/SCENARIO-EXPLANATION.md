# BIP-FR-003 장애 시나리오 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: Kafka를 처음 접하거나 FR-002와 FR-003의 차이를 이해하려는 개발자

## 먼저 이해할 한 문장

BIP-FR-003은 Kafka leader가 사라져서 쓰기가 실패한 실험이 아니다. Partition leader는 살아 있었지만, 안전하게 동기화됐다고 인정되는 replica 수가 `min.insync.replicas=2` 아래인 1개로 줄어 `acks=all` 쓰기가 거부되는 경계를 검증했다.

```text
leader 존재
+ ISR size 1
+ min.insync.replicas 2
+ producer acks=all
        ↓
내구성 조건 불충족
        ↓
새 쓰기 성공 승인 거부
```

Kafka는 이 상태에서 가용성을 위해 보호 조건을 낮추지 않았다. 설정된 복제 안전성을 지키기 위해 일부 쓰기 가용성을 포기했다.

## Replica 3개와 ISR 3개는 왜 다른가

Partition의 replica는 그 데이터를 보유하도록 배치된 복제본이다. 복제 계수(Replication Factor, RF)가 3이면 partition마다 replica가 세 개 있다는 뜻이다.

동기화 복제본 집합(In-Sync Replicas, ISR)은 그 replica 중 leader의 log를 허용 범위 안에서 따라가고 있어 현재 쓰기 승인과 clean leader election에 참여할 수 있는 집합이다.

```text
Replicas = 구성상 데이터를 보유해야 하는 전체 복제본
ISR      = 그중 현재 충분히 동기화된 복제본
```

따라서 다음 상태가 가능하다.

| 상태 | Replicas | ISR | 의미 |
|---|---:|---:|---|
| 정상 | 3 | 3 | 세 replica가 모두 동기화됨 |
| 저하 | 3 | 2 | replica 하나는 존재하지만 현재 ISR 밖에 있음 |
| 쓰기 불가 경계 | 3 | 1 | leader만 ISR에 남아 `min.insync.replicas=2`를 충족하지 못함 |

RF는 배치된 복제본 수라는 설계값이고, ISR은 실행 중 변하는 상태다. RF=3만 확인해서는 현재 쓰기 내구성이나 가용성을 알 수 없다.

## `min.insync.replicas=2`는 무엇을 보호하는가

`min.insync.replicas=2`는 `acks=all` 쓰기를 성공으로 승인하려면 ISR에 최소 두 replica가 있어야 한다는 보호 장치다.

- ISR size 3: 최소값 2를 충족한다.
- ISR size 2: 최소값 2를 충족한다.
- ISR size 1: 최소값 2보다 작으므로 새 `acks=all` 쓰기를 성공으로 승인하지 않는다.

이 설정은 장애를 예방하지 않는다. 대신 replica가 너무 적게 남았을 때 한 곳에만 기록된 데이터를 성공으로 인정해 이후 장애에서 잃을 위험을 제한한다.

## `acks=all`과 왜 함께 봐야 하는가

`min.insync.replicas`는 producer가 `acks=all`을 요구하는 쓰기에서 의미 있는 승인 경계를 만든다. Producer가 성공을 기다리는 조건과 broker가 허용하는 최소 ISR 조건이 함께 작동한다.

```text
Producer: acks=all
    asks for the configured replicated-write safety boundary

Broker/topic: min.insync.replicas=2
    refuses that write when ISR size < 2
```

BIP-FR-003의 runtime ProducerConfig에서는 `acks=-1`, 즉 `all`이 직접 확인됐다. Topic `barcode-events`에는 dynamic topic config로 `min.insync.replicas=2`가 적용됐다. Broker runtime default에 `min.insync.replicas=1`도 보였지만 target topic의 dynamic config가 우선하므로 두 값을 혼동하면 안 된다.

## leader가 살아 있는데도 왜 실패하는가

Leader의 존재는 partition 요청을 받을 주체가 있다는 뜻이다. 그러나 모든 요청을 성공으로 승인할 수 있다는 뜻은 아니다.

FR-003의 ISR=1 구간에는 broker 3이 partition 1의 leader로 살아 있었다. Kafka metadata에도 leader 3이 존재했고 unavailable partition은 없었다. 하지만 ISR에는 leader 하나만 남아 topic의 최소값 2를 충족하지 못했다.

```text
Leader exists
≠ enough in-sync replicas
≠ producer write allowed
```

이때 제출한 고유 application witness는 HTTP 503과 `NotEnoughReplicasException`을 남겼다. 판정은 HTTP 응답만 사용하지 않았다. Witness 전후 partition offset이 `177→177`로 유지됐고, 해당 identity가 Kafka와 MySQL에 없음을 함께 확인했다.

## FR-002에서는 견뎠는데 FR-003에서는 왜 막혔는가

두 시나리오는 같은 RF=3, `min.insync.replicas=2`, `acks=all` 경계를 서로 다른 지점에서 검증했다.

| 구분 | BIP-FR-002 | BIP-FR-003 |
|---|---|---|
| 장애 핵심 | 현재 leader broker 한 대 중단 | 새 leader를 살린 채 남은 follower 추가 중단 |
| leader | clean election으로 `2→3` | broker 3 leader 유지 |
| ISR | `3→2` | `3→2→1` |
| 최소 ISR 충족 | 충족 | ISR=1에서 불충족 |
| `acks=all` 새 쓰기 | 저하 상태에서도 성공 | ISR=1에서 거부 |
| 검증 의미 | 단일 broker 장애 중 HA continuity | 내구성 정책에 의한 write unavailability |

```text
FR-002
leader failure → clean leader election → ISR 2 → write continues

FR-003
leader remains alive → ISR 1 < minISR 2 → write rejected
```

FR-003을 단순한 “broker 두 대 장애”로만 설명하면 핵심이 사라진다. 중요한 것은 살아 있는 process 수가 아니라 target partition의 leader, ISR, topic minISR와 producer acknowledgment 조건의 결합이다.

## 실제로 검증한 인과관계

주 Material Run은 `BIP-FR-003-MR-20260902T114420Z`, 적용 계약은 `BIP-FR-003-RC-R2`다.

```text
healthy: leader L0=2, ISR=[3,1,2]
→ L0=2 SIGKILL
→ clean leader L1=3, ISR=[3,1]
→ 연속 sample과 10초 안정화
→ ISR=2 write HTTP 200, offset 170
→ active Scanner traffic 시작
→ follower F1=1 SIGKILL
→ leader L1=3 유지, ISR=[3]
→ unique write HTTP 503 + NotEnoughReplicasException
→ offset 177→177, downstream identity 없음
→ F1=1 same-volume 복구
→ ISR=[3,1], recovery write HTTP 200, offset 213
→ L0=2 same-volume 복구
→ 모든 partition ISR size 3, URP 0, unavailable 0
→ backlog와 identity reconciliation 수렴
```

Kafka metadata에서 `Isr: 3`은 “ISR 개수가 3”이 아니라 “broker ID 3 하나가 ISR에 있다”는 뜻이다. 이 구간의 ISR size는 1이다.

## 직접 fault injection한 조건

BIP-FR-003은 승인된 로컬 Compose 환경에서 다음 조건을 직접 만들었다.

- 전용 KRaft controller node 100은 계속 실행했다.
- `barcode-events` partition 1의 현재 leader `L0=2`를 SIGKILL했다.
- clean leader `L1=3`과 ISR size 2가 안정된 뒤 쓰기 성공을 확인했다.
- `L1=3`을 살린 채 follower `F1=1`만 추가로 SIGKILL했다.
- Active traffic 중 leader 존재와 ISR size 1을 직접 확인하고 고유 write witness를 제출했다.
- `F1`을 같은 container와 volume으로 먼저 복구해 ISR 1→2와 write 회복을 확인했다.
- `L0`를 같은 volume으로 복구해 ISR 2→3과 전체 수렴을 확인했다.

Controller, volume, topic, offset, `min.insync.replicas`, producer `acks`, unclean leader election은 변경하지 않았다.

## Production에서 ISR 감소를 만들 수 있는 가능한 원인

아래는 Kafka의 일반 메커니즘을 설명하는 운영 원인 후보다. BIP-FR-003이 각 원인을 직접 재현했다는 뜻이 아니다.

| 가능한 원인 | ISR에 미칠 수 있는 영향 | FR-003에서 직접 검증했는가 |
|---|---|---|
| broker process 또는 container 중단 | 해당 broker replica가 ISR에서 이탈 | 예. SIGKILL로 직접 주입 |
| host 장애나 재부팅 | host의 broker와 storage/network 경로 상실 | 아니오 |
| network partition 또는 장시간 지연 | follower가 leader를 제때 따라가지 못해 ISR 이탈 가능 | 아니오 |
| disk I/O stall, disk full, corruption | replica fetch·append 지연 또는 log directory 실패 | 아니오 |
| CPU·GC pause 또는 심한 자원 고갈 | replica fetch 지연과 ISR 축소 가능 | 아니오 |
| 배포·운영 실수로 여러 broker 동시 중단 | 여러 replica가 동시에 ISR에서 이탈 | 원인 일반화는 아니며, bounded SIGKILL 순서만 검증 |

운영에서는 “ISR이 줄었다”는 공통 결과만으로 원인을 확정하지 않는다. Process, controller, network, storage, resource와 deployment Evidence를 별도로 확인해야 한다.

## 무엇을 보호하기 위해 availability를 포기했는가

ISR이 하나뿐인데도 쓰기를 성공으로 인정하면 그 유일한 replica가 추가로 실패하기 전에 다른 동기화 사본이 없을 수 있다. `min.insync.replicas=2`와 `acks=all`은 이 위험을 감수해 계속 쓰기보다, 최소 두 in-sync replica라는 보호 조건이 회복될 때까지 성공 승인을 중단한다.

Trade-off는 다음과 같다.

```text
더 높은 minISR
→ 더 강한 replicated-write protection
→ replica 장애 시 write availability가 더 일찍 제한될 수 있음

더 낮은 minISR
→ 장애 중 write availability가 늘 수 있음
→ 더 적은 동기화 사본으로 성공을 인정하는 위험 증가
```

BIP-FR-003은 어느 값이 production에 최적인지 결정하지 않았다. 그 선택에는 장애 영역(Failure Domain), RPO, 처리량, 비용과 조직의 운영 목표가 필요하다.

## ISR 회복과 Recovery Complete가 다른 이유

ISR이 1에서 2가 되면 이 시나리오의 기능 복구 조건은 충족된다. 실제로 설정 완화나 application restart 없이 새 write가 성공했다. 그러나 이것만으로 종단 간 복구 완료(Recovery Complete)는 아니다.

```text
ISR 1→2
→ write acceptance 회복
→ 아직 최초 broker 미복구 가능
→ retry·backlog·consumer lag·PEL 잔존 가능
→ transport duplicate나 unaccounted identity 가능
```

FR-003은 다음 세 경계를 분리했다.

1. 기능 복구: ISR size 2와 새 `acks=all` write 성공
2. 복제 중복성 복원: 모든 partition ISR size 3, URP 0, unavailable 0
3. 종단 간 복구 완료: Scanner retry queue, Kafka/Redis lag, PEL, DLQ/DLT가 수렴하고 모든 logical identity가 terminal state에 귀속

주 실행에서는 54개 logical identity가 MySQL unique 53개와 직접 입증된 expected rejection 1개로 모두 귀속됐다. Kafka transport record 54개 중 unique identity는 53개였고 transport duplicate 1개는 Processing dedupe 뒤 business duplicate를 만들지 않았다.

## 검증 결과를 읽는 법

| 항목 | 관찰 결과 | 의미 |
|---|---|---|
| ISR=2 degraded witness | HTTP 200, offset 170 | 최소 ISR 충족 상태의 write 가능 |
| ISR=1 failure witness | HTTP 503, `NotEnoughReplicasException`, offset `177→177` | leader가 있어도 내구성 조건 미충족으로 write 거부 |
| ISR=2 recovery witness | HTTP 200, offset 213 | 설정 완화 없는 기능 복구 |
| 최종 Kafka 상태 | 모든 partition ISR size 3, URP 0, unavailable 0 | 복제 중복성 복원 |
| 최종 identity | 54 generated = 53 MySQL + 1 expected rejection | unaccounted 0 |
| 중복 | transport duplicate 1, business duplicate 0 | 전송과 최종 비즈니스 결과의 경계가 다름 |

R1의 두 실행도 중요하다. 첫 실행은 inspection template 오류로 fault injection 전에 종료됐고, 두 번째 실행은 ISR=2 안정화 전에 witness를 보내 HTTP 503 뒤 late acknowledgment를 관찰했다. 두 실행은 성공으로 합치지 않고 `INCONCLUSIVE`로 보존했으며, 안정화 절차를 R2로 교정한 뒤 주 실행을 수행했다.

## Evidence가 허용하는 최대 Claim

이 Repository Evidence로 말할 수 있는 최대 범위는 다음과 같다.

> 승인된 로컬 RF=3 토폴로지의 bounded R2 run에서, `barcode-events` partition 1의 leader broker 3이 살아 있는 동안 ISR size를 1로 낮추자 topic `min.insync.replicas=2`와 runtime producer `acks=all` 조건의 고유 application write가 성공 acknowledgment를 받지 못하고 `NotEnoughReplicasException`과 offset 불변을 남겼다. Follower를 같은 volume으로 복구해 ISR size 2가 되자 설정 완화와 application restart 없이 새 write가 성공했고, 전체 broker 복구 뒤 replica와 downstream 상태가 수렴했다.

## 명시적 Non-Claim

다음은 검증하지 않았거나 일반화하지 않는다.

- production HA, SLA, RTO 또는 RPO
- controller HA 또는 controller 장애
- 세 번째 broker 장애와 전체 cluster failure tolerance
- network partition, storage loss·corruption·full 또는 host/AZ 장애
- 모든 topic assignment, Kafka/client version과 infrastructure의 동일 동작
- callback timeout이 언제나 Kafka append 실패라는 주장
- 일반적인 exactly-once 또는 duplicate-free transport 보장
- Scanner, Processing, Redis, MySQL, worker의 결합 장애 복구
- 성능, capacity, 장시간 soak 또는 일반적인 recovery latency
- 관측된 `OutOfOrderSequenceException`의 근본 원인 확정

## 핵심 교훈

1. Broker process `UP`과 Kafka write availability는 같은 상태가 아니다.
2. Leader 존재와 producer write 허용도 같은 상태가 아니다.
3. RF는 구성값이고 ISR은 실행 상태이므로 함께 확인해야 한다.
4. `min.insync.replicas`와 `acks=all`은 내구성과 availability 사이의 명시적 경계다.
5. ISR 회복은 기능 복구의 시작일 수 있지만, Recovery Complete는 backlog와 최종 identity까지 확인해야 한다.

## 기존 Artifact와의 중복 평가

Scenario explanation이라는 독자 책임은 FR-003에서 필요하다. Contract와 Technical Report는 정확하지만 처음 읽는 개발자에게 RF, ISR, minISR, `acks=all`의 인과관계를 순서대로 가르치는 책임은 분산돼 있다.

다만 독립 파일은 다음 내용을 중복한다.

- 실행 조건과 Non-Claim은 `REPRODUCTION-CONTRACT.md`와 중복된다.
- 시간선·수치·최대 Claim은 `REPRODUCTION-RECORD.md`, `TECHNICAL-REPORT.md`와 중복된다.
- FR-002 설명과 Kafka 기본 개념 일부가 반복된다.

따라서 이 파일은 기술 결과의 새 정본이 아니라 학습 순서와 FR-002/FR-003 의미 차이를 제공하는 읽기 경로다. 고정 4-file 구조의 영구 필요성은 이번 Trial만으로 확정하지 않는다.
