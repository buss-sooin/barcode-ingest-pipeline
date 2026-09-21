# BIP-FR-005 인간 개발자 장애 대응 안내서

> 문서 상태: `FINAL — HUMAN CONFIRMED`
>
> 이 문서는 FR-005의 로컬 Compose 구성과 확인된 구현을 기준으로 한다. 운영 환경의 인증, 배포, 변경 승인과 데이터 보존 정책을 대체하지 않는다. Historical Material Run을 다시 실행하는 절차가 아니다.

## 먼저 기억할 세 가지

1. Redis가 `PONG`을 반환해도 실패한 업무가 끝난 것은 아니다.
2. DLT를 전부 replay하지 말고, 논리 식별자의 현재 소유권을 먼저 찾는다.
3. count, lag와 PEL은 진행 신호다. 복구 완료는 identity별 최종 귀속으로 판단한다.

## Layer 1 — Common Troubleshooting Core

### 1. Symptom

현상과 시간을 먼저 기록한다.

- Processing에서 Redis timeout/connection failure가 발생했는가?
- `barcode-processing-group` lag이 증가하는가?
- `barcode-events-dlt`에 새 record가 생기는가?
- Redis Stream ingress가 멈췄는가?
- Worker와 MySQL은 정상인데 새 데이터만 도달하지 않는가?

`HTTP 2xx`, process `UP`, Kafka source offset 진행 중 하나만으로 업무 완료를 판단하지 않는다.

### 2. Initial Triage

다음 순서로 장애 영역(Failure Domain)을 좁힌다.

```text
요청 수락 여부
→ Kafka append 여부
→ Processing consume 여부
→ Redis handoff 여부
→ Redis Stream acceptance 여부
→ Worker ownership 여부
→ MySQL persistence 여부
```

최소 기록 항목:

- 첫 오류 시각과 마지막 정상 시각
- 영향받은 `originalBarcode`, `scanTime`, `deviceId`
- Kafka topic/partition/offset
- DLT category와 replay-count
- Redis Record ID, consumer owner, PEL 상태
- `internalBarcodeId`와 MySQL 존재 여부

### 3. Failure-domain Narrowing

| 관측 | 우선 의심할 경계 | 아직 단정할 수 없는 것 |
|---|---|---|
| Kafka append 실패, source offset 없음 | Ingest/Kafka | Redis failure |
| Kafka source 존재, Redis timeout | Processing→Redis | Kafka unavailable |
| Redis Stream entry 존재, PEL 증가 | Worker/MySQL | Processing handoff failure |
| DLT `TRANSIENT_REDIS` | source retry 소진 뒤 DLT ownership | replay 완료 |
| quarantine record 존재 | terminal isolation | MySQL persistence |

### 4. Identity State

한 identity마다 현재 책임을 하나씩 분류한다.

```text
source-owned
DLT-owned
Redis-accepted
Worker-owned / PEL
persisted
quarantine terminal
unaccounted
```

동일 identity가 여러 상태에 나타날 수 있다. 예를 들어 C1은 원본과 replay source record가 모두 있지만 business identity는 하나다. 중복 상태가 정상 이력인지, 충돌인지 설명해야 한다.

### 5. Safe Continuation

```text
source-owned
→ natural retry / redelivery를 관찰

DLT-owned transient generation 0
→ Redis recovery 확인 뒤 bounded replay 후보

Redis-accepted
→ source replay 금지, downstream 진행 확인

Worker-owned / PEL
→ Worker reclaim·idempotent persistence 경계 확인

persisted
→ replay 금지

permanent / unknown / malformed / replay-exhausted
→ quarantine terminal
```

```text
Redis healthy
→ replay everything
```

방식은 사용하지 않는다. 먼저 `unfinished identities → current ownership → correct continuation point`를 결정한다.

### 6. Recovery

복구 조치는 확인한 원인과 권한 범위에 맞춰 최소화한다.

- Redis process만 중단됐고 volume/data identity가 보존됐으면 동일 instance를 복구한다.
- Kafka가 함께 저하됐다면 Redis-only 사고로 취급하지 않는다.
- Redis 복구 뒤 natural source retry가 남아 있으면 DLT replay와 동시에 실행해 중복을 증폭시키지 않는다.
- DLT disposition 전에 대상 partition, snapshot end offset, group ownership과 committed offset을 고정한다.
- 이미 Redis 또는 MySQL에 도달한 identity는 replay 대상에서 제외한다.

### 7. Reconciliation

다음 집합을 비교한다.

```text
accepted logical identities
= persisted
 + quarantine terminal
 + 설명 가능한 unfinished ownership
```

완료 선언 시에는 보통 unfinished가 `0`이어야 한다. 남겨야 한다면 identity, owner, continuation plan과 이유를 명시한다.

### 8. Recovery Complete

| 단계 | 확인 질문 |
|---|---|
| Infrastructure Recovery | Redis가 실제 command를 처리하는가? |
| Processing Recovery | source/replay가 Redis handoff에 성공하는가? |
| Disposition Recovery | retry/DLT/quarantine ownership이 정산됐는가? |
| Downstream Recovery | Redis-accepted identity가 Worker/MySQL로 진행하는가? |
| Identity Reconciliation | 모든 incident-scoped identity가 최종 귀속됐는가? |

Lag 0, PEL 0, DLT count, MySQL row count, process UP은 보조 지표다. identity 집합과 conflict/unaccounted 검사가 최종 기준이다.

## Layer 2 — FR-005 Failure Mechanism

### 판단 모델

```text
Kafka source는 존재한다
→ Processing이 record를 받는다
→ Redis Lua handoff가 timeout/failure
→ listener exception이 container로 전파
→ source retry
→ retry 소진 뒤 DLT publish
→ source offset은 DLT 책임 이전 뒤 진행
```

여기서 핵심 질문은 다음과 같다.

- Kafka source ownership이 아직 남아 있는가?
- retry 중인가, 소진됐는가?
- DLT로 responsibility가 이동했는가?
- Redis에 이미 accepted 됐는가?
- Worker/PEL로 downstream responsibility가 이동했는가?
- MySQL에 이미 완료됐는가?
- quarantine terminal인가?
- generation 0의 bounded replay 대상인가?

### Category와 continuation

| Category / metadata | 의미 | continuation |
|---|---|---|
| `TRANSIENT_REDIS`, replay-count 없음/0 | 일시 Redis failure | 복구 확인 뒤 최대 한 번 replay |
| `TRANSIENT_REDIS`, replay-count ≥1 | replay 소진 | quarantine |
| `PERMANENT_VALIDATION` | 재시도로 바뀌지 않는 입력 오류 | quarantine |
| `UNKNOWN` | 원인 분류 불가 | fail closed, quarantine |
| malformed replay-count | 안전한 generation 판단 불가 | fail closed, quarantine |

### DLT commit boundary

Disposition은 output publish 성공 뒤에만 해당 DLT offset을 commit한다. 이 순서는 output loss 위험을 줄이지만 publish와 commit이 transaction 하나가 아니므로 commit 전 failure 시 duplicate publication이 가능하다. 같은 identity의 replay output 수와 final state를 다시 확인한다.

## Layer 3 — BIP-FR-005 Project Adapter

### 실제 구성

| 책임 | 실제 이름 |
|---|---|
| Source topic | `barcode-events` |
| Source consumer group | `barcode-processing-group` |
| DLT | `barcode-events-dlt` |
| DLT disposition group | `barcode-events-dlt-disposition` |
| Quarantine topic | `barcode-events-quarantine` |
| Redis Stream | `barcode:stream` |
| Redis Worker group | `barcode-persistence-group` |
| Worker DLQ | `barcode:stream:dlq` |
| Business identity | `originalBarcode`, `scanTime`, `deviceId` |
| Redis/MySQL bridge identity | `internalBarcodeId` |

아래 명령은 repository root에서 실행한다. 두 Compose 파일은 FR-005가 사용한 로컬 validation topology를 선택한다. 조회 명령부터 실행하고, 상태 변경 명령은 별도 절의 조건을 만족할 때만 사용한다.

### 1. Container와 Redis 상태 확인

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  ps --all
```

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec redis redis-cli PING
```

`PONG`은 infrastructure recovery만 의미한다.

### 2. Kafka failure domain 분리

세 topic 각각의 leader, replicas와 ISR을 확인한다.

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec broker-1 kafka-topics --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --topic barcode-events
```

같은 명령의 마지막 topic을 `barcode-events-dlt`, `barcode-events-quarantine`으로 바꿔 반복한다. leader 없음, ISR 부족, unavailable partition 또는 broker OOM/restart가 함께 있으면 Redis-only 원인으로 단정하지 않는다.

### 3. Source consumer ownership 확인

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec broker-1 kafka-consumer-groups \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --group barcode-processing-group
```

`LAG`은 backlog 크기다. 특정 identity가 retry 중인지 DLT로 이동했는지는 Processing log와 DLT record를 추가로 확인해야 한다.

### 4. DLT와 disposition group 확인

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec broker-1 kafka-get-offsets \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --topic barcode-events-dlt
```

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec broker-1 kafka-consumer-groups \
  --bootstrap-server broker-1:29092,broker-2:29092,broker-3:29092 \
  --describe --group barcode-events-dlt-disposition
```

Group이 아직 생성되지 않았다는 오류는 disposition을 한 번도 실행하지 않았다는 뜻일 수 있다. DLT가 비었다는 뜻은 아니다.

### 5. Redis Stream ownership 확인

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec redis redis-cli XINFO GROUPS barcode:stream
```

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec redis redis-cli XPENDING barcode:stream barcode-persistence-group
```

PEL이 있으면 summary count로 끝내지 말고 range를 조회해 Redis Record ID, owner, idle time과 delivery count를 확보한다.

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec redis redis-cli XPENDING barcode:stream barcode-persistence-group - + 100
```

### 6. 한 business identity의 Redis acceptance 확인

아래의 `<ORIGINAL_BARCODE>`를 실제 incident identity로 바꾼다.

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec redis redis-cli --raw XRANGE barcode:stream - + COUNT 10000
```

출력에서 `originalBarcode`, `scanTime`, `deviceId`, `internalBarcodeId`를 함께 확인한다. 운영 데이터가 많다면 전체 XRANGE 대신 승인된 read-only 조회 도구나 time-bounded export를 사용한다. `<ORIGINAL_BARCODE>`가 보이지 않는다는 사실만으로 source loss를 단정하지 말고 DLT와 Kafka source를 확인한다.

### 7. MySQL 최종 identity 확인

MySQL container의 `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`는 Compose가 주입한 실행 환경 변수다. 아래 placeholder를 실제 identity로 바꾼다.

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  exec mysql sh -lc 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" --batch --raw -e "SELECT internal_barcode_id, original_barcode, device_id, scan_time, processed_time, saved_time FROM barcodes WHERE original_barcode = '\''<ORIGINAL_BARCODE>'\'';"'
```

결과가 있으면 같은 identity를 source나 DLT에서 다시 replay하지 않는다.

## 승인된 continuation을 선택하는 표

| Source | DLT | Redis | MySQL | 안전한 다음 단계 |
|---|---|---|---|---|
| retry/pending | 없음 | 없음 | 없음 | natural retry 관찰. 수동 replay 금지 |
| 완료 | transient gen 0 | 없음 | 없음 | Redis health와 대상 identity 확인 뒤 bounded disposition 후보 |
| 완료 | 있음 | 있음 | 없음 | source/DLT replay 금지. Worker ownership과 PEL 조사 |
| 완료 | 있음/과거 이력 | 있음 | 있음 | 완료. 재처리 금지, duplicate 여부만 확인 |
| 완료 | permanent/unknown/malformed | 없음 | 없음 | quarantine terminal 확인 |
| 어디에도 없음 | 없음 | 없음 | 없음 | unaccounted. 앞 경계와 Evidence를 확대하고 자동 복구 중단 |

## 상태 변경 전 Human Gate

다음은 조회가 아니라 상태 변경이다.

- Redis start/restart
- DLT disposition 실행
- Worker restart 또는 PEL reclaim
- offset reset/seek
- DLT·quarantine record 삭제
- topic 재생성

FR-005와 같은 로컬 구성에서 Redis process만 중단됐고 동일 container/volume identity 보존과 변경 권한을 확인했다면 다음 명령은 infrastructure recovery가 될 수 있다.

```bash
docker compose --env-file .env \
  -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-005-redis-streams-unavailability/docker-compose.release.yml \
  start redis
```

그러나 현재 `docker-compose.release.yml`은 Historical Run 준비 artifact다. Verified successor Run의 exact frozen image·등록 identity를 재구성하는 실행 파일로 재사용하지 않는다. DLT disposition도 현재 incident의 release identity, committed offsets, startup snapshot과 승인 경계를 별도로 고정한 뒤 실행해야 한다. 이 문서에서 historical Run command를 복사해 replay하지 않는다.

다음은 원인과 별도 승인 없이 수행하지 않는다.

- DLT 전체 무차별 replay
- `barcode-events-dlt-disposition` offset reset
- quarantine replay
- 이미 Redis/MySQL에 존재하는 identity 재발행
- historical residue 삭제
- 장애를 빨리 끝내기 위한 category 또는 replay-count 수정

## FR-005 Recovery Complete checklist

- Redis command와 health가 안정적으로 성공한다.
- Kafka broker/ISR/URP/unavailable partition이 incident를 지배하지 않는다.
- source retry가 끝났거나 각 pending identity의 owner가 설명된다.
- DLT record마다 root source identity, category, replay-count와 disposition이 확인된다.
- replay 대상은 generation 0 transient identity로 제한된다.
- quarantine terminal identity는 다시 replay되지 않는다.
- Redis-accepted identity는 Worker/MySQL 진행이 확인된다.
- source/DLT consumer lag, Redis group lag와 PEL이 0 또는 명시적 terminal 상태로 수렴한다.
- persisted identity를 다시 처리하지 않는다.
- missing, extra, duplicate conflict와 unaccounted identity가 없다.

## 즉시 escalation해야 하는 경우

- Redis와 Kafka 또는 MySQL의 복합 장애
- Kafka broker OOM/restart, unavailable partition 또는 ISR 저하 동반
- DLT metadata가 root source identity와 연결되지 않음
- replay-count가 malformed이거나 category가 신뢰되지 않음
- publish 성공 뒤 commit 실패가 의심됨
- 같은 generation output duplicate가 업무 부작용을 만듦
- Redis Stream entry와 MySQL row의 identity가 충돌함
- PEL owner가 사라졌거나 reclaim 정책이 불명확함
- offset reset, topic truncation, data deletion이 필요해 보임
- unaccounted identity가 남음

## 관련 자료

- [Scenario explanation](./SCENARIO-EXPLANATION.md)
- [Reproduction Record](./REPRODUCTION-RECORD.md)
- [R1 Reproduction Contract](./REPRODUCTION-CONTRACT.md)
- [Verified Run final runtime state](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/final-runtime-state.txt)
- [Verified Run identity accounting](./evidence/BIP-FR-005-MR-20260915T031000Z/04-material-run/05-reconciliation/identity-accounting.txt)
