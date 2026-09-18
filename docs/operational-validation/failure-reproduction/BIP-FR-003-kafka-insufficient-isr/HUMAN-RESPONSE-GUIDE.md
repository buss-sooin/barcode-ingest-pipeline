# BIP-FR-003 인간 개발자 장애 대응 안내서

> 상태: `FINAL — HUMAN CONFIRMED`
> 용도: Broker process는 실행 중이거나 partition leader가 존재하지만 Kafka 쓰기가 실패할 때의 확인·판단 순서
> 주의: 이 문서는 운영 환경의 인증, 배포 플랫폼, 조직별 escalation·변경 승인 절차를 대체하지 않는다.

## 먼저 기억할 세 가지

```text
Broker process UP
≠ Kafka write available

Leader exists
≠ Producer write allowed

ISR recovered
≠ End-to-end Recovery Complete
```

쓰기가 실패한다고 즉시 broker를 재시작하거나 `min.insync.replicas`를 낮추지 않는다. 먼저 target partition의 leader, ISR, topic minISR, producer acknowledgment 조건과 실제 application 결과를 연결한다.

이 안내서는 FR-001에서 사용한 3계층 구조를 FR-003에 적용한다.

```text
Layer 1 — 공통 장애 대응 핵심
→ Layer 2 — FR-003 failure mechanism
→ Layer 3 — BIP-FR-003 project adapter
```

## Layer 1 — 공통 장애 대응 핵심

### 1. Symptom

사용자와 애플리케이션에 보이는 현상을 먼저 시간과 identity와 함께 보존한다.

- HTTP non-success, timeout 또는 producer exception
- 정상 구간과 달라진 latency·error rate
- 실패한 barcode, `scanTime`, device ID
- 최초 발생 시각과 지속 시간
- 새 요청 전체가 실패하는지 특정 partition key만 실패하는지

HTTP 503 하나만으로 Kafka append 실패를 확정하지 않는다. 이 프로젝트의 Ingest는 producer Future를 5초만 기다리며, timeout 뒤에도 underlying Future를 취소하지 않는다. 따라서 응답 시점의 미확인과 최종 append 실패를 offset·callback·identity로 구분해야 한다.

### 2. Initial Triage

다음 순서로 상태를 좁힌다.

1. Process/container와 controller가 실행 중인가?
2. Target topic의 모든 partition에 leader가 존재하는가?
3. Replicas와 ISR은 각각 몇 개인가?
4. Topic에 실제 적용된 `min.insync.replicas`는 얼마인가?
5. Producer의 runtime `acks`는 무엇인가?
6. 실패 시점의 producer exception과 partition offset은 무엇인가?
7. Consumer와 downstream에도 영향이 진행됐는가?

### 3. Failure-domain Narrowing

관측을 다음 경계로 분류한다.

| 관측 | 우선 의심할 경계 | 아직 확정하지 못하는 것 |
|---|---|---|
| broker/container DOWN | process 또는 host 경계 | partition write 불가 여부 |
| leader 없음 | partition availability 경계 | 원인이 process, network, storage 중 무엇인지 |
| leader 존재 + ISR < minISR | replicated-write safety 경계 | ISR 이탈의 근본 원인 |
| ISR 조건 충족 + producer timeout | client metadata, network, broker 처리, confirmation uncertainty | 실제 append 성공·실패 |
| Kafka write 성공 + downstream lag 증가 | consumer 이후 처리 경계 | producer availability 문제 |
| ISR 복원 + backlog 잔존 | 복제는 회복됐지만 flow 또는 drain 미완료 | Recovery Complete |

### 4. Hypothesis Verification

가설마다 독립 probe를 둔다.

```text
가설: insufficient ISR 때문에 acks=all 쓰기가 거부됐다.

필요 Evidence:
- target partition leader 존재
- ISR size < topic minISR
- runtime producer acks=all
- 같은 시간의 NotEnoughReplicas 계열 오류
- 고유 witness의 offset·downstream identity 부재 또는 terminal result
```

경쟁 가설도 유지한다.

- Leader 부재 또는 controller 문제
- Client가 stale metadata를 사용하는 전이 구간
- Network, DNS, TLS 또는 bootstrap 연결 실패
- Disk·resource 문제
- Ingest 내부 timeout과 늦은 acknowledgment
- Downstream 장애를 producer 장애로 잘못 해석한 경우

### 5. Recovery

원인 경계를 확인한 뒤 최소 조치를 선택한다.

- Process 중단이면 동일 설정과 영구 저장소를 유지한 해당 replica 복구
- Host/network 문제면 broker 반복 재시작보다 원인 경로 복구
- Disk full/corruption이면 자동 재시작보다 storage 보호와 교체 절차
- ISR 부족이면 정책 완화보다 이탈한 replica의 안전한 복귀 우선
- 승인 범위를 넘는 복구가 필요하면 중단하고 권한 있는 담당자에게 escalation

### 6. Recovery Complete

다음을 분리해 확인한다.

```text
Component Recovery
→ Functional Recovery
→ Replication Recovery
→ Backlog Drain
→ End-to-end Reconciliation
```

- Component Recovery: broker가 다시 등록되고 healthy한가?
- Functional Recovery: 새 `acks=all` write가 실제로 성공하는가?
- Replication Recovery: 기대 ISR, URP 0, unavailable 0으로 수렴했는가?
- Backlog Drain: Kafka/Redis lag, PEL, retry queue, DLQ/DLT가 terminal 상태인가?
- End-to-end Reconciliation: 고유 입력 identity가 저장·명시적 rejection·격리·pending 중 하나로 모두 설명되는가?

## Layer 2 — FR-003 Failure Mechanism

### 판단 모델

FR-003에서 write availability는 다음 네 값의 결합으로 판단한다.

```text
broker process state
→ target partition leader
→ target partition ISR size vs topic minISR
→ producer acknowledgment condition
```

| Leader | ISR size | minISR | `acks=all` write 해석 |
|---|---:|---:|---|
| 없음 | 무관 | 2 | Partition unavailable |
| 있음 | 3 | 2 | 승인 조건 충족 |
| 있음 | 2 | 2 | 저하 상태지만 승인 조건 충족 |
| 있음 | 1 | 2 | Leader가 있어도 새 write 거부 |

### FR-003에서 직접 관찰한 상태

```text
P=1
L0=broker-2
L1=broker-3
F1=broker-1

ISR size 3
→ broker-2 SIGKILL
→ leader broker-3 / ISR size 2 / write 200
→ broker-1 SIGKILL
→ leader broker-3 / ISR size 1 / write 503
→ broker-1 복구
→ ISR size 2 / write 200
→ broker-2 복구
→ ISR size 3 / URP 0 / unavailable 0
```

Kafka 출력의 `Isr: 3`은 broker ID 3 하나를 뜻할 수 있다. 쉼표로 구분된 ID 수를 세어 ISR size를 판단한다.

### Under-replicated와 unavailable을 구분한다

- 복제 부족 파티션(Under-replicated Partition, URP): 배치된 replica 중 일부가 ISR에 없다는 뜻이다.
- Unavailable partition: leader가 없어 partition 요청을 처리할 주체가 없다는 뜻이다.

FR-003의 핵심 failure 구간은 URP이면서 leader는 존재하고 unavailable partition은 아닌 상태다. 이 상태에서도 `min.insync.replicas` 때문에 쓰기가 거부될 수 있다.

### Consumer와 downstream 영향

Insufficient ISR은 새 `acks=all` produce의 승인 경계다. 이미 Kafka에 저장된 record의 consumer read가 모두 즉시 중단된다는 뜻은 아니다. 그러나 새 입력이 Kafka에 들어가지 못하면 이후 Processing, Redis, MySQL에는 해당 identity가 도달하지 않는다.

동시에 application retry가 발생하면 다음 부작용을 확인해야 한다.

- 동일 logical identity의 반복 HTTP 제출
- Transport duplicate
- Scanner retry queue 증가 또는 drop
- Recovery 뒤 burst와 consumer lag
- Redis dedupe와 MySQL unique constraint의 최종 결과

## Layer 3 — BIP-FR-003 Project Adapter

### 실제 구성과 진단 대상

| 구분 | Repository에서 확인한 값 |
|---|---|
| Compose asset | `../BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml` |
| Controller | `controller`, KRaft node 100 |
| Brokers | `broker-1`, `broker-2`, `broker-3` |
| Applications | `ingest`, `processing`, `scanner`, `worker-1`, `worker-2` |
| State stores | `redis`, `mysql` |
| Topic | `barcode-events`, partitions 3, RF 3 |
| Topic policy | `min.insync.replicas=2` |
| Producer | Runtime `acks=-1(all)`, 3-broker bootstrap |
| Consumer group | `barcode-processing-group` |
| Redis stream/group | `barcode:stream` / `barcode-persistence-group` |
| Redis DLQ | `barcode:stream:dlq` |
| Kafka DLT | `barcode-events-dlt` |
| Ingest endpoint | `http://127.0.0.1:18081/ingest/barcode` |

FR-003은 FR-002의 전용 Kafka HA Compose asset을 재사용한다. 따라서 container 이름에 `bip-fr-002`가 포함돼 있어도 시나리오 판정은 FR-003 Contract와 Evidence를 따른다.

### 명령 실행 위치와 공통 옵션

아래 예시는 저장소 루트에서 FR-003 시나리오 디렉터리로 이동한 뒤 실행한다.

```bash
cd docs/operational-validation/failure-reproduction/BIP-FR-003-kafka-insufficient-isr
alias fr003='docker compose --env-file ../../../../.env -f ../BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml'
```

- `--env-file ../../../../.env`: 저장소 루트의 Compose 환경 변수를 읽는다.
- `-f .../docker-compose.validation.yml`: FR-002와 FR-003이 사용하는 전용 HA topology를 선택한다.
- `fr003`: 현재 terminal에서만 유효한 별칭이다.
- `-T`: 자동 수집 시 pseudo-TTY를 끄는 옵션이다. 사람이 직접 실행할 때는 필수가 아니다.

### 1. Process 상태 확인

기본 명령:

```bash
fr003 ps --all
```

확인하는 상태:

- Controller와 세 broker의 running/healthy 여부
- 종료된 broker와 exit 상태
- Ingest, Processing, Scanner, Redis, MySQL, worker의 실행 여부

정상/비정상 의미:

- Broker `healthy`는 process/container 상태다.
- 모든 broker가 UP이어도 ISR이 수렴하지 않았을 수 있다.
- 일부 broker가 DOWN이어도 target partition leader와 minISR 조건에 따라 쓰기는 가능할 수 있다.

FR-003 실제 예:

- ISR=1 failure 구간에도 leader인 `broker-3`은 alive였다.
- `broker-2`와 `broker-1`이 순차적으로 중단됐지만 controller는 계속 실행됐다.

관련 log를 필터 없이 먼저 확인한다.

```bash
fr003 logs --since 15m controller broker-1 broker-2 broker-3
fr003 logs --since 15m ingest processing scanner worker-1 worker-2
```

Log는 원인 후보와 상태 전이를 보여주지만, topic의 현재 leader와 ISR은 다음 명령으로 직접 확인한다.

### 2. 실행 가능한 Kafka CLI service 선택

Kafka CLI는 실행 중인 broker container에서 호출한다. 다음 예시의 `broker-3`은 FR-003 주 실행에서 살아 있던 leader였기 때문에 사용한 실제 값이다. 현재 환경에서는 `fr003 ps --all`로 실행 중인 broker를 먼저 고른다.

```bash
KAFKA_CLI_SERVICE=broker-3
```

이 변수는 진단 명령을 실행할 장소일 뿐, 장애 원인이나 leader를 미리 확정하지 않는다.

### 3. Controller 상태 확인

기본 명령:

```bash
fr003 exec controller \
  kafka-metadata-quorum \
  --bootstrap-controller controller:29093 \
  describe --status
```

최소 옵션과 의미:

- `--bootstrap-controller`: KRaft controller endpoint를 지정한다.
- `describe --status`: controller quorum 상태를 읽기 전용으로 조회한다.

정상/비정상 의미:

- Controller leader가 존재해야 metadata 관리와 broker fencing이 가능하다.
- Controller가 정상이어도 특정 partition의 ISR 부족이나 write rejection은 별도로 발생할 수 있다.

FR-003 실제 예: controller node 100은 전체 Material Run 동안 실행 상태를 유지했다.

### 4. Topic leader, replicas와 ISR 확인

기본 명령:

```bash
fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --topic barcode-events
```

필요한 최소 옵션:

- `--bootstrap-server`: 처음 접속할 broker 주소. 장애에 대비해 세 주소를 함께 준다.
- `--describe`: 상태 변경 없이 metadata를 읽는다.
- `--topic barcode-events`: 진단 대상을 target topic으로 한정한다.

확인하는 상태:

- `Leader`: partition 요청을 처리하는 broker ID
- `Replicas`: 배치된 전체 replica ID
- `Isr`: 현재 in-sync replica ID 목록

정상/비정상 의미:

- `Leader`가 없으면 unavailable partition이다.
- Leader가 있어도 ISR ID가 하나뿐이고 minISR가 2면 `acks=all` 쓰기는 거부될 수 있다.
- Replicas가 3이라는 사실만으로 ISR도 3이라고 판단하지 않는다.

FR-003 실제 예:

```text
Partition: 1  Leader: 3  Replicas: 2,3,1  Isr: 3
```

이 출력은 leader broker 3이 살아 있지만 ISR size가 1인 failure state였다.

### 5. Topic의 실제 `min.insync.replicas` 확인

기본 명령:

```bash
fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-configs \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --entity-type topics --entity-name barcode-events
```

필요한 최소 옵션:

- `--entity-type topics`: broker default가 아니라 topic 설정을 조회한다.
- `--entity-name barcode-events`: target topic을 지정한다.

확인하는 상태:

- `min.insync.replicas=2`
- Config source가 dynamic topic config인지

정상/비정상 의미:

- Broker default와 topic override가 다르면 target topic에 실제 적용되는 우선순위를 확인한다.
- FR-003에서는 broker runtime default `1`보다 topic dynamic config `2`가 우선했다.

### 6. URP와 unavailable partition 확인

```bash
fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --under-replicated-partitions

fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --unavailable-partitions
```

확인하는 상태:

- 첫 명령: 배치 replica가 ISR에 모두 참여하지 못하는 partition
- 둘째 명령: leader가 없는 partition

정상/비정상 의미:

- URP 출력이 있으면 replication 저하 상태다.
- Unavailable 출력이 비어 있어도 ISR < minISR이면 write unavailable일 수 있다.
- 복구 완료 시 두 출력 모두 비어야 한다.

### 7. Application write failure를 Kafka state와 연결

최근 Ingest log에서 producer 결과를 확인한다.

```bash
fr003 logs --since 15m ingest
```

FR-003 실제 failure witness에서는 다음이 함께 나타났다.

- HTTP 503
- 5초 confirmation timeout
- `NotEnoughReplicasException`
- Target partition offset `177→177`
- Witness identity의 Kafka/MySQL 부재

실제 사고에서 새 witness를 보내는 행위는 상태 변경이다. 조직의 진단 정책과 승인 범위 안에서만 고유 identity로 수행한다. FR-003에서 사용한 요청 형태는 다음과 같다.

```bash
curl --retry 0 -i \
  -X POST http://127.0.0.1:18081/ingest/barcode \
  -H 'Content-Type: application/json' \
  -d '{"barcode":"UNIQUE-DIAGNOSTIC-BARCODE","scanTime":CURRENT_EPOCH_MS,"deviceId":"SEOUL-CENTER-PC-001"}'
```

- `--retry 0`: 진단 client가 별도 재시도를 만들지 않게 한다.
- 고유 barcode와 `scanTime`: offset, Kafka, MySQL 결과를 같은 identity로 대조한다.
- HTTP 결과만으로 terminal state를 확정하지 않는다.

### 8. Consumer와 downstream 영향 확인

Kafka consumer lag:

```bash
fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-consumer-groups \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --group barcode-processing-group
```

Redis Stream과 PEL:

```bash
fr003 exec redis redis-cli XINFO GROUPS barcode:stream
fr003 exec redis redis-cli XPENDING barcode:stream barcode-persistence-group
fr003 exec redis redis-cli XLEN barcode:stream:dlq
```

Kafka DLT offset:

```bash
fr003 exec "$KAFKA_CLI_SERVICE" \
  kafka-get-offsets \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --topic barcode-events-dlt
```

정상/비정상 의미:

- Kafka target lag, Redis group lag와 PEL은 서로 다른 backlog다.
- DLQ/DLT가 증가하면 정상 처리 경로 밖의 terminal candidate를 별도로 조사한다.
- ISR 회복 후에도 이 값들이 수렴하지 않으면 Recovery Complete가 아니다.

### 9. 원인 확인 뒤 replica를 복구한다

FR-003과 같은 단순 container process 중단이고 container·volume identity가 보존됐음을 확인했다면, ISR 회복에 필요한 follower를 먼저 시작한다.

```bash
fr003 start broker-1
```

이것은 주 Material Run의 실제 `F1=broker-1` 예다. 현재 사고에서 broker 1을 무조건 시작하라는 뜻이 아니다. 실제 leader와 ISR을 확인해, 중단된 service와 storage 상태가 맞을 때만 적용한다.

복구 우선순위:

```text
원인 확인
→ 이탈한 replica를 동일 설정·volume으로 복구
→ ISR이 minISR까지 회복되는지 확인
→ 새 write 성공 확인
→ 나머지 replica 복구
→ 전체 ISR과 downstream 수렴 확인
```

다음은 원인과 별도 승인 없이 수행하지 않는다.

- `min.insync.replicas` 하향
- Producer `acks` 완화
- RF 변경
- Unclean leader election 활성화
- Topic 삭제·재생성
- Consumer offset reset
- Broker data volume 삭제
- Redis PEL, DLQ 또는 MySQL row 수동 삭제
- 원인 확인 없는 모든 broker 반복 재시작

### 10. 기능 복구를 확인한다

앞에서 사용한 topic describe를 반복해 ISR size가 1에서 2로 회복됐는지 확인한다. 그 뒤 승인된 고유 witness로 새 write가 성공하는지 본다.

FR-003 실제 예:

- `broker-1` same-volume 복구
- Partition 1 ISR `3→3,1`
- Application restart와 설정 완화 없음
- Recovery witness HTTP 200, offset 213

이 시점은 write 기능 복구다. 최초 중단 broker가 아직 복구되지 않았을 수 있으므로 전체 복제 중복성 복원과 구분한다.

### 11. 전체 복제 상태를 복원한다

FR-003에서는 최초 중단 broker를 마지막에 복구했다.

```bash
fr003 start broker-2
```

다시 실제 사고의 원인과 volume 안전성이 확인됐을 때만 적용한다.

다음 조건을 확인한다.

- 모든 `barcode-events` partition의 ISR size가 3인가?
- URP 출력이 비었는가?
- Unavailable partition 출력이 비었는가?
- 세 broker가 controller에 등록되고 healthy한가?

### 12. End-to-end Recovery Complete를 확인한다

최종 조건:

- 새 producer write와 Processing consume이 정상이다.
- Kafka target lag이 0 또는 설명 가능한 terminal 기준으로 수렴한다.
- Redis group lag과 PEL이 0 또는 승인된 terminal 기준으로 수렴한다.
- Scanner retry queue remaining과 drop을 확인한다.
- Kafka DLT, Redis DLQ와 unresolved retry가 설명된다.
- 생성한 고유 identity가 MySQL, 명시적 rejection, DLQ/DLT 또는 pending 중 하나로 모두 귀속된다.
- Transport duplicate와 business duplicate를 별도로 계량한다.

FR-003 주 실행의 최종 결과:

```text
54 generated unique
= 53 MySQL unique
+ 1 directly evidenced expected rejection
+ 0 unaccounted

54 Kafka records
= 53 Kafka unique identities
+ 1 transport duplicate

business duplicate = 0
```

## Evidence locator

| 질문 | FR-003 실제 Evidence |
|---|---|
| 실행 identity와 Revision | `evidence/BIP-FR-003-MR-20260902T114420Z/00-run-identity-and-contract.txt` |
| Runtime topology·topic·producer config | `before/01-effective-runtime-config.txt` |
| 정상 사전 조건 | `before/02-healthy-preconditions.txt` |
| `P`, `L0`, `L1`, `F1` | `05-runtime-role-mapping.txt` |
| ISR 3→2 | `timeline/10-first-transition-isr3-to2.txt` |
| ISR=2 write 성공 | `07-isr2-write-witness.txt`, `08-isr2-write-application-logs.txt` |
| Active traffic 범위 | `09-active-traffic-boundaries.txt` |
| Follower 중단 | `11-second-failure-F1.txt` |
| ISR 2→1 | `timeline/12-second-transition-isr2-to1.txt` |
| Leader alive + ISR=1 | `13-isr1-leader-alive-state.txt` |
| Failure witness | `14-isr1-failure-witness.txt`, `15-isr1-failure-application-logs.txt`, `16-isr1-failure-verification.txt` |
| ISR 1→2 기능 복구 | `18-F1-functional-recovery.txt`, `timeline/19-functional-recovery-isr1-to2.txt`, `20-isr2-recovery-write-witness.txt` |
| ISR 2→3 전체 복구 | `22-L0-full-recovery.txt`, `timeline/17-full-recovery-isr2-to3.txt` |
| 최종 cluster·downstream 상태 | `final/25-terminal-state.txt` |
| Identity reconciliation | `final/42-run-scoped-reconciliation-summary.txt` |
| 무결성 manifest | `MANIFEST.sha256` |

모든 상대 경로의 기준은 `evidence/BIP-FR-003-MR-20260902T114420Z/`다.

## 즉시 escalation해야 하는 경우

- Controller 또는 여러 broker의 동시 원인 미상 장애
- Leader가 없는 partition이 지속됨
- ISR이 minISR 아래에서 회복되지 않음
- Storage loss, corruption, disk full 또는 volume identity 불일치 의심
- Network partition 또는 host failure가 의심되지만 관측 범위가 부족함
- ISR 복원 뒤에도 `NotEnoughReplicas` 또는 write failure 지속
- Retry amplification, queue drop, DLQ/DLT 또는 business duplicate 증가
- Lag, PEL, missing·extra·unaccounted identity가 수렴하지 않음
- 정책 완화, topic 재생성, offset reset 같은 material action이 필요함

## 3계층 구조 Trial 평가

이 구조는 FR-003에서도 자연스럽다.

- Layer 1은 Symptom부터 Recovery Complete까지 기술에 독립적인 판단 순서를 제공한다.
- Layer 2는 `leader exists + ISR < minISR + acks=all`이라는 FR-003 고유 인과관계를 설명한다.
- Layer 3은 실제 service, topic, command와 Evidence locator를 연결한다.

다만 중복 비용이 있다. Layer 2의 메커니즘은 `SCENARIO-EXPLANATION.md`, Layer 3의 실행 사실은 Contract·Record·run script와 겹친다. 운영자가 한 문서에서 판단과 명령을 함께 찾는 가치는 있지만, 장기 구조에서는 공통 Layer 1을 한 번만 유지하고 각 scenario가 Layer 2·3 adapter만 제공하는 방식이 더 짧을 수 있다.

이 Trial만으로 3계층 구조를 공통 Rule로 승인하지 않는다.
