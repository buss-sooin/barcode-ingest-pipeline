# BIP-FR-004 인간 개발자 장애 대응 안내서

> 상태: `HUMAN REVIEW COMPLETE`
>
> 목적: 이미 진행한 데이터가 어디까지 저장됐는지 확인하고, 안전한 재개 지점을 결정한다.
> 이 문서는 닫힌 BIP-FR-004를 다시 실행하거나 장애를 새로 주입할 권한을 부여하지 않는다.

## 대응 원칙

MySQL 장애가 보이면 처음부터 원인 가설과 모든 시스템 지표를 펼쳐 놓지 않는다. 가장 쉽게 확인할 수 있고 복구 판단에 직접 필요한 데이터부터 본다.

```text
1. 이미 진행한 작업의 범위를 정한다
2. Redis PEL에 실제로 남은 데이터를 확인한다
3. 그 데이터의 internalBarcodeId가 DB에 있는지 확인한다
4. ID별 현재 위치로 재개 지점을 정한다
5. 자동 복구가 그 집합을 줄이는지 본다
6. 설명되지 않는 ID가 있을 때만 앞 경계와 원인을 더 조사한다
```

핵심 질문은 다음 두 가지다.

> 지금까지 진행한 데이터는 어디까지 도착했는가?
>
> 아직 완료되지 않은 정확한 ID는 무엇이며 어디서 다시 처리해야 하는가?

## 1. 먼저 작업분을 보존한다

조사 중에는 다음을 하지 않는다.

- 전체 물량을 다시 스캔하도록 요청하지 않는다.
- PEL을 수동 `XACK`하거나 삭제하지 않는다.
- 오래됐다는 이유만으로 pending 전체를 강제 claim하지 않는다.
- Worker·Redis·Kafka를 함께 재시작하지 않는다.
- MySQL volume, schema 또는 Kafka offset을 변경하지 않는다.

이런 조치는 미완료 데이터의 위치를 지우거나 장애 원인과 복구 효과를 섞는다.

## 2. 이미 진행한 작업의 기준을 확보한다

가능하면 scanner 수락 목록이나 실행 manifest를 확보한다.

| 구간 | 대사에 사용할 값 |
|---|---|
| scanner → Redis | `scanTime + deviceId`, 필요하면 `originalBarcode` |
| Redis → MySQL | `internalBarcodeId` |
| Redis 소비자 그룹 내부 | Redis Record ID |

`internalBarcodeId`는 Processing Service에서 생성되므로 scanner가 수락했지만 Processing까지 도달하지 못한 데이터를 이 ID만으로 찾을 수는 없다. 앞 구간은 `scanTime + deviceId`로 연결하고, Redis 이후는 `internalBarcodeId`로 연결한다.

scanner 수락 목록이 없다면 Redis 이후 상태만 확인할 수 있다. 이 경우 “센터 작업분 전체가 전송됐다”고 단정하지 않는다.

## 3. PEL 수보다 실제 payload를 먼저 연결한다

PEL summary로 미완료 전달이 있는지 확인한다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml exec redis redis-cli XPENDING barcode:stream barcode-persistence-group
```

pending이 있으면 Redis Record ID, owner, idle, delivery count를 확인한다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml exec redis redis-cli XPENDING barcode:stream barcode-persistence-group - + 1000
```

PEL의 Redis Record ID만으로는 어떤 업무 데이터인지 알 수 없다. 그 ID로 Stream payload를 읽는다. 다음은 이번 실행에서 실제 pending이었던 ID의 예다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml exec redis redis-cli XRANGE barcode:stream 1788847350399-0 1788847350399-0
```

확인할 값은 다음 네 개다.

```text
internalBarcodeId
scanTime
deviceId
originalBarcode
```

예시 Redis Record ID는 다음 `internalBarcodeId`를 가리킨다.

```text
DLV-SEOUL-CENTER-PC-001-260908-01M1ZSRRKZH73MAJNNXC19RY8F
```

## 4. 같은 internalBarcodeId가 DB에 있는지 본다

MySQL console을 연다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml exec mysql sh -c 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'
```

PEL payload에서 확인한 ID를 그대로 조회한다.

```sql
SELECT internal_barcode_id, original_barcode, device_id, scan_time
FROM barcodes
WHERE internal_barcode_id = 'DLV-SEOUL-CENTER-PC-001-260908-01M1ZSRRKZH73MAJNNXC19RY8F';
```

판단 기준은 다음과 같다.

| Redis/PEL 상태 | MySQL 상태 | 재개 판단 |
|---|---|---|
| PEL에 있고 DB에 없음 | Redis에 안전하게 남은 미저장 작업 | 이 ID를 application reclaim으로 재처리 |
| PEL과 DB 양쪽에 있음 | DB commit 뒤 ACK 전이거나 중복 재처리 중 | 새 스캔을 만들지 말고 idempotent 재처리·ACK 경계 확인 |
| Redis cohort에 있고 DB에 없음 | 아직 DB까지 가지 않은 작업 | Redis payload부터 처리 재개 |
| accepted에는 있으나 Redis와 DB에 없음 | MySQL 장애만으로 설명되지 않는 작업 | Processing·Kafka·Ingest 순으로 앞 경계 조사 |
| DB에 있고 최종 PEL에 없음 | 완료된 작업 후보 | 전체 ID 집합 대사에서 완료 확정 |

표본 한두 건은 장애 형태를 빠르게 확인하기 위한 것이다. 재스캔이나 복구 완료를 결정할 때는 전체 ID 집합을 비교한다.

## 5. MySQL이 돌아오면 미완료 ID 집합이 줄어드는지 본다

DB readiness만 확인한다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml exec mysql sh -c 'mysqladmin ping -h localhost -u"$MYSQL_USER" -p"$MYSQL_PASSWORD"'
```

현재 Worker는 60초마다 pending을 확인하고 5분 이상 idle인 Redis Record ID를 reclaim한다. 기존 persistence path에서 MySQL 저장이 성공한 뒤 `XACK`한다.

따라서 다음 변화를 함께 본다.

```text
Redis에는 있고 MySQL에는 없는 internalBarcodeId 감소
MySQL의 동일 internalBarcodeId 증가
PEL 감소
최종 차집합 0
```

PEL만 감소하고 MySQL ID가 늘지 않으면 완료가 아니다. DLQ 이동이나 잘못된 ACK 가능성을 확인한다. MySQL row 수만 늘어도 기대 ID가 빠지고 다른 ID가 섞일 수 있으므로 완료가 아니다.

## 6. 진행하지 않을 때만 원인 조사를 넓힌다

MySQL이 정상인데 미저장 ID가 줄지 않으면 다음 순서로 확인한다.

1. pending idle이 reclaim 기준인 5분을 넘었는가?
2. owner 또는 delivery count가 변하는가?
3. Worker가 pending 후보를 조회하고 claim하는가?
4. 같은 ID 또는 같은 시간대에 DB 오류가 계속되는가?
5. 같은 ID가 Redis DLQ 또는 Kafka DLT로 이동했는가?
6. Worker restart·OOM 또는 Redis 연결 장애가 함께 발생했는가?

이 단계에서 전체 service와 Worker 로그를 확인한다.

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml ps
```

```bash
docker compose --env-file .env -f docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/docker-compose.validation.yml logs --since 10m worker-1 worker-2
```

로그는 앞 단계에서 얻은 `internalBarcodeId`, Redis Record ID와 시간대를 중심으로 읽는다. 처음부터 모든 로그에서 원인을 추측하지 않는다.

## 7. 복구 완료를 ID 집합으로 판단한다

복구 완료 조건은 다음과 같다.

```text
accepted identity 전체
= MySQL 저장 identity
 + DLQ/DLT로 명시적으로 귀속된 identity
 + 아직 책임 주체가 명확한 pending identity
```

그리고 다음 조건을 만족해야 한다.

- 어느 상태에도 없는 unaccounted ID가 없다.
- 두 최종 상태에 동시에 속한 conflict ID가 없다.
- 완료 선언 시 pending ID가 없거나 각 pending의 책임과 처리 계획이 명확하다.
- Redis payload의 `internalBarcodeId`와 MySQL 저장 ID가 일치한다.
- scanner 수락분과 Redis·MySQL의 `scanTime` 집합이 일치한다.

```text
MySQL healthy ≠ 복구 완료
Group Lag 0 ≠ 복구 완료
PEL 0 ≠ ID 정합성 확인
row count 일치 ≠ ID 집합 일치
```

## 8. 이번 실행에서 확정된 재개 지점

BIP-FR-004 주 실행에서는 다음이 확인됐다.

| 확인 | 결과 |
|---|---:|
| accepted `scanTime` | 750개 |
| Redis·MySQL `scanTime` 차집합 | 양방향 0개 |
| Redis·MySQL `internalBarcodeId` | 각각 750개, 양방향 차집합 0개 |
| outage PEL Record ID | 252개 |
| 위 252개 중 최종 MySQL 누락 ID | 0개 |
| 최종 PEL / DLQ / DLT / unaccounted / conflict | 모두 0 |

따라서 이 bounded run에서는 이미 진행한 750개 전부의 최종 위치가 MySQL로 확인됐다. 재스캔하거나 특정 중간 지점부터 다시 시작할 잔여 작업은 없다.

## 9. 현재 운영 도구의 부족한 점

Repository에는 live PEL payload 전체와 MySQL ID 전체를 읽어 차집합을 한 번에 보여 주는 사람용 도구가 없다. 다량의 Redis Record ID를 사람이 하나씩 복사하는 방식은 실제 장애 대응에 적합하지 않다.

필요한 read-only reconciliation 출력은 다음과 같다.

```text
accepted but not in Redis
Redis but not in MySQL
PEL and not in MySQL
PEL and already in MySQL
DLQ/DLT identities
unaccounted identities
multi-state conflicts
```

이 도구와 함께 Worker가 `redisRecordId`, `internalBarcodeId`, `action`, `consumer`, `timestamp`를 구조화해 기록하면 비즈니스 상태와 Redis 전달 제어를 한 흐름으로 확인할 수 있다.

## 관련 Evidence

- [Outage PEL](./evidence/BIP-FR-004-MR-20260908T055225Z/05-redis/outage-pending.txt)
- [Redis cohort](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/redis-cohort.json)
- [MySQL final cohort](./evidence/BIP-FR-004-MR-20260908T055225Z/06-mysql/final-cohort.tsv)
- [Accepted scan times](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/accepted-scan-times.txt)
- [Final reconciliation](./evidence/BIP-FR-004-MR-20260908T055225Z/08-reconciliation/reconciliation.txt)
