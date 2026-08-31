# BIP-FR-001 Technical Report — Kafka Ingress Unavailable

| 항목 | 결과 |
|---|---|
| Validation Task | `BIP-FR-001 — Active Scan 중 Kafka ingress broker unavailable` |
| Material Run | `20260829T073503Z` |
| Workflow Outcome | `REPRODUCED` |
| Experiment Validity | `PASS` |
| Evidence Sufficiency | `PASS` |
| Verified Boundary | `bounded Kafka failure → observable impact → controlled recovery → backlog convergence → end-to-end reconciliation` |

## 1. Executive Technical Result

이 검증은 격리된 로컬 단일 broker Docker 환경에서 active synthetic scan traffic 중 Kafka ingress broker를 57초간 unavailable 상태로 만들고, 장애 영향과 복구 후 종단 간 수렴을 확인했다. 장애 구간에는 Ingest의 Kafka 전송 확인 실패, Scanner의 fallback·retry 활성화, Processing 이하 신규 진행 중단이 함께 관측되었다. 동일 Kafka container의 availability만 복원한 뒤 publish, consume, retry, Redis Stream 처리와 MySQL 저장이 다시 진행되었고, 모든 계층의 백로그와 logical identity가 terminal state로 수렴했다.

실행 결과는 다음 두 식으로 요약된다.

```text
Kafka records 1,235
= logical events 820
+ retry-induced transport duplicates 415

Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

첫 번째 식은 transport에서 동일 logical identity가 반복 전달되었음을 뜻한다. `415`는 final business duplicate row가 아니다. 두 번째 식은 생성한 logical identity 전체가 MySQL의 unique persisted set으로 수렴했고 실패·미완료·미설명 경로가 남지 않았음을 뜻한다.

따라서 이 실행이 지지하는 최대 결론은 다음과 같다.

> 격리된 local single-broker Docker 환경에서 설정값 5 requests/sec의 active synthetic scan traffic 중 Kafka를 57초간 unavailable 상태로 만들었을 때, ingress delivery confirmation failure와 Scanner fallback/retry가 관측되었다. State 조작 없이 동일 broker를 복구한 뒤 processing이 재개되었고, experiment logical event 820건 전체가 final duplicate 또는 unaccounted loss 없이 reconciliation되었다.

이 결론은 해당 bounded run의 장애 재현과 최종 수렴에 한정된다. Kafka HA, exactly-once, storage-loss durability 또는 production availability를 입증하지 않는다.

## 2. Validation Question and Scope

### 2.1 Validation Question

검증 질문은 다음과 같다.

> Active scan 중 단일 Kafka ingress broker가 bounded window 동안 unavailable해질 때, 시스템이 장애 영향을 관측 가능한 형태로 드러내고, 승인된 최소 복구 뒤 백로그를 소진하여 모든 logical event를 설명 가능한 terminal state로 수렴시키는가?

이 질문은 다음 네 하위 판정으로 분해했다.

1. Kafka unavailable이 단순 container 상태가 아니라 Ingest → Kafka 경계의 실패와 downstream progression 중단으로 관측되는가?
2. 장애 영향이 logical event, transport record, retry backlog, downstream state로 구분되어 계량되는가?
3. 동일 Kafka component의 availability 복원 뒤 신규 흐름과 기존 retry 흐름이 다시 진행되는가?
4. broker availability를 넘어 모든 backlog와 generated identity가 종단 간 조정(End-to-end Reconciliation)에 도달하는가?

### 2.2 Included Scope

- 실행 환경: 격리된 로컬 Docker Compose, 단일 Kafka broker
- 입력 경로: Scanner → Ingest → Kafka → Processing → Redis Streams → Persistence Worker → MySQL
- 입력: 서로 겹치지 않는 `scanTimeMs` identity range의 synthetic logical events
- 장애: 기존 Kafka container의 bounded `stop`
- 복구: 보존된 동일 Kafka container의 `start`
- 검증: component 상태, timestamped logs, Kafka offset·lag, Redis Stream·PEL, retry state, MySQL identity set, DLQ·DLT

### 2.3 Excluded Scope

새 fault mode, benchmark, capacity test, replicated Kafka, storage loss, container recreation, application restart, retry queue overflow, state repair와 production availability 평가는 포함하지 않았다.

## 3. System and Failure Boundary

### 3.1 System Boundary

```text
Synthetic Driver
  → Scanner memory buffer / retry queue
  → Ingest HTTP API / Kafka Producer
  → Kafka topic: barcode-events
  → Processing Consumer / Redis atomic dedupe + XADD
  → Redis Stream: barcode:stream
  → Persistence Workers / consumer-group ACK lifecycle
  → MySQL: barcodes
```

각 경계는 서로 다른 완료 의미를 가진다.

- Scanner HTTP `200`은 요청이 Scanner의 memory buffer에 수용되었음을 뜻한다. Kafka append 또는 final MySQL persistence 성공을 뜻하지 않는다.
- Ingest HTTP `207` 또는 `503`은 controller의 대기 시간 안에 Kafka delivery success를 확인하지 못했음을 뜻한다. 확정 event loss나 Kafka record 부재를 뜻하지 않는다.
- Kafka record count는 transport append 수다. Logical scan/event count와 동일하다고 가정할 수 없다.
- Redis group lag `0`, PEL `0` 또는 Kafka consumer lag `0`은 각각의 경계가 수렴했다는 신호이며, 단독으로 end-to-end completeness를 입증하지 않는다.
- MySQL row count만으로도 generated identity의 누락·extra·미완료 경로를 판정할 수 없다. Manifest와 terminal category의 집합 대조가 필요하다.

### 3.2 Injected Failure and First Broken Boundary

의도적으로 변경한 availability는 Kafka 하나뿐이었다. 기존 Kafka container를 stop했고, stop 완료부터 recovery command 시작까지의 unavailable duration은 57초였다. Fault window에 다음 causal chain이 확인되었다.

```text
Kafka unavailable
→ Ingest producer connection / delivery confirmation failure
→ batch HTTP 207 및 single HTTP 503 경로
→ Scanner single fallback / retry queue 활성화
→ Processing과 Worker의 affected-event 신규 진행 중단
```

Kafka container가 stopped였다는 사실만으로 장애 재현을 판정하지 않았다. Ingest producer, Scanner fallback/retry, Kafka exporter 응답 실패, Processing과 Worker progression을 같은 시간축에서 교차 확인하여 Ingest → Kafka broker availability를 최초로 끊어진 경계(First Broken Boundary)로 판정했다.

## 4. Validation Method and Experiment Validity

### 4.1 Method

| 단계 | 방법 | 판정 목적 |
|---|---|---|
| Clean start and readiness | Project-scoped clean state에서 core, monitoring, application을 staged startup하고 component readiness와 resource boundary를 확인 | 실험 전 환경 안정성과 오염 없는 시작 확인 |
| Healthy phase | 설정값 `5 requests/sec`로 logical events 300건 생성 | 정상 경로와 baseline terminal state 확인 |
| Fault window | Kafka만 stop한 상태에서 logical events 220건 생성 | Failure signature와 영향 범위 확인 |
| Controlled recovery | 동일 container ID의 Kafka만 start | 승인된 최소 복구로 component·flow 회복 확인 |
| Post-recovery phase | Broker probe 뒤 logical events 300건 생성 | 신규 traffic의 전체 경로 회복 확인 |
| Drain and reconciliation | 입력 종료 뒤 연속 terminal sample과 identity manifest 대조 | backlog convergence와 Recovery Complete 확인 |

새 topic 생성, offset reset, Redis/MySQL state 조작, manual repair, 다른 component restart 또는 추가 fault injection은 수행하지 않았다.

### 4.2 Experiment Validity

Experiment Validity는 다음 근거로 `PASS`였다.

- Frozen Material Run Specification SHA `5870dd3578061663be89d54cbde0f9a84375c708`를 사용했다.
- Kafka 하나만 의도적으로 unavailable하게 만들었다.
- Kafka outage는 승인 상한 60초 이내인 57초였다.
- 동일 Kafka container identity를 복구 전후 유지했다.
- Application source, canonical Compose, validation override, traffic driver, image identity와 resource limit은 실행 중 변경하지 않았다.
- Kafka 외 component restart, OOM, state/topic/offset 조작과 manual data repair가 없었다.
- Host safety boundary와 실행 timeline이 유지되었다.
- 독립적인 container state, logs, Kafka·Redis·MySQL query로 failure lifecycle과 terminal reconciliation을 확인했다.

### 4.3 Method Limitation

Driver argument는 모든 phase에서 `5 requests/sec`였지만, driver가 각 blocking HTTP 호출 뒤 `0.2초`를 sleep하는 방식이어서 실제 wall-clock rate는 명목값보다 낮았다. 예를 들어 healthy 300건은 약 71초, post-recovery 300건은 약 69초가 걸렸다. 따라서 이 실행은 정확한 5 requests/sec throughput이나 production 처리량을 입증하지 않는다. 이 제한은 Kafka-only fault causal chain과 identity-level terminal reconciliation 판정을 무효화하지 않는다.

## 5. Failure Lifecycle

| Lifecycle | Material Evidence | Interpretation | Result |
|---|---|---|---|
| Healthy baseline | Scanner HTTP `200` 300, Kafka offset 300, Redis Stream 300 / lag 0 / PEL 0, MySQL 300 unique | 장애 전 end-to-end 경로와 terminal state가 정상 수렴 | `PASS` |
| Kafka failure | `07:45:35.326Z` Kafka stop 완료, 57초 unavailable | 승인된 bounded component failure가 실제 발생 | `PASS` |
| Detect | `07:45:34.673Z` producer connection failure, `07:45:40.978Z` batch confirmation failure, `07:45:40.985Z` Scanner fallback | Ingest → Kafka 경계 이상이 application과 transport 신호로 드러남 | `PASS` |
| Impact | Outage logical events 220, batch failed indices 220, fault-window Processing receive 0, Worker read 0 | Affected events가 Scanner/Ingest 쪽 outstanding work로 남고 downstream 신규 진행이 중단 | `PASS` |
| Retry activation | `07:45:52.087Z` first retry enqueue, `07:45:55.250Z` first scheduled retry | 확인 불확실성 뒤 loss exposure를 줄이는 별도 send path 활성화 | `PASS` |
| Component recovery | `07:46:32Z` 동일 Kafka start, `07:46:50Z` broker probe 완료 | Broker availability 복원 | `PASS` |
| Flow recovery | `07:46:48.405Z` first publish, `07:46:48.823Z` first consume, `07:46:49.398Z` first retry success | 신규·retry flow가 다른 시점에 재개 | `PASS` |
| Backlog drain | `07:46:57.034Z` Scanner retry remaining 0; 두 terminal sample에서 Kafka lag, Redis lag, PEL 모두 0 | 계층별 outstanding work가 수렴 | `PASS` |
| Reconciliation | Generated 820과 MySQL unique 820 일치, missing·final duplicate·pending·unaccounted 0 | 모든 logical identity가 설명 가능한 terminal state에 도달 | `PASS` |

이 lifecycle은 `Component Recovery → Flow Recovery → Backlog Drain → End-to-end Reconciliation`의 각 단계를 분리한다. 앞 단계의 성공은 뒤 단계의 성공을 자동으로 보장하지 않는다.

## 6. Quantitative Results

### 6.1 Logical Input

| Phase | Logical events | Identity boundary |
|---|---:|---|
| Healthy | 300 | `scanTimeMs=1787989319000..1787989319299` |
| Kafka unavailable | 220 | `scanTimeMs=1787989534000..1787989534219` |
| Post-recovery | 300 | `scanTimeMs=1787989631000..1787989631299` |
| **Total** | **820** | 서로 겹치지 않는 세 range |

### 6.2 HTTP and Retry Observations

| Boundary | Observation | Meaning |
|---|---:|---|
| Scanner driver | HTTP `200` 820 / other 0 / transport error 0 | Scanner buffer acceptance 820; final persistence confirmation 아님 |
| Ingest batch | total 172 / HTTP `200` 141 / HTTP `207` 31 | `207` response의 failed index 합계는 outage events 220 |
| Ingest single | total 415 / HTTP `200` 220 / HTTP `503` 195 | 응답 시간 내 delivery success 확인 결과; 확정 loss count 아님 |
| Scanner explicit retry | enqueue 90 / maximum observed queue 89 / scheduled success 90 / failed attempts 3 / terminal remaining 0 | 관측 가능한 explicit retry queue가 복구 뒤 drain |

Ingest status 수는 access log의 직접 status 집계가 아니라 controller logs와 고정 response mapping을 결합한 파생 Evidence다. `not observed`인 값을 임의로 `0`으로 변환하지 않았다.

### 6.3 Transport, Processing and Persistence

| Layer | Result |
|---|---:|
| Kafka transport records | 1,235 |
| Processing received | 1,235 |
| Processing new | 820 |
| Processing duplicate | 415 |
| Processing error | 0 |
| Redis Stream length | 820 |
| Redis group lag / PEL | 0 / 0 |
| MySQL rows / unique persisted | 820 / 820 |
| Missing logical identities | 0 |
| Final duplicate rows | 0 |
| Expected manifest 밖 extra rows | 0 |
| DLQ | 0 |
| DLT | topic `none`; terminal count 0 |
| Pending retry terminal | 0 |
| Unaccounted | 0 |

### 6.4 Required Arithmetic Boundary

```text
1,235 transport records = 820 logical events + 415 retry-induced transport duplicates
```

`1,235`는 logical scan count가 아니며, `415`는 business duplicate row count가 아니다. 또한 `820` logical events가 transport에서 각각 한 번만 처리되었다는 뜻도 아니다. Processing은 1,235 records를 수신해 820건을 new, 415건을 duplicate로 분류했고, Redis Stream과 MySQL은 820 unique identities로 수렴했다.

Terminal accounting은 다음과 같다.

```text
Generated unique 820
= MySQL unique 820
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

## 7. Failure Mechanism and Operational Impact

### 7.1 Acknowledgment Uncertainty and Transport Amplification

Ingest controller는 Kafka producer Future의 완료를 최대 5초 기다린다. 이 시간 안에 완료를 확인하지 못하면 batch는 failed index와 HTTP `207`, single은 HTTP `503`을 반환할 수 있지만, timeout 뒤 Future를 취소하지 않는다. Scanner는 failed batch item을 single request로 다시 보내고, single failure를 process-local retry queue에 넣어 재시도한다.

따라서 다음 상태가 가능하다.

```text
원래 Kafka send는 응답 시점에 미확인이나 계속 진행
+ Scanner가 만든 별도 fallback / retry send
→ broker recovery 뒤 둘 이상의 send가 함께 성공
→ 동일 logical identity의 transport record 증가
```

Material Run에서는 이 증폭이 Kafka records 1,235와 Processing duplicate 415로 나타났다. Scanner logs에는 HTTP client 자동 재실행도 관측되었지만, 415건 각각을 explicit fallback, scheduled retry, HTTP client 재실행으로 완전히 분해한 Evidence는 없다. 그러므로 `retry-induced`는 별도 application send attempt가 만든 transport 증폭 전체를 가리키며 각 하위 메커니즘의 개별 기여도를 확정하지 않는다.

### 7.2 Duplicate Containment

Processing의 Redis Lua script는 original barcode 기준 duplicate marker 확인과 unique event의 `XADD`를 Redis-side에서 원자적으로 수행한다. 그 결과 1,235 Processing invocations 중 820건만 Redis Stream entry를 만들고 415건은 duplicate로 분류되었다. Worker와 MySQL unique constraint는 persistence 경계에서 추가 반복 처리 가능성을 방어한다.

이 결과는 “중복이 발생하지 않았다”가 아니라 “transport duplicate가 발생했고 이 bounded run에서 downstream idempotency boundary가 final duplicate row 없이 수렴시켰다”는 뜻이다. Redis atomicity와 MySQL uniqueness는 Kafka, Redis, MySQL을 하나의 분산 transaction으로 만들지 않는다.

### 7.3 Operational Impact

- Scanner는 fault window의 220 logical events를 모두 HTTP `200`으로 수용했지만, 이 응답은 memory buffer acceptance에 한정되었다.
- Ingest는 Kafka delivery를 제때 확인하지 못해 batch partial failure와 single failure를 반환했다.
- Scanner fallback과 retry queue에 outstanding work가 형성되었다.
- Fault window에 Processing receive와 두 Worker의 Redis read가 모두 0이어서 affected-event downstream progression이 중단되었다.
- Kafka exporter process는 생존했지만 outage 중 여섯 sample의 metrics HTTP가 모두 `000`이었다. Process `running`만으로 dependency observability가 정상이라고 볼 수 없었다.
- 복구 뒤 원래 background send와 별도 retry path가 함께 진행되어 transport duplicates가 발생했지만, terminal missing·duplicate·unaccounted는 남지 않았다.

## 8. Recovery and Recovery-Complete Verification

Kafka broker availability 복원 자체는 Recovery Complete가 아니다. 이 실행은 다음 네 계층을 결과 Evidence로 검증했다.

| Recovery level | Required evidence | Material result |
|---|---|---|
| Component Recovery | 동일 container identity, broker/topic probe 응답 | 동일 Kafka container를 start했고 `07:46:50Z` broker probe 완료 — `PASS` |
| Flow Recovery | Kafka publish, Processing consume, retry와 downstream progression 재개 | first publish `07:46:48.405Z`, consume `07:46:48.823Z`, retry success `07:46:49.398Z` — `PASS` |
| Backlog Drain | Scanner retry, Kafka lag, Redis group lag·PEL이 연속 sample에서 수렴 | `07:49:18Z`, `07:49:34Z` 두 sample 모두 retry 0, Kafka lag 0, Redis lag 0, PEL 0 — `PASS` |
| End-to-end Reconciliation | Generated identity set과 MySQL·DLQ·DLT·pending·unaccounted의 집합 대조 | 820 = 820 + 0 + 0 + 0 + 0; missing·final duplicate·extra 0 — `PASS` |

두 terminal sample은 다음 상태를 반복 확인했다.

| UTC | MySQL | Kafka records / lag | Redis stream / lag / PEL | Retry remaining | DLQ / DLT |
|---|---:|---|---|---:|---|
| `07:49:18Z` | 820 | `1,235 / 0` | `820 / 0 / 0` | 0 | `0 / none` |
| `07:49:34Z` | 820 | `1,235 / 0` | `820 / 0 / 0` | 0 | `0 / none` |

이후 manifest reconciliation은 healthy 300/300, outage 220/220, post-recovery 300/300을 각각 확인했다. 따라서 Recovery Complete에 필요한 기술 criteria는 해당 bounded run에서 모두 `PASS`였다.

## 9. Engineering Conclusions

### 9.1 Verified Conclusions

1. 승인된 단일 Kafka unavailable fault는 Ingest delivery confirmation failure, Scanner fallback/retry, affected-event downstream interruption으로 재현되었다.
2. HTTP status의 의미와 final delivery state는 분리해야 한다. Scanner `200`은 buffer acceptance이고 Ingest `207/503`은 time-bounded confirmation failure다.
3. 확인 불확실성 상태에서 미취소 background send와 별도 fallback/retry send가 함께 성공하여 transport record가 logical event보다 많아질 수 있다.
4. 이 run의 `415` records는 retry-induced transport duplicates로 설명되며 Processing의 Redis dedupe가 모두 duplicate로 분류했다.
5. 동일 Kafka component의 availability 복원만으로 flow가 재개되었으며 다른 component restart나 state repair는 필요하지 않았다.
6. Broker responsiveness, flow recovery, backlog drain, identity reconciliation을 각각 확인한 뒤에만 Recovery Complete criteria가 충족되었다.
7. Generated 820 logical identities는 MySQL 820 unique identities로 수렴했고 missing, final duplicate, DLQ, DLT, pending, unaccounted는 모두 0이었다.

### 9.2 Claim–Evidence Trace

| Claim | Class | Evidence | Interpretation and boundary |
|---|---|---|---|
| Kafka가 57초 unavailable했고 FS-1~FS-4가 성립했다 | `MR` | [Fault·recovery timeline](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt), [Detect·impact·recovery summary](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt) | Container stop뿐 아니라 producer, Scanner, downstream progression을 교차 확인한 bounded failure result |
| Scanner `200`은 buffer acceptance이고 Ingest `207/503`은 5초 내 delivery 미확인이다 | `REPO` + `MR` | [Operational Diagnostic Guide](./OPERATIONAL-DIAGNOSTIC-GUIDE.md), [Reproduction Record](./REPRODUCTION-RECORD.md) | HTTP response를 final MySQL success 또는 확정 loss로 해석하지 않음 |
| `1,235 = 820 + 415`는 transport amplification이다 | `MR` + `INT` | [Final event reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt), [Kafka Failure Learning Note](./KAFKA-FAILURE-LEARNING-NOTE.md) | `415`를 business duplicate나 Kafka의 원인 없는 복제로 일반화하지 않음 |
| Processing과 Redis가 415 transport duplicates를 final stream에서 contain했다 | `MR` + `REPO` | [Final event reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt), [Kafka Failure Learning Note](./KAFKA-FAILURE-LEARNING-NOTE.md) | Bounded run의 수렴 결과이며 end-to-end exactly-once 보장이 아님 |
| Component·Flow·Backlog·Reconciliation이 모두 통과했다 | `MR` + `INT` | [Backlog drain observation](./evidence/20260829T073503Z/22-backlog-drain-observation.txt), [Runbook](./RUNBOOK.md) | Broker start나 lag 0 하나가 아니라 네 계층 Evidence를 결합한 technical assessment |
| Generated 820이 MySQL 820으로 terminal reconciliation되었다 | `MR` | [Final event reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt) | DLQ·DLT·pending·unaccounted·missing·final duplicate를 함께 확인한 identity-level result |
| 실행 validity와 resource safety boundary가 유지되었다 | `MR` | [Final runtime safety and validity](./evidence/20260829T073503Z/31-final-runtime-safety-and-validity.txt), [Reproduction Record](./REPRODUCTION-RECORD.md) | Performance capacity 또는 production sizing 결론이 아님 |

## 10. Limitations and Non-claims

### 10.1 Evidence and Method Limitations

- 실제 wall-clock traffic rate는 driver의 blocking-call 후 sleep 방식 때문에 명목 `5 requests/sec`보다 낮았다.
- Ingest HTTP status count는 access log 직접 집계가 아니라 application logs와 response mapping을 결합한 파생치다.
- Scanner retry queue는 전용 metric·endpoint가 없어 existing logs로 계량했다.
- 추가 single POST의 일부에 HTTP client 자동 재실행이 관측되었지만, 415 duplicate records의 하위 retry mechanism별 기여도는 완전히 분해되지 않았다.
- `not observed`는 `0`이 아니다. 본 보고서는 Source Artifact가 `0` 또는 `none`으로 terminal 확인한 항목과 관측되지 않은 항목을 구분한다.
- 결과는 한 개의 local Material Run `20260829T073503Z`에 직접 적용된다.

### 10.2 Explicit Non-claims

이 Technical Report는 다음을 주장하지 않는다.

- Kafka HA 또는 replicated Kafka availability를 입증했다.
- Kafka storage loss나 container recreation 상황의 durability를 입증했다.
- Kafka → Redis → MySQL의 exactly-once guarantee를 입증했다.
- Transport에서 각 logical event가 정확히 한 번만 처리되었다.
- Scanner HTTP `200`이 final persistence success를 뜻한다.
- Ingest HTTP `207` 또는 `503`이 확정 event loss를 뜻한다.
- Production availability, production RTO 또는 production RPO를 입증했다.
- Retry queue overflow, Scanner restart, 임의 replay 또는 다른 Kafka failure mode에서도 같은 결과를 보장한다.
- Enterprise-grade Kafka availability가 구현되었다.
- `820`, `1,235`, `415`가 운영 threshold, capacity 또는 production guarantee다.
- Kafka broker availability, Kafka lag 0, Redis PEL 0, DLQ/DLT 0 또는 MySQL row count 하나만으로 Recovery Complete를 입증할 수 있다.

## 11. Evidence and Artifact Traceability

### 11.1 Evidence Classification

| Class | Meaning | Use in this report |
|---|---|---|
| `MR` | Material Run에서 직접 수집하거나 실행 자료에서 산출한 Evidence | `20260829T073503Z`에 한정된 실행 사실과 수치 |
| `REPO` | 저장소 코드·설정·Artifact에서 확인한 구현 사실 | HTTP, retry, dedupe, persistence mechanism 설명 |
| `SEM` | Kafka·Redis 등 공식 기술 의미론 | 특정 BIP 사건의 발생 증거가 아니라 mechanism의 일반 경계 설명 |
| `INT` | MR, REPO, SEM을 연결한 해석 | 직접 관측과 구분하여 claim boundary와 함께 사용 |
| `Non-claim` | 현재 Evidence가 입증하지 않는 범위 | 과도한 일반화와 guarantee 확대 방지 |

Evidence와 Interpretation은 동일한 사실로 취급하지 않았다. Material conclusion은 위 Claim–Evidence Trace에서 분류와 locator를 함께 제시한다.

### 11.2 Primary Artifact Responsibility

| Artifact | Responsibility in this report |
|---|---|
| [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md) | 실행 절차, timeline, validity, Evidence sufficiency, verified claim boundary의 정본 |
| [OPERATIONAL-DIAGNOSTIC-GUIDE.md](./OPERATIONAL-DIAGNOSTIC-GUIDE.md) | First Broken Boundary와 cross-layer diagnostic interpretation |
| [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md) | logical event/transport record, acknowledgment uncertainty, retry, dedupe, PEL 의미론 |
| [RUNBOOK.md](./RUNBOOK.md) | `Component Recovery → Flow Recovery → Backlog Drain → End-to-end Reconciliation` completion model |
| [AI-HUMAN-RESOLUTION-MAPPING.md](./AI-HUMAN-RESOLUTION-MAPPING.md) | Evidence, interpretation, technical assessment, operational accountability의 책임 경계 |

### 11.3 Material Evidence Locators

- [Healthy baseline verification](./evidence/20260829T073503Z/17-healthy-baseline-verification.txt)
- [Fault and recovery timeline](./evidence/20260829T073503Z/18-fault-recovery-timeline.txt)
- [Backlog drain observation](./evidence/20260829T073503Z/22-backlog-drain-observation.txt)
- [Detect, impact and recovery summary](./evidence/20260829T073503Z/29-detect-impact-recovery-summary.txt)
- [Final event reconciliation](./evidence/20260829T073503Z/30-final-event-reconciliation.txt)
- [Final runtime safety and validity](./evidence/20260829T073503Z/31-final-runtime-safety-and-validity.txt)

이 보고서는 위 Artifact와 Evidence를 reviewer 관점에서 synthesis한다. 원 실행 명령, 전체 raw logs, diagnostic tree, Kafka 일반 이론, operator procedure와 AI/Human 역할 matrix는 각 Source Artifact의 책임으로 남긴다.
