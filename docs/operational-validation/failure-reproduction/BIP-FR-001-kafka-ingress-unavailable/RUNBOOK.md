# BIP-FR-001 — Kafka Ingress Broker Unavailable 복구 Runbook

| 항목 | 값 |
|---|---|
| Status | `APPROVED DESIGN IMPLEMENTATION` |
| Applicable scenario | `BIP-FR-001 — Active Scan 중 Kafka ingress broker unavailable` |
| Applicable repository revision | `a5e32481cb7bcf70ce53cf11ad90c685e6bdec1c` 기준 구현·Compose 동작 |
| Applicable branch | `validation/bip-fr-001-kafka-unavailable` |
| Primary recovery | 보존된 동일 Kafka container의 availability 복원 |
| Completion model | `Component Recovery → Flow Recovery → Backlog Drain → End-to-end Reconciliation` |

> 이 문서의 `820`, `1,235`, `415`는 Material Run의 Evidence 예시다. 운영 임계값이나 완료 기준이 아니다.

## 1. 목적과 책임 경계

이 Runbook은 운영 진단을 통해 Kafka broker availability가 최초로 끊어진 경계(First Broken Boundary)로 확인된 뒤 사용한다. 운영자는 검증된 범위 안에서 **보존된 동일 Kafka container**를 시작하고, 구성요소 복구(Component Recovery), 흐름 복구(Flow Recovery), 백로그 소진(Backlog Drain), 종단 간 조정(End-to-end Reconciliation)을 순서대로 검증한다.

이 문서의 단일 책임은 다음과 같다.

- 복구 진입 조건과 필요한 권한을 확인한다.
- 검증된 단일 상태 변경과 안전 경계를 제시한다.
- 각 Recovery Gate의 관측, 진행 조건, 중단 조건을 제시한다.
- 영향을 받은 논리 식별자(Logical Identity)를 terminal state까지 설명하고 복구 완료(Recovery Complete)를 판정한다.
- 실행 사실, 관측, 결정, 승인 참조를 incident Evidence로 남긴다.

다음 Artifact의 책임은 복제하지 않는다.

- [운영 진단 가이드](./OPERATIONAL-DIAGNOSTIC-GUIDE.md): 장애 영역을 관측하고 추론하여 복구 대상을 결정한다.
- [Kafka 장애 학습 노트](./KAFKA-FAILURE-LEARNING-NOTE.md): Kafka, Redis, 분산 시스템 현상이 발생하는 이유를 설명한다.
- [재현 기록](./REPRODUCTION-RECORD.md): 검증 실행의 실제 Evidence와 판정을 보존한다.
- 향후 Technical Report: 전체 검증 질문과 Evidence를 종합한다.

진단이 끝나지 않았거나 First Broken Boundary가 불명확하면 이 Runbook으로 복구를 시작하지 않는다. [운영 진단 가이드](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)로 돌아간다.

## 2. 대상 독자와 필요한 권한

대상 독자는 다음 권한과 책임을 가진 운영자다.

- incident 환경과 business impact를 판단할 수 있다.
- 대상 Compose project와 Kafka container 상태를 읽을 수 있다.
- 승인된 Compose context에서 기존 Kafka container를 시작할 수 있다.
- Kafka topic·consumer group, Redis Stream·PEL, application logs·metrics, MySQL read-only reconciliation을 조회할 수 있다.
- 변경 승인과 incident Evidence 보존 절차를 따른다.
- 완료 또는 escalation 판정에 최종 책임을 진다.

관측 도구나 AI의 제안은 운영자의 승인과 독립 검증을 대신하지 않는다. Credential, secret, 불필요한 host·machine identifier는 명령 출력이나 Evidence에 남기지 않는다.

## 3. 적용 범위와 활성화 조건

다음 조건을 **모두** 만족할 때만 이 Runbook을 활성화한다.

- Active scan 중 Ingest에서 Kafka ingress broker로 가는 경계가 unavailable하다.
- 독립 broker/topic probe와 application Evidence를 결합해 Kafka availability를 First Broken Boundary로 확인했다.
- Scanner, Ingest, Processing, Redis, Worker, MySQL이 각각 더 이른 First Broken Boundary가 아니다.
- 기존 Kafka container가 존재한다.
- 해당 container의 identity와 writable layer가 보존되어 있다.
- 동일 container를 시작해 availability를 복원하는 것이 승인된 기본 복구다.
- 복구 뒤 기존 retry, consume, dedupe, persistence 경로를 그대로 사용한다.
- 아래 네 Compose file이 동일 project context를 구성하는 검증 환경이다.

다음 상황은 적용 범위를 벗어난다.

- Kafka container가 없거나 기존 identity를 확인할 수 없다.
- container identity가 바뀌었거나 recreate 정황이 있다.
- writable layer 또는 Kafka storage loss·corruption 정황이 있다.
- topic, partition, offset, broker identity 또는 storage를 바꿔야 복구할 수 있다.
- 다른 component의 장애가 먼저 발생했거나 여러 장애 영역이 경합한다.
- 대상 환경의 Compose context가 아래 검증 환경과 다르다.

적용 범위를 벗어나면 상태를 바꾸지 말고 중단한다. 별도 영향 분석과 사람 승인 관문(Human Gate)으로 escalation한다.

## 4. 사전 조건과 Incident Context

복구 전에 다음 context를 incident record에 고정한다.

- [ ] Incident ID
- [ ] 실행 환경과 Compose project 식별
- [ ] UTC incident 시작 시각과 Runbook 활성화 시각
- [ ] Repository revision과 이 Runbook revision
- [ ] First Broken Boundary 판정 및 근거 Evidence 위치
- [ ] 실행자, 검토자, 필요한 승인 참조
- [ ] 영향을 받은 logical identity cohort, manifest 또는 accounting cut
- [ ] 신규 traffic의 지속 여부와 종료·watermark 조건
- [ ] pre-recovery Kafka container ID, status, image identity
- [ ] writable layer·storage 보존 근거와 recreate 부재 근거
- [ ] Scanner retry, Kafka lag, Redis group lag, Redis PEL, DLQ, DLT, MySQL의 pre-recovery sample

### 4.1 사전 상태 고정

| 필드 | 내용 |
|---|---|
| **Entry Condition** | 진단 handoff가 존재하고 아직 복구 명령을 실행하지 않았다. 대상 Compose context에 read 권한이 있다. |
| **Action** | 현재 UTC 시각, repository·Runbook revision, Compose project를 기록한다. `docker compose ps -q kafka`로 container ID를 얻고 read-only inspect로 status와 image identity를 기록한다. affected cohort와 현재 backlog sample을 같은 시각축에 고정한다. |
| **Expected Observation** | 기존 Kafka container 한 개가 식별되고, identity·image·status·storage 보존 여부와 affected cohort 경계가 Evidence로 남는다. |
| **Decision / Stop Condition** | identity와 writable layer가 보존됐으면 적용성 평가로 진행한다. container 부재, identity 불일치, recreate·storage loss 정황, cohort 정의 불가가 있으면 상태를 바꾸지 않고 중단한다. cohort만 정의할 수 없는 경우 복구 필요성은 별도 승인에 따르되 최종 선언은 `Flow Recovered`를 넘을 수 없다. |

read-only 확인 예시는 다음과 같다. 실제 project name과 출력 보존 위치는 incident 절차를 따른다.

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  ps -q kafka
```

Container ID를 unresolved 변수나 glob으로 다른 명령에 넘기지 않는다. 먼저 명시적으로 확인한 뒤 승인된 read-only inspect 절차로 조회한다.

## 5. 안전 경계

- 상태 변경은 아래의 검증된 `start kafka` 한 번으로 제한한다.
- 다른 component는 복구 대상으로 추정하지 않는다.
- timeout, HTTP `207` 또는 HTTP `503`을 Kafka append 실패나 event loss의 확정 증거로 해석하지 않는다.
- broker probe 성공을 전체 흐름이나 데이터 복구 완료로 해석하지 않는다.
- 백로그가 느리게 줄어든다는 이유만으로 state를 삭제·재배치·재생성하지 않는다.
- 모든 query와 log 수집은 read-only로 수행하고 Credential을 Evidence에서 제거한다.
- 모순되거나 stale한 Evidence는 조용히 보정하지 않고 중단 사유로 기록한다.

### 5.1 재시작 안전성

**Scanner를 재시작하지 않는다.** Scanner retry queue는 process-local memory의 `ConcurrentLinkedQueue`다. 재시작하면 미처리 retry state가 소실될 수 있으며 queue가 가득 차도 drop 위험이 있다. 근거는 [FailureRetryService.java](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/FailureRetryService.java)다.

**Ingest를 재시작하지 않는다.** Ingest는 Kafka send confirmation을 5초 기다리지만 timeout 시 send Future를 취소하지 않는다. HTTP 실패는 “그 시간 안에 성공을 확인하지 못함”이며 background send가 계속될 수 있다. 재시작은 이 확인 불확실성(Acknowledgment Uncertainty) 상태를 바꿀 수 있다. 근거는 [BarcodeIngestController.java](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/controller/BarcodeIngestController.java)다.

**Worker를 재시작하거나 consumer identity를 바꾸지 않는다.** Worker는 환경에서 고정된 consumer name을 받고 Redis consumer group을 공유한다. PEL entry는 60초 주기로 확인하고 5분 이상 idle인 entry를 claim해 재처리한다. 임의 재시작이나 identity 변경은 pending ownership과 복구 관측을 바꿀 수 있다. 근거는 [RedisStreamConsumer.java](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/service/RedisStreamConsumer.java)와 [docker-compose.apps.yml](../../../../docker-compose.apps.yml)이다.

이 제한은 “모든 재시작은 항상 데이터를 잃는다”는 일반 명제가 아니다. 현재 구현과 검증 범위에서 restart를 기본 복구로 승인할 Evidence가 없고 현재 in-flight·retry·PEL 상태를 변경할 수 있다는 좁은 판단이다.

## 6. 금지 행동과 중대 조치

다음 행동은 이 Runbook의 실행 가능한 기본 절차가 아니다.

- Kafka offset reset
- topic 삭제 또는 재생성
- Kafka container 삭제, 교체 또는 재생성
- Redis Stream 또는 PEL clear
- 수동 `XACK`
- Scanner retry backlog purge
- DLQ 또는 DLT 삭제
- 임의 replay 또는 traffic replay
- DB insert, update, delete
- unique constraint 변경
- Scanner 또는 Ingest restart
- Processing, Redis, Worker 또는 MySQL restart
- consumer identity 변경

이 행동들은 loss, duplicate, 재처리 범위, pending ownership, forensic Evidence를 바꿀 수 있다. 필요해 보이면 이 Runbook을 중단하고 대상 identity·offset 범위, 데이터 영향, backup·rollback·verification 계획, 실행 권한과 승인자, 기존 Evidence 보존 방법을 포함한 별도 영향 분석과 Human Gate를 요청한다. 이 문서는 위 행동의 명령어를 제공하지 않는다.

## 7. Detect Handoff

이 단계는 장애를 새로 진단하지 않고 진단 결과가 복구 실행에 충분한지 인수한다.

| 필드 | 내용 |
|---|---|
| **Entry Condition** | [운영 진단 가이드](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)에 따라 First Broken Boundary 판정이 끝났다. |
| **Action** | 같은 incident window에서 Ingest producer 연결·전송 확인 실패, application 밖 broker/topic probe 실패, Kafka·downstream progression 중단, Redis·MySQL 및 다른 application의 독립 상태를 묶은 Evidence를 인수한다. 진단자와 실행자가 다르면 handoff 시각과 책임자를 기록한다. |
| **Expected Observation** | 단일 HTTP 또는 log가 아니라 서로 독립적인 Evidence가 Kafka availability를 최초 장애 경계로 지시하고 다른 component가 더 이른 원인이 아님을 설명한다. |
| **Decision / Stop Condition** | Evidence가 일관되고 최신이면 Assess로 진행한다. application error만 있거나 broker probe가 이를 반증하거나 복수 장애가 있으면 Runbook을 활성화하지 않고 진단으로 반환한다. |

최소 handoff Evidence는 Ingest failure 시각, Kafka container와 독립 broker/topic probe, Processing·Redis·Worker·MySQL progression, Scanner retry 상태 또는 관측성 공백, Redis·MySQL 독립 health, affected cohort 또는 watermark/accounting cut이다.

## 8. Assess

### 8.1 적용성·영향 범위 평가

| 필드 | 내용 |
|---|---|
| **Entry Condition** | Detect handoff가 수락됐고 아직 상태 변경을 하지 않았다. |
| **Action** | 적용 조건을 하나씩 확인한다. 기존 Kafka container의 ID·image·status와 storage 보존 여부를 pre-recovery Evidence로 고정한다. traffic이 계속된다면 affected cohort를 분리할 watermark/accounting cut을 정한다. Scanner retry, Kafka lag, Redis group lag·PEL, DLQ·DLT, MySQL terminal identity의 초기값을 수집한다. |
| **Expected Observation** | 복구 대상이 보존된 동일 Kafka container 하나로 좁혀지고 영향을 받은 logical identity와 backlog의 시작 경계를 설명할 수 있다. |
| **Decision / Stop Condition** | 동일 container start가 충분하고 cohort가 정의되면 승인 확인으로 진행한다. container 부재·identity 변경·storage 이상·다른 장애·필요 권한 부재면 중단한다. cohort가 불명확하면 그 공백과 `Recovery Complete` 보류 조건을 명시한다. |

### 8.2 변경 승인 확인

| 필드 | 내용 |
|---|---|
| **Entry Condition** | 기술적 적용성은 확인됐으며 recovery 명령은 아직 실행하지 않았다. |
| **Action** | 실행자, 승인 참조, 허용된 Compose context, primary action, 금지 행동을 교차 확인한다. 명령의 네 `-f` 경로와 대상 service가 정확히 `kafka`인지 검토한다. |
| **Expected Observation** | 승인 범위가 “동일 Kafka container start”로 명확하고 다른 state-changing action이 포함되지 않는다. |
| **Decision / Stop Condition** | 승인과 명령 context가 일치하면 Recover로 진행한다. 승인 불명확, 다른 환경, 오타, 추가 service·flag가 있으면 실행하지 않는다. |

## 9. Recover

### 9.1 보존된 동일 Kafka container 시작

| 필드 | 내용 |
|---|---|
| **Entry Condition** | Kafka availability가 First Broken Boundary로 확인됐다. 기존 container와 writable layer가 보존됐다. 네 Compose file의 검증 context와 실행 승인이 일치한다. pre-recovery identity와 UTC 시각을 기록했다. |
| **Action** | 아래 명령을 **한 번** 실행한다. 명령 시작·종료 UTC 시각, 표준 출력·오류, exit code를 보존한다. |
| **Expected Observation** | Compose가 기존 `kafka` container를 시작하며 명령이 성공한다. post-recovery container ID가 pre-recovery ID와 동일하다. container가 시작 상태로 전이하며 broker는 readiness까지 시간이 걸릴 수 있다. |
| **Decision / Stop Condition** | exit code가 성공이고 identity가 동일하면 Component Recovery 검증으로 진행한다. 명령 실패, 새 container 생성, ID 변경, storage·broker identity 이상, 반복 start 필요가 발생하면 추가 변경 없이 중단하고 escalation한다. 명령 성공만으로 `Recovery Complete`를 선언하지 않는다. |

검증 환경에서 승인되고 Material Run에서 사용된 유일한 primary state-changing action은 다음과 같다.

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  start kafka
```

이 명령을 다른 환경에 일반화하지 않는다. `docker compose up`, container recreation, remove/recreate는 동등한 복구가 아니다.

## 10. Gate 1 — Component Recovery 검증

### 10.1 Container identity와 broker 응답 확인

| 필드 | 내용 |
|---|---|
| **Entry Condition** | 승인된 `start kafka`가 종료됐고 추가 상태 변경을 하지 않았다. |
| **Action** | post-recovery container ID·status·image identity를 수집해 pre-recovery 값과 비교한다. application 밖에서 broker metadata와 `barcode-events` topic을 read-only probe한다. kafka-exporter를 사용한다면 process 상태뿐 아니라 현재 broker metadata, `kafka_brokers`, scrape freshness를 함께 확인한다. |
| **Expected Observation** | container ID와 image identity가 유지되고 status가 running이다. broker metadata와 기존 topic·partition 정보가 응답하며 exporter의 현재 sample이 broker를 다시 관측한다. |
| **Decision / Stop Condition** | 독립 broker/topic probe가 성공하고 identity가 유지되면 `Component Recovered`를 기록하고 Flow Recovery로 진행한다. timeout 중이면 승인된 관측 window 안에서 read-only probe를 반복할 수 있다. identity 변경, topic·partition 불일치, probe 지속 실패, exporter stale·conflicting signal이면 중단하고 escalation한다. |

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec kafka kafka-topics --bootstrap-server kafka:29092 --describe --topic barcode-events
```

Broker 응답은 Kafka component availability만 증명한다. 미확인 send 완료, retry 소진, downstream persistence 또는 business correctness는 증명하지 않는다.

## 11. Gate 2 — Flow Recovery 검증

Flow Recovery는 기존 traffic·retry 경로가 자연스럽게 진행되는 것을 관측한다. 이 Runbook은 검증을 위한 임의 traffic replay를 허용하지 않는다.

### 11.1 Publish와 consume 재개

| 필드 | 내용 |
|---|---|
| **Entry Condition** | `Component Recovered`가 확인됐고 기존 Ingest·Processing이 재시작 없이 유지된다. |
| **Action** | recovery 뒤 첫 Kafka publish acknowledgment와 partition·offset log, Processing의 첫 resumed consume 시각을 관측한다. consumer group을 read-only 조회해 committed offset과 lag가 다시 움직이는지 확인한다. |
| **Expected Observation** | 새 또는 retry logical event의 publish가 확인되고 Processing consume가 재개된다. end offset과 committed offset이 정상 방향으로 진행한다. |
| **Decision / Stop Condition** | publish와 consume가 모두 재개되면 downstream 흐름 확인으로 진행한다. broker만 응답하고 publish가 실패하거나 consumer progression이 없으면 `Component Recovered` 상태에 머물며 원인을 escalation한다. offset reset이나 Processing restart를 시도하지 않는다. |

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec kafka kafka-consumer-groups --bootstrap-server kafka:29092 --describe --group barcode-processing-group
```

### 11.2 Redis write, Worker read, MySQL persistence 재개

| 필드 | 내용 |
|---|---|
| **Entry Condition** | recovery 뒤 publish와 Processing consume가 확인됐다. |
| **Action** | Processing의 Redis dedupe·XADD 성공, Redis Stream progression, Worker read, affected logical identity의 MySQL persistence를 동일 시간축에서 확인한다. 단일 health endpoint가 아니라 logs·metrics·read-only query를 교차 확인한다. |
| **Expected Observation** | Kafka consume 이후 Redis Stream이 진행하고 Worker가 읽으며 대응 logical identity가 MySQL terminal state로 진행한다. duplicate transport record가 있다면 dedupe 경로가 이를 분류한다. |
| **Decision / Stop Condition** | publish → consume → Redis write → Worker read → MySQL persistence가 연결되면 `Flow Recovered`를 기록하고 Backlog Drain으로 진행한다. 어느 경계에서든 progression이 멈추거나 DLQ·DLT가 증가하면 완료를 선언하지 않고 해당 경계와 affected identity를 기록해 escalation한다. Redis·Worker·MySQL restart나 수동 `XACK`을 실행하지 않는다. |

Flow Recovery는 “새 흐름이 다시 진행된다”는 판정이다. 장애 동안의 모든 affected identity가 처리됐다는 판정은 아니다.

## 12. Gate 3 — Backlog Drain 검증

### 12.1 계층별 백로그 수렴 관측

| 필드 | 내용 |
|---|---|
| **Entry Condition** | `Flow Recovered`가 확인됐고 affected cohort 또는 accounting cut이 정의됐다. 신규 traffic의 포함·제외 기준이 명확하다. |
| **Action** | 같은 UTC sample에서 Scanner retry remaining, Kafka `barcode-processing-group` lag, Redis `barcode-persistence-group` lag·PEL, DLQ, DLT를 수집한다. affected cohort 기준으로 추세를 관찰하고 최소 두 번의 연속 수렴 sample을 남긴다. |
| **Expected Observation** | retry, Kafka lag, Redis group lag, PEL, 미검토 DLQ·DLT가 affected cohort 기준 terminal 값으로 수렴한다. 두 연속 sample 사이에 새 pending 또는 unaccounted identity가 생기지 않는다. |
| **Decision / Stop Condition** | 모든 계층이 두 연속 sample에서 수렴하면 `Backlog Drained`를 기록하고 reconciliation로 진행한다. 값이 증가·정체·진동하거나 queue drop, 새 DLQ·DLT, 관측 불능이 있으면 완료를 선언하지 않는다. purge, replay, offset reset, PEL clear를 하지 않고 escalation한다. |

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec redis redis-cli XINFO GROUPS barcode:stream
```

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.apps.yml \
  -f monitoring-compose.yml \
  -f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml \
  exec redis redis-cli XPENDING barcode:stream barcode-persistence-group
```

Scanner retry queue는 현재 전용 metric·endpoint가 없고 logs로만 계량할 수 있다. `Retry summary ... Remaining in queue`와 queue full/drop log를 확인하되 log 누락 가능성을 Evidence 한계로 기록한다. Kafka lag 0은 Redis·MySQL 완료를 뜻하지 않고 Redis PEL 0은 전체 backlog나 business correctness를 뜻하지 않는다.

### 12.2 지속 traffic과 관측성 공백

| 필드 | 내용 |
|---|---|
| **Entry Condition** | 신규 traffic이 계속되어 전체 lag·row count가 정지하거나 0이 되지 않는다. |
| **Action** | affected cohort를 분리하는 logical identity range, manifest, timestamp watermark 또는 승인된 accounting cut으로 incident 대상만 계산한다. cut 이후 traffic을 별도로 표시한다. |
| **Expected Observation** | 전체 시스템이 계속 움직여도 incident affected identity의 pending·terminal 상태와 계층별 backlog를 분리할 수 있다. |
| **Decision / Stop Condition** | cohort를 신뢰성 있게 분리할 수 있으면 수렴 판정을 계속한다. 분리할 수 없으면 `Flow Recovered`까지만 선언하고 `Recovery Complete`를 보류해 observability gap으로 escalation한다. 전체 lag나 총 row count로 완료를 추정하지 않는다. |

## 13. Gate 4 — 종단 간 조정

### 13.1 Logical Identity accounting

Kafka transport record 수와 logical event 수를 분리한다. retry와 미확인 background send가 모두 성공하면 하나의 logical identity가 여러 Kafka record로 나타날 수 있다.

```text
Generated logical identities
= MySQL terminal identities
+ DLQ terminal identities
+ DLT terminal identities
+ still-pending identities
+ unaccounted identities
```

### 13.2 Manifest 대조

| 필드 | 내용 |
|---|---|
| **Entry Condition** | `Backlog Drained`가 확인됐고 affected logical identity manifest 또는 accounting cut을 조회할 수 있다. |
| **Action** | generated identity set을 MySQL terminal set, DLQ, DLT, still-pending과 대조한다. missing, expected manifest 밖 extra, final duplicate row, unaccounted를 집합 기준으로 계산한다. Kafka record가 logical identity보다 많으면 transport duplicate 수와 fallback·retry·dedupe containment 경로를 설명한다. |
| **Expected Observation** | affected identity 각각이 정확히 하나의 승인된 terminal category로 설명된다. still-pending과 unaccounted가 0이고 final duplicate와 manifest 밖 extra row가 없다. transport duplicate가 있으면 수와 containment Evidence가 일치한다. |
| **Decision / Stop Condition** | 집합 대조와 두 연속 terminal sample이 모두 일치하면 Recovery Complete Gate로 진행한다. total count만 맞거나 identity manifest가 없거나 missing·extra·duplicate·unaccounted가 있으면 완료를 선언하지 않고 escalation한다. DB를 수동 수정하지 않는다. |

MySQL read-only query는 incident 환경의 승인된 client와 credential 처리 절차를 사용한다. 다음 집계는 일부 검증일 뿐 manifest join을 대체하지 않는다.

```sql
SELECT
    COUNT(*) AS rows_total,
    COUNT(DISTINCT original_barcode) AS original_barcode_unique,
    COUNT(DISTINCT scan_time) AS scan_time_unique
FROM barcodes;
```

### 13.3 Material Run Evidence 예시 — 운영 threshold 아님

```text
Generated unique logical identities: 820
Kafka transport records:           1,235
Retry-induced duplicate records:     415
MySQL unique persisted:               820
```

`1,235 = 820 + 415`는 해당 run의 설명이다. 모든 incident에서 같은 비율이나 값으로 수렴해야 한다는 기준이 아니다. 이 실행은 bounded scenario에서 duplicate containment를 관측한 것이며 exactly-once, production RTO 또는 production RPO를 입증하지 않는다.

## 14. Recovery Complete Gate

### 14.1 최종 판정

| 필드 | 내용 |
|---|---|
| **Entry Condition** | Component Recovery, Flow Recovery, Backlog Drain, End-to-end Reconciliation의 Evidence가 모두 준비됐다. |
| **Action** | 아래 완료 조건을 독립적으로 검토하고 각 항목의 Evidence 위치와 UTC 시각을 기록한다. 최소 두 번의 연속 수렴 sample과 승인 책임자의 판정을 남긴다. |
| **Expected Observation** | 네 Gate가 순서대로 충족되고 affected identity 전체가 terminal state로 설명되며 미해결 위험 행동이 없다. |
| **Decision / Stop Condition** | 모든 조건이 충족되면 `Recovery Complete`를 선언한다. 하나라도 미충족이면 가장 높은 검증 완료 상태만 선언한다. broker만 복구되면 `Component Recovered`, 흐름까지만 확인되면 `Flow Recovered`, backlog까지만 수렴하면 `Backlog Drained`이며 `Recovery Complete`가 아니다. |

완료 조건:

- [ ] pre/post Kafka container ID가 동일하다.
- [ ] broker와 기존 topic이 독립 probe에 응답한다.
- [ ] publish와 Processing consume가 재개됐다.
- [ ] Redis write, Worker read, MySQL persistence가 재개됐다.
- [ ] affected cohort의 Scanner retry remaining이 수렴했다.
- [ ] affected cohort의 Kafka consumer lag가 수렴했다.
- [ ] affected cohort의 Redis group lag와 PEL이 수렴했다.
- [ ] DLQ·DLT terminal identity가 검토되고 accounting에 포함됐다.
- [ ] `still-pending = 0`이다.
- [ ] `unaccounted = 0`이다.
- [ ] final duplicate row가 없다.
- [ ] expected manifest 밖 extra row가 없다.
- [ ] 모든 affected identity가 terminal state로 설명된다.
- [ ] transport duplicate가 있으면 수와 containment 경로가 설명된다.
- [ ] 최소 두 번의 연속 수렴 sample이 있다.
- [ ] 금지 행동이나 승인되지 않은 Material Action을 실행하지 않았다.

## 15. 중단 및 Escalation Matrix

| 조건 | 즉시 판정 | 금지되는 반응 | Escalation에 포함할 Evidence |
|---|---|---|---|
| First Broken Boundary 불명확 또는 Evidence 충돌 | 진단으로 반환 | 추정 restart | 상충 signal, freshness, timeline |
| Kafka container 부재·ID 변경·recreate 정황 | 적용 범위 밖 | `up`, recreate, 새 container 생성 | pre/post inventory, image·storage identity |
| storage loss·corruption 또는 topic·partition 불일치 | 적용 범위 밖 | topic 생성·삭제, offset reset | broker/topic metadata, storage Evidence |
| `start kafka` 실패 또는 반복 start 필요 | Recovery 실패 | 임의 flag 추가, 다른 service restart | 명령, exit code, UTC, container state |
| broker probe 지속 실패 | Component Recovery 미충족 | Ingest·Processing restart | broker log·metadata, exporter freshness |
| broker는 응답하지만 publish·consume 미재개 | Component만 복구 | offset reset, replay | producer/consumer log, group offsets·lag |
| Redis write·Worker read·MySQL persistence 중단 | Flow Recovery 미충족 | Redis·Worker·MySQL restart, 수동 `XACK` | boundary별 log·metric·read-only query |
| retry·lag·PEL이 증가·정체·진동 | Backlog Drain 미충족 | purge, PEL clear, offset reset | 연속 sample과 affected cohort |
| DLQ·DLT 증가 | terminal exception 존재 | 삭제 또는 임의 replay | identity, reason, source offset·record 참조 |
| queue full/drop 관측 | loss risk | count로 무시 | drop log, cohort, queue 추세 |
| manifest·accounting cut 부재 | 완료 관측 불가 | total count로 완료 추정 | 관측성 공백과 가능한 watermark |
| missing·extra·final duplicate·unaccounted 존재 | Reconciliation 실패 | DB 수동 수정 | set diff와 identity별 상태 |
| 권한·승인·Credential 처리 불충분 | 실행 중단 | 우회 실행 | 필요한 권한과 승인 범위 |

## 16. Evidence Capture Checklist

### 16.1 식별과 승인

- [ ] Incident ID
- [ ] 실행 환경과 Compose project
- [ ] UTC 시작·종료 시각
- [ ] Repository revision
- [ ] Runbook revision
- [ ] First Broken Boundary 진단 근거와 handoff 시각
- [ ] 실행자·검토자와 필요한 승인 참조

### 16.2 Recovery action

- [ ] pre-recovery Kafka container ID, status, image identity
- [ ] writable layer·storage 보존과 recreate 부재 근거
- [ ] 실행한 정확한 명령, UTC 시작·종료, exit code
- [ ] post-recovery container ID, status, image identity와 비교 결과
- [ ] 실행하지 않은 고위험 행동 목록

### 16.3 Component와 흐름

- [ ] broker·topic·partition probe와 sample freshness
- [ ] consumer group probe
- [ ] recovery 후 첫 publish success 시각
- [ ] recovery 후 첫 consume 시각
- [ ] recovery 후 첫 retry success 시각
- [ ] recovery 후 첫 Redis write·Worker read·MySQL persistence 시각

### 16.4 Backlog와 terminal state

- [ ] affected logical identity manifest 또는 accounting cut
- [ ] Scanner retry remaining과 queue full/drop 여부
- [ ] Kafka lag 연속 sample
- [ ] Redis group lag·PEL 연속 sample
- [ ] DLQ·DLT identity와 reason
- [ ] MySQL identity-level reconciliation
- [ ] missing, extra, final duplicate, still-pending, unaccounted
- [ ] transport duplicate 수와 containment 설명
- [ ] 최소 두 번의 연속 수렴 sample
- [ ] 중단·escalation 조건과 발생 UTC 시각

Credential, secret, 불필요한 machine identifier는 Evidence에 포함하지 않는다. Evidence 파일을 수정해 과거 결과를 맞추지 않는다.

## 17. Artifact 참조와 Claim 경계

### 17.1 운영·검증 Artifact

- [운영 진단 가이드](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)
- [Kafka 장애 학습 노트](./KAFKA-FAILURE-LEARNING-NOTE.md)
- [BIP-FR-001 재현 기록](./REPRODUCTION-RECORD.md)
- [Detect·impact·recovery summary](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt)
- [Backlog drain 연속 sample](./evidence/20260829T073503Z/22-backlog-drain-observation.txt)
- [Final event reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt)
- [Fault·recovery timeline](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt)

### 17.2 구현 근거

- [Scanner FailureRetryService](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/FailureRetryService.java): process-local bounded retry queue와 5초 주기 drain
- [Scanner ApiGatewayTransmitter](../../../../barcode-scanner-service/src/main/java/com/barcode/barcode_scanner_service/service/ApiGatewayTransmitter.java): batch partial failure의 single fallback
- [Ingest BarcodeIngestController](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/controller/BarcodeIngestController.java): 5초 confirmation wait, HTTP `207`·`503`, timeout 뒤 Future 미취소
- [Ingest BarcodeProducer](../../../../barcode-ingest-service/src/main/java/com/barcode/barcode_ingest_service/service/BarcodeProducer.java): Kafka send와 partition·offset callback
- [Processing BarcodeEventConsumer](../../../../barcode-processing-service/src/main/java/com/barcode/barcode_processing_service/service/BarcodeEventConsumer.java): Kafka consume와 Redis dedupe·publish
- [Redis dedupe script](../../../../barcode-processing-service/src/main/resources/scripts/dedupe-and-publish.lua): duplicate check와 `XADD`의 원자 실행
- [Worker RedisStreamConsumer](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/service/RedisStreamConsumer.java): consumer identity, PEL reclaim, MySQL persistence, DLQ 후 ACK
- [Application Compose](../../../../docker-compose.apps.yml): worker별 고정 consumer name 주입
- [BarcodeEntity](../../../../barcode-persistence-worker/src/main/java/com/barcode/barcode_persistence_worker/entity/BarcodeEntity.java): final persistence unique constraint

### 17.3 금지되는 Claim

이 Runbook 실행으로 다음을 주장하지 않는다.

- HTTP failure이므로 Kafka append 실패가 확정됐다.
- HTTP failure이므로 event loss가 확정됐다.
- broker가 응답하므로 Recovery Complete다.
- Kafka lag 0이므로 MySQL persistence까지 완료됐다.
- PEL 0이므로 business correctness가 증명됐다.
- MySQL total count가 같으므로 duplicate나 missing이 없다.
- Material Run으로 exactly-once가 증명됐다.
- Material Run으로 production RTO 또는 RPO가 증명됐다.
- 동일 container start가 container loss·storage loss·replicated Kafka 장애에도 유효하다.

## 18. 비규범적 후속 후보

다음은 현재 Runbook의 실행 승인이 아니며 별도 설계·승인이 필요한 후보이다.

- Scanner retry queue size·enqueue·drop·drain의 직접 metric 또는 status
- Ingest send-confirm success·uncertain outcome의 domain counter
- affected logical identity watermark와 online reconciliation
- exporter series freshness alert와 broker health 분리
- continuous traffic에서 cohort별 backlog convergence 관측
