# BIP-FR-002 인간 개발자 장애 조치 안내서

> 상태: `FINAL — HUMAN CONFIRMED`
> 용도: Kafka broker 또는 partition leader 장애가 의심될 때의 확인·판단 순서
> 주의: 이 문서는 운영 환경의 인증, 배포 플랫폼, 조직별 escalation 절차를 대체하지 않는다.

## 먼저 판단할 것

broker 한 대가 내려갔다고 즉시 데이터를 변경하거나 topic을 재생성하지 않는다. 먼저 다음 세 질문에 답한다.

1. leader가 없는 partition이 있는가?
2. 남은 ISR이 `min.insync.replicas`를 충족하는가?
3. 실제 producer, consumer와 최종 비즈니스 처리가 계속되는가?

```text
broker down
├─ leader 존재 + ISR 조건 충족 → 저하 상태에서 처리 지속 가능
├─ leader 존재 + ISR 조건 미충족 → acks=all 쓰기 거부 가능
└─ leader 없음 → 해당 partition unavailable
```

## 명령을 실행하기 전에: 무엇을 확인하는가

Kafka 장애는 한 명령으로 판정하지 않는다. 각 도구가 확인하는 계층이 다르다.

| 확인 계층 | Kafka 원리와 동작 | 대표 명령 |
|---|---|---|
| process/container | broker process가 실행 중인지 확인한다. 실행 중이어도 Kafka에 정상 참여한다는 뜻은 아니다. | `docker compose ps`, `logs` |
| controller 제어면 | controller가 metadata를 관리하고 broker fencing과 leader 변경을 조정한다. | `kafka-metadata-quorum`와 controller log |
| partition 데이터면 | 각 partition의 leader, replica와 ISR을 확인한다. | `kafka-topics --describe` |
| 쓰기 안전성 | `min.insync.replicas`와 `acks=all`이 쓰기 승인 경계를 만든다. | `kafka-configs --describe` |
| 소비 진행 | consumer offset과 log end offset의 차이가 lag이다. | `kafka-consumer-groups --describe` |
| downstream 결과 | Kafka 성공이 Redis와 MySQL의 최종 성공인지 별도로 확인한다. | `redis-cli`, application log, 데이터 조회 |

## 기본 명령어를 먼저 이해하기

### Docker Compose

| 기본 명령 | 의미 |
|---|---|
| `docker compose ps` | 현재 실행 중인 service 상태를 본다. `--all`을 붙이면 종료된 service도 보인다. |
| `docker compose logs SERVICE` | service가 출력한 log를 본다. 원인과 상태 전이 확인에 사용한다. |
| `docker compose exec SERVICE COMMAND` | 실행 중인 container 안에서 명령을 실행한다. Kafka CLI가 설치된 broker에서 진단할 때 사용한다. |
| `docker compose start SERVICE` | 이미 존재하지만 멈춘 container를 다시 시작한다. image나 volume을 삭제하지 않는다. |

FR-002는 기본 Compose 파일이 아닌 전용 파일을 사용하므로 다음 두 옵션은 필요하다.

- `--env-file ../../../../.env`: Compose가 필요한 환경 변수를 읽는다.
- `-f docker-compose.validation.yml`: FR-002 전용 service 구성을 선택한다.

`--since 15m`은 최근 15분 log만 볼 때 선택적으로 사용한다. `-T`와 `--no-color`는 자동 수집 파일에는 유용하지만 사람이 터미널에서 확인할 때는 필요하지 않다.

### Kafka CLI

| 기본 명령 | 확인 대상 |
|---|---|
| `kafka-metadata-quorum ... describe --status` | KRaft controller quorum의 leader와 상태 |
| `kafka-topics ... --describe --topic TOPIC` | partition별 leader, replica와 ISR |
| `kafka-configs ... --describe` | topic에 적용된 `min.insync.replicas` 같은 설정 |
| `kafka-consumer-groups ... --describe --group GROUP` | consumer의 현재 offset, 끝 offset과 lag |

공통 옵션은 다음 의미다.

- `--bootstrap-server`: 진단 명령이 처음 접속할 broker 주소다. 한 broker 장애를 고려해 여러 주소를 준다.
- `--describe`: 상태를 변경하지 않고 현재 정보를 조회한다.
- `--topic`: 확인할 topic을 지정한다.
- `--group`: 확인할 consumer group을 지정한다.
- `--under-replicated-partitions`: replica가 ISR에 모두 참여하지 못한 partition만 보여준다.
- `--unavailable-partitions`: leader가 없어 사용할 수 없는 partition만 보여준다.

`docker compose exec broker-1`에서 `broker-1`은 Kafka CLI를 실행할 장소일 뿐 장애 대상이라는 뜻이 아니다. broker 1이 내려갔다면 실행 중인 다른 broker를 선택한다.

### Redis와 애플리케이션 확인

| 기본 명령 | 확인 대상 |
|---|---|
| `redis-cli XINFO GROUPS STREAM` | consumer group의 `pending`과 `lag` |
| `redis-cli XPENDING STREAM GROUP` | 처리 중이거나 회수되지 않은 PEL 항목 |
| `redis-cli XLEN STREAM` | stream 또는 DLQ에 남은 항목 수 |
| `curl URL` | HTTP endpoint 응답. health 성공은 process 응답만 증명한다. |

## FR-002 명령 실행 위치

아래 예시는 저장소 루트에서 시나리오 디렉터리로 이동한 뒤 실행한다.

```bash
cd docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure
alias fr002='docker compose --env-file ../../../../.env -f docker-compose.validation.yml'
```

`fr002`는 긴 Compose 공통 옵션을 줄이기 위한 현재 terminal의 별칭이다. 실제 Docker 명령은 앞에서 설명한 `docker compose`이며, 새 terminal에서는 별칭을 다시 정의해야 한다. 실제 운영에서는 Docker Compose 대신 Kubernetes나 배포 플랫폼 명령을 사용하고, service 이름과 bootstrap 주소를 운영 값으로 바꿔야 한다.

## 1. process와 service 영향을 확인한다

종료된 broker를 놓치지 않도록 `--all`을 사용한다.

```bash
fr002 ps --all
```

최근 원인을 확인할 때는 먼저 복잡한 필터 없이 관련 service log를 본다.

```bash
fr002 logs broker-2 controller
fr002 logs ingest processing
```

`ps`는 process 상태, log는 controller fencing·client timeout·재연결 과정을 보여준다. 둘 다 partition 가용성을 직접 증명하지는 않으므로 다음 단계가 필요하다.

## 2. controller와 partition 상태를 확인한다

controller 상태를 확인한다.

```bash
fr002 exec controller \
  kafka-metadata-quorum --bootstrap-controller controller:29093 \
  describe --status
```

controller가 정상이어도 특정 partition에는 leader가 없을 수 있다. topic 상태를 별도로 확인한다.

```bash
fr002 exec broker-1 \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --topic barcode-events
```

확인할 내용:

- `Leader`: 없으면 해당 partition은 unavailable 상태다.
- `Replicas`: 구성상 데이터를 보유해야 하는 broker 목록이다.
- `Isr`: 현재 leader를 따라가 새 leader 후보가 될 수 있는 replica 목록이다.
- ISR이 2개면 FR-002에서는 `min.insync.replicas=2`를 충족한다.
- ISR이 1개면 `acks=all` 쓰기가 거부될 수 있다.

쓰기 안전성 설정도 실제 topic에서 확인한다.

```bash
fr002 exec broker-1 \
  kafka-configs \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --entity-type topics --entity-name barcode-events
```

## 3. cluster 저하 범위를 확인한다

```bash
fr002 exec broker-1 \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --under-replicated-partitions

fr002 exec broker-1 \
  kafka-topics \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --unavailable-partitions
```

- URP 출력이 있으면 replica 중 일부가 ISR에서 빠진 저하 상태다.
- unavailable partition 출력이 있으면 leader가 없어 해당 partition의 요청에 직접 영향이 있다.
- 두 출력이 비어 있어도 애플리케이션 처리가 정상이라는 뜻은 아니므로 downstream을 확인한다.

## 4. consumer와 downstream을 확인한다

```bash
fr002 exec broker-1 \
  kafka-consumer-groups \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --group barcode-processing-group
```

`CURRENT-OFFSET`이 consumer 처리 위치, `LOG-END-OFFSET`이 partition 끝이며 둘의 차이가 `LAG`다. 장애 중 lag이 늘 수 있지만 복구 후 감소해야 한다.

Redis downstream 상태는 다음처럼 확인한다.

```bash
fr002 exec redis \
  redis-cli XINFO GROUPS barcode:stream

fr002 exec redis \
  redis-cli XPENDING barcode:stream barcode-persistence-group

fr002 exec redis \
  redis-cli XLEN barcode:stream:dlq
```

Kafka lag과 Redis lag·PEL·DLQ가 함께 수렴해야 pipeline 처리가 따라잡았다고 판단할 수 있다.

## 5. 읽기 전용 Evidence를 보존한다

FR-002의 수집 도구는 위의 Kafka 상태와 관련 log를 한 디렉터리에 보존한다.

```bash
./capture-kafka-ha-state.sh /tmp/bip-fr-002-incident-state
```

이 도구는 describe/list/log 수집만 수행하며 topic, offset, replica, Redis 또는 MySQL 상태를 변경하지 않는다. 운영에서는 저장 위치의 보안과 개인정보 정책을 먼저 적용한다.

## 6. 원인에 맞는 복구 조치를 선택한다

복구 전에 장애 원인을 구분한다.

| 원인 | 우선 조치 |
|---|---|
| 일시적 process/container 실패 | 동일 설정과 영구 저장소를 유지해 해당 broker만 복구 |
| host 또는 network 문제 | broker 반복 재시작보다 host/network 경로 복구 우선 |
| disk full/corruption | 자동 재시작을 반복하지 말고 storage 보호와 교체 절차 적용 |
| ISR이 최소값 아래로 감소 | 설정 완화보다 추가 replica 복구를 우선 |

FR-002와 같은 단순 container process 실패라면 대상 broker만 복구한다.

```bash
fr002 start broker-2
```

`start`는 멈춘 기존 container를 같은 설정과 volume으로 다시 실행한다. 이 명령은 장애 대상이 broker 2로 확인됐을 때만 사용한다. 원인이 host, network 또는 disk라면 broker 반복 재시작보다 원인 경로를 먼저 복구한다.

다음 조치는 원인과 승인 없이 수행하지 않는다.

- topic 삭제·재생성
- consumer offset reset
- broker data volume 삭제
- `min.insync.replicas` 또는 RF 완화
- unclean leader election 활성화
- DB row, Redis PEL 또는 DLQ의 수동 삭제

## 7. 복구 동작과 완료 조건을 확인한다

복구는 다음 순서로 진행된다.

```text
container start
→ broker가 controller에 다시 등록
→ fencing 해제
→ follower replica가 leader log를 catch-up
→ ISR 재합류
→ URP·unavailable partition 해소
→ 새 traffic 처리와 backlog 소진
→ 최종 데이터 수렴
```

### 7.1 process 복귀

```bash
fr002 ps broker-2
fr002 logs --since 5m broker-2 controller
```

`running`은 첫 단계일 뿐이다. log에서 broker 등록, catch-up과 unfence 흐름을 확인한다.

### 7.2 replica와 가용성 복원

앞에서 사용한 `kafka-topics --describe --topic barcode-events`를 다시 실행한다.

- 모든 partition의 ISR이 기대 replica 수로 복원됐는가?
- `--under-replicated-partitions` 출력이 비었는가?
- `--unavailable-partitions` 출력이 비었는가?

FR-002에서는 ISR 3, URP 0, unavailable partition 0이 복제 중복성 복원의 기준이었다.

### 7.3 실제 흐름 복원

health endpoint는 process 응답만 확인한다.

```bash
curl -i http://localhost:18081/ingest/health
```

Kafka까지 확인하려면 고유한 barcode와 현재 epoch millisecond를 사용해 새 요청을 한 건 보낸다. 먼저 시간을 얻는다.

```bash
date +%s000
```

출력값을 `scanTime`에 넣고, 재사용하지 않을 barcode를 사용한다.

```bash
curl -i -X POST http://localhost:18081/ingest/barcode \
  -H 'Content-Type: application/json' \
  -d '{"barcode":"RECOVERY-CHECK-UNIQUE","scanTime":CURRENT_EPOCH_MS,"deviceId":"RECOVERY-CHECK"}'
```

HTTP 200은 producer acknowledgment까지 확인한 결과다. 이어서 ingest·processing·worker log, Kafka consumer lag, Redis lag·PEL·DLQ와 MySQL의 해당 identity를 확인해야 end-to-end 복구가 된다.

MySQL에서는 단순 전체 건수보다 방금 사용한 고유 identity를 조회한다.

```sql
SELECT original_barcode, device_id, scan_time
FROM barcodes
WHERE original_barcode = 'RECOVERY-CHECK-UNIQUE';
```

복구 완료는 다음 조건을 모두 충족해야 한다.

- broker가 controller에 등록되고 unfence됐다.
- ISR이 복원되고 URP와 unavailable partition이 0이다.
- 새 producer 요청이 처리되고 consumer lag이 수렴한다.
- Redis lag·PEL·DLQ, Kafka DLT와 retry가 설명 가능한 terminal 값으로 수렴한다.
- 새 요청의 identity가 MySQL에 한 번만 존재하며 유실·중복 부작용이 없다.

## 즉시 escalation해야 하는 경우

- leader가 없는 partition이 지속된다.
- ISR이 `min.insync.replicas` 아래에서 회복되지 않는다.
- 여러 broker 또는 controller 문제가 동시에 보인다.
- storage 유실·손상·용량 고갈이 의심된다.
- 자동 재시도 때문에 중복 비즈니스 부작용이 증가한다.
- broker 복귀 후에도 URP, lag 또는 데이터 불일치가 수렴하지 않는다.

## FR-002가 보여준 운영상 주의점

FR-002에서는 leader 전환 중 application/HTTP resend로 transport duplicate 9개가 발생했다. 따라서 장애 대응은 Kafka 복구만으로 끝나지 않는다. 요청 identity, 재시도 소유권, dedupe 결과와 최종 데이터 불변조건까지 확인해야 한다.
