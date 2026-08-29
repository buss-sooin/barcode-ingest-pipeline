# BIP-FR-001 — Kafka 유입 불가 Operating Validation 재현 기록

## 실행 이력 요약

| 시도 | Run ID | 범위 | 결과 |
|---|---|---|---|
| 이전 시도 | `20260829T053958Z` | Resource Preflight | `FAIL` — `kafka-exporter` 조기 종료 및 Grafana memory safety margin 부족으로 Material Run 미시작 |
| 현재 시도 | `20260829T064402Z` | Execution Environment Readiness 개선 및 검증 | `PASS` — staged startup과 승인된 Grafana `256 MiB` limit로 clean preflight 통과, Material Run 미시작 |

두 시도는 서로 다른 실행 이력이다. 현재 시도의 성공은 이전 실패 기록을 대체하지 않으며, Kafka Material Failure Run을 수행하거나 그 결과를 평가한 것으로 해석하지 않는다.

## 이전 시도 실행 식별 (`20260829T053958Z`)

| 항목 | 값 |
|---|---|
| Task ID | `BIP-FR-001` |
| Contract ID / Revision | `BIP-FR-001 / R1` |
| Run ID | `20260829T053958Z` |
| Human Gate boundary | Resource Preflight 통과 후 Kafka service의 reversible `stop/start`만 승인 |
| Git branch | `validation/bip-fr-001-kafka-unavailable` |
| Base commit SHA | `b39b04907f72c484c9213289933a6a4be178acc4` |
| Evidence locator | `evidence/20260829T053958Z/` |
| 현재 상태 | `MATERIAL RUN NOT STARTED` — Resource Preflight 실패 |

## 목적

활성 synthetic barcode scan traffic 중 단일 Kafka broker가 최대 60초 동안 unavailable 상태가 될 때 `Detect → Impact Assessment → Recovery → Verification` lifecycle을 검증한다. 이 작업은 Performance Benchmark가 아니며, 수집된 evidence가 직접 지지하는 범위만 판정한다.

## 실행 환경

- Host: Apple Silicon 기반 macOS, `arm64`, 8 logical CPU, 16 GiB physical memory
- Docker Engine: 8 CPU, 약 5.79 GiB memory allocation
- Canonical Compose set: `docker-compose.yml`, `docker-compose.apps.yml`, `monitoring-compose.yml`
- Task-local override: `docker-compose.validation.yml`
- 입력 경로: Host driver → `scanner` → `ingest` → Kafka → `processing` → Redis Streams → `worker` → MySQL

Machine identifier, credential 및 secret은 기록하지 않는다.

## Resource Safety Envelope

Task-local override는 Runtime limit만 추가하며 business behavior, topology, durability 또는 monitoring behavior를 변경하지 않는다.

- Aggregate memory upper bound: `5056 MiB` (`4.9375 GiB`)
- Aggregate CPU quota: `3.95 CPU`
- 성격: 이번 Run의 Host Safety Ceiling이며 Capacity sizing 결과가 아님
- Runtime 반영 조건: 모든 Container의 `Memory` 및 `NanoCpus`가 non-zero이고 Rendered Compose와 일치해야 함

## Preconditions

- `main`과 `origin/main`이 동일한 verified commit을 가리킴
- clean working tree에서 Validation branch 생성
- Disk free space가 20 GiB 이상
- Required port collision과 unrelated Docker workload가 없음
- Project-scoped clean start 완료
- Complete stack의 60초 healthy baseline이 Resource Preflight를 통과함

## Failure Scenario

1. 5 requests/sec deterministic synthetic traffic로 healthy baseline 관측
2. 동일 traffic를 유지하면서 Kafka service만 `stop`
3. Outage를 최대 60초 유지
4. 동일 Kafka service를 `start`
5. 60초 post-recovery 관측 및 bounded backlog drain 확인
6. 전체 generated event set reconciliation

## Failure Signature

다음 causal chain을 evidence로 평가한다.

`Kafka unavailable → ingest publish confirmation failure/timeout → HTTP 503 또는 batch partial failure → scanner retry path activation → downstream progression interruption`

Kafka Container의 stopped 상태만으로 Failure Reproduction을 판정하지 않는다.

## Verification Criteria

정상 valid-input run의 목표 terminal condition은 다음과 같다.

- `pending retry = 0`
- `DLQ = 0`
- `DLT = 0`
- `unaccounted events = 0`
- `duplicate final rows = 0`

## Authorized Actions

- Project-scoped Compose `down -v --remove-orphans`, `up`, `stop kafka`, `start kafka`
- 5 requests/sec synthetic traffic, 최대 10 requests/sec
- Kafka outage 최대 60초
- Read-only Runtime/Host/Database/Queue evidence collection
- Task-local artifact와 evidence 작성

## Prohibited Actions

- `main` 수정, merge, push, force operation
- Application/Infrastructure canonical Compose 또는 source/config 변경
- Kafka container/data/topic/offset/retention/replication 변경 또는 삭제
- Scanner, Processing, Worker, Redis, MySQL의 의도적 restart/stop
- Network partition 또는 추가 fault injection
- Docker Desktop global setting 변경
- Global prune 또는 unrelated Docker resource 변경
- Retry queue saturation

## Evidence 계획

- Environment 및 image identity
- Rendered Compose와 effective runtime limits
- Timeline timestamp
- `docker stats`, restart/OOM/health evidence
- Scanner/Ingest/Processing/Worker/Kafka log
- Kafka lag, Redis Stream/PEL, DLQ/DLT
- MySQL generated-set reconciliation
- Evidence manifest 및 SHA-256 checksum

## Outcome

`MATERIAL RUN NOT STARTED`

Complete stack 기동 직후 `kafka-exporter`가 `kafka:29092`에 접속했으나 `connection refused`로 `ExitCode=255` 종료됐다. R1의 `required service is unhealthy before injection` Stop Condition에 해당하므로 healthy baseline traffic과 Kafka Failure Injection을 시작하지 않았다.

Pre-teardown snapshot에서 Grafana가 `186.5 MiB / 192 MiB (97.14%)`를 사용해 설정한 Task-local memory boundary에 근접했다. R1은 limit 증가를 새 Human Gate 대상으로 규정하므로 limit를 변경하거나 재실행하지 않았다.

## 실행 결과 요약

| 평가 항목 | 결과 | 근거 |
|---|---|---|
| Experiment Validity | 평가하지 않음 | Material Run 미시작 |
| Evidence Sufficiency | Preflight 실패 판정에는 충분, Kafka outage lifecycle 판정에는 불충분 | Exporter log, Container inspect, resource snapshot |
| Failure Signature | 평가하지 않음 | Kafka를 의도적으로 중단하지 않음 |
| Recovery | 평가하지 않음 | Failure Injection 미수행 |
| Final Data Verification | Material Run 입력 `0`, terminal data `0` | MySQL/Kafka/Redis snapshot |
| Final Outcome | `MATERIAL RUN NOT STARTED` | Resource Preflight Stop Condition |

## Resource Safety Preflight

### 정적 조건

- Disk free: `49 GiB` — 20 GiB minimum 통과
- Required port collision: 없음
- 기존 Container 및 Compose-owned Network/Volume: 없음
- Host physical memory: `16 GiB`, logical CPU: `8`
- Docker Engine allocation: `6,212,071,424 bytes`, CPU: `8`
- Task-local Runtime upper bound: `5056 MiB / 3.95 CPU`
- 모든 14개 Container의 effective `Memory`와 `NanoCpus`: non-zero 및 Rendered Compose와 일치

### 기동 후 판정

- `kafka-exporter`: `ExitCode=255`, `OOMKilled=false`, `RestartCount=0`
- 직접 원인 signature: Kafka client initialization 중 `kafka:29092` 연결이 `connection refused`
- Kafka broker 자체는 이후 topic 조회에 응답했고 `barcode-events`와 `__consumer_offsets`가 확인됨
- Kafka exporter 외 Application, Kafka, MySQL, Redis, Prometheus, Grafana 및 나머지 exporter endpoint는 확인 시점에 응답
- 모든 Container의 `OOMKilled=false`, `RestartCount=0`
- Grafana: `186.5 MiB / 192 MiB (97.14%)` — 현재 Task-local limit에서 baseline 안정성을 보장할 수 없는 경계 상태
- macOS memory free: Preflight capture `57%`, Stack 관측 중 `37~41%`
- Swap: Initial `472.25 MiB`, post-build `687.12 MiB`, Stack 관측 중 `716.31 MiB`, teardown 후 `708.31 MiB`

따라서 Resource Preflight는 `FAIL`이다. 60초 healthy baseline과 Kafka outage는 수행하지 않았다.

## Timeline

| UTC | Event |
|---|---|
| `2026-08-29T05:39:58Z` | Run ID 및 branch/base 식별 |
| `2026-08-29T06:07:10Z` | Host/Docker preflight capture |
| `2026-08-29T06:07:36Z` | Project-scoped Clean Start |
| `2026-08-29T06:10:05Z` | Image identity 및 post-build host snapshot |
| `2026-08-29T06:10:28Z` | Bounded stack start |
| `2026-08-29T06:10:29.083Z` | `kafka-exporter` process start |
| `2026-08-29T06:10:29.896Z` | Kafka connection refused, exporter fatal exit |
| `2026-08-29T06:10:52Z` | Runtime limit/startup snapshot에서 exporter exit 검출 |
| `2026-08-29T06:11:42Z` | Failure log 및 service availability evidence 수집 |
| `2026-08-29T06:13:19Z` | Pre-teardown terminal/data snapshot |
| `2026-08-29T06:13:39Z` | Project-scoped Clean End 시작 |
| `2026-08-29T06:14:02Z` | Container/Network/Volume 제거 및 Docker health 확인 |

## Detect Evidence

- `kafka-exporter` log가 broker 연결 실패와 fatal 종료를 직접 기록한다.
- Container inspect가 `Status=exited`, `ExitCode=255`, `OOMKilled=false`를 확인한다.
- Port `9308`은 HTTP `000`, 나머지 확인 대상 endpoint는 HTTP `200`이었다.

이는 승인된 Kafka Failure Signature가 아니라 Execution Environment Preflight failure이다.

## Impact Assessment

- Synthetic scan request generated: `0`
- Scanner retry activation: `0`
- MySQL `barcodes`: `0`
- Kafka `barcode-events` partition end offsets: 모두 `0`
- Redis `barcode:stream`: `0`
- Redis PEL: `0`
- Redis DLQ: `0`
- Kafka DLT: 생성되지 않음
- Unaccounted event: 해당 없음 — Material input 없음

## Recovery 및 Final Verification

Kafka를 의도적으로 중단하지 않았으므로 Recovery와 Failure Scenario Final Verification은 평가하지 않았다. Preflight stack의 Kafka는 정상 응답 상태였으며 수동 data/offset 조작은 수행하지 않았다.

## Clean End

Evidence 수집 후 동일 Compose file set으로 `down -v --remove-orphans`를 수행했다.

- Project Container: `0`
- Project Network: `0`
- Project Volume: `0`
- Docker daemon: 정상 응답
- Global prune: 미수행
- Pulled/built Image와 Build Cache: R1 허용대로 유지
- 임시 Git-ignored `.env`: 삭제

## Candidate Improvements

다음 항목은 발견 사항일 뿐 이 Task에서 구현하지 않는다.

1. **Project Scope — Kafka exporter startup readiness**: 관측된 사실은 Stack 기동 직후의 `connection refused`와 일회성 fatal exit이다. Startup readiness race는 현재의 가장 좁은 working hypothesis이며 Root Cause로 확정하지 않는다. 별도 Remediation approval 후 health/retry/restart 전략을 검토해야 한다.
2. **Task/Environment Scope — Resource envelope fit**: Grafana `192 MiB` limit는 초기 기동에서도 97%에 도달했다. Limit 증가는 새 Human Gate가 필요하며 Docker Engine의 약 5.79 GiB allocation 안에서 전체 envelope를 다시 검토해야 한다.
3. **Project Scope — Reproducible monitoring images**: 일부 exporter image가 explicit version 없이 `latest`로 해석됐다. 이번 Run의 digest는 evidence에 고정했지만 canonical Compose의 재현성 gap으로 분류한다.
4. **Project Scope — Compose schema hygiene**: 세 Canonical Compose file의 top-level `version`이 설치된 Compose에서 obsolete warning을 발생시킨다.

## Limitations

- Local single-broker Docker 환경만 검증한다.
- Production HA, replicated Kafka durability, container/storage loss를 검증하지 않는다.
- Scanner restart durability와 retry queue overflow safety를 검증하지 않는다.

## Unresolved Gaps

- Resource Preflight를 통과하지 못해 `Detect → Impact Assessment → Recovery → Verification` lifecycle이 아직 검증되지 않았다.
- Scanner retry queue behavior, backlog drain, final duplicate/loss reconciliation은 실행 evidence가 없다.
- Kafka exporter readiness 및 Task-local Grafana memory fit에 대한 Human Resolution이 필요하다.

## 현재 시도 — Execution Environment Readiness (`20260829T064402Z`)

### Session Routing 및 실행 식별

| 항목 | 값 |
|---|---|
| Task ID | `BIP-FR-001` |
| Run ID | `20260829T064402Z` |
| 실행 범위 | 안정적인 Task-local test runtime을 위한 clean Resource / Runtime Readiness Preflight |
| Git branch | `validation/bip-fr-001-kafka-unavailable` |
| HEAD / `origin/main` | `b39b04907f72c484c9213289933a6a4be178acc4` / `b39b04907f72c484c9213289933a6a4be178acc4` |
| Evidence locator | `evidence/20260829T064402Z/` |
| 최종 판정 | `PASS` |
| Kafka Material Failure Run | `NOT STARTED` |

이번 시도에서는 synthetic failure traffic, Kafka `stop/start`, failure signature 평가, recovery 평가 및 final reconciliation을 수행하지 않았다. 이전 evidence manifest는 변경 전 검증에서 모두 `OK`였고 이전 evidence directory의 파일은 수정하지 않았다.

### 변경 파일 및 승인 경계

- `docker-compose.validation.yml`: Grafana Task-local hard memory limit만 `192 MiB → 256 MiB`로 변경했다.
- `REPRODUCTION-RECORD.md`: 이전 실패 이력을 유지하고 현재 readiness 이력을 추가했다.
- `evidence/20260829T064402Z/`: 현재 시도의 새 evidence만 추가했다.
- Application source와 세 canonical Compose file은 수정하지 않았다.
- Docker Desktop global configuration, Kafka configuration/topology, exporter image, restart policy 및 다른 service limit은 변경하지 않았다.
- 임시 local `.env`는 실행 종료 후 삭제했으며 credential은 evidence에 기록하지 않았다.

### Effective Resource Envelope

Rendered Compose와 Docker inspect가 14개 container 모두에서 non-zero memory/CPU limit 및 일치를 확인했다.

- Aggregate hard memory ceiling: `5,368,709,120 bytes = 5,120 MiB = 5.0 GiB`
- Aggregate CPU quota: `3.95 CPU`
- Docker Engine: `6,212,071,424 bytes` memory, `8 CPU`
- Grafana effective limit: `268,435,456 bytes = 256 MiB`, `NanoCpus=150,000,000`
- 성격: 이 수치는 이번 Task-local Host Safety Ceiling이며 production sizing 결론이 아니다.

### 재사용 Image Identity

Unconditional pull은 수행하지 않았고 모든 startup에 `--pull never`를 사용했다. 로컬 image ID와 digest는 이전 시도에 기록된 값과 일치했다.

| Repository / Tag | Image ID | Repository Digest |
|---|---|---|
| `confluentinc/cp-kafka:8.1.0-1-ubi9` | `sha256:7cd4ffecaaf138cdb88030b3656a37a4e8651cdc8141c70062c869b13e8ff249` | `sha256:9026dbbf280d41868b95ae3995e1fdf0f5db5964776fb9581b52a02e3776d727` |
| `mysql:8` | `sha256:5e7e005a680e75d935984d3d9390990d2a709b3ed67e92708e9e6747f1f754c9` | `sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb` |
| `redis:alpine` | `sha256:59c08762bdbcf53fa132aa0bae464a57a1309dc3fff8a034bb3e16d7a0b30ec5` | `sha256:becdda6c7f4b3fb42e42fd7f120bbf5c54c4caaaf16f26da24e4563d2c1f0576` |
| `prom/prometheus:v2.47.1` | `sha256:d2525ab881e3315844f06cf90d72184d8ee4dae274463d2aa794a7f50e3fdb71` | `sha256:089b3beab1304d83280c589a81f6f72ca42006910ff903ea3cf25f97fddc49ea` |
| `grafana/grafana:10.1.5` | `sha256:0a3c9111b0d74ceab6954202a004ca530961f8d3fb8fb9a068440fc868797ce9` | `sha256:0679e877ba204cede473782d5aba962831a3449092da120aba7d24082efe3fde` |
| `prom/mysqld-exporter:latest` | `sha256:9dda0b138756235ad8c488ec215892de0b68e5b4f017047f3a14b81be14f4606` | `sha256:abed8dac117b4ae5b70757f988e44795935b9a72c3b58d720c67ba688f8cb79e` |
| `danielqsj/kafka-exporter:latest` | `sha256:26fe916957b4a83e5b4ad8f13f6e1d9c96c18422d8c36de5ec1414d2d9f6d7d3` | `sha256:a51b280b55a763deaa1bc5024310bc2954995d9160014d7445055dac6a090868` |
| `oliver006/redis_exporter:latest` | `sha256:0892de2d75ea1c5df257f5f63dc2291dd1650dbf250358946bdf336ee00321bb` | `sha256:a129504e65b87c54f79bc92f1afc403475e8ff646a3d7512de469904ceddf986` |
| `barcode-ingest-pipeline-ingest:latest` | `sha256:72c559bb87e27466cf8803e8633d75f98f3606129f334ead603e5302414be7fc` | local build — digest 없음 |
| `barcode-ingest-pipeline-processing:latest` | `sha256:9e9098f75b73825d2e30d7db3c09c7b2733655b21109a104b34d0c733ce1c7a6` | local build — digest 없음 |
| `barcode-ingest-pipeline-scanner:latest` | `sha256:7457ce9df6e35cc12981cb06e948737a52525cbc6223be33b86a8fdac5d4d218` | local build — digest 없음 |
| `barcode-ingest-pipeline-worker-1:latest` | `sha256:de543d632da818fd7c0a86dbcb6bd4857fbbf1b12f6f20b22d17936024df4433` | local build — digest 없음 |
| `barcode-ingest-pipeline-worker-2:latest` | `sha256:37ffc1d11f40c8f48b33da9855d6d7a476661ab78850115385ed8a4b79134490` | local build — digest 없음 |

### Clean Start

실행 전 Docker resource ownership inventory에서 container와 volume은 없었고 기본 `bridge`, `host`, `none` network만 존재했다. Required port listener도 없었다. 정확히 동일한 네 Compose file set으로 project-scoped `down -v --remove-orphans`를 수행한 뒤 다음을 확인했다.

- Project container: `0`
- Project network: `0`
- Project volume: `0`
- Docker daemon: responsive

### Staged Startup 명령

모든 명령은 다음 file set을 같은 순서로 사용했다.

```text
-f docker-compose.yml
-f docker-compose.apps.yml
-f monitoring-compose.yml
-f docs/operational-validation/failure-reproduction/BIP-FR-001-kafka-ingress-unavailable/docker-compose.validation.yml
```

Stage 1:

```bash
docker compose <위의 네 file option> up -d --no-build --pull never kafka mysql redis
```

Stage 2:

```bash
docker compose <위의 네 file option> up -d --no-build --pull never mysqld-exporter mysqld-exporter-central kafka-exporter redis-exporter prometheus grafana
```

Stage 3:

```bash
docker compose <위의 네 file option> up -d --no-build --pull never ingest processing scanner worker-1 worker-2
```

### Readiness Evidence

- Kafka: `2026-08-29T06:46:44Z`에 container 내부 `kafka-topics --bootstrap-server kafka:29092 --list`가 `ExitCode=0`으로 실제 broker responsiveness를 확인했다. 120초 maximum wait를 초과하지 않았다.
- MySQL: `mysqladmin ping` 성공.
- Redis: `PONG` 응답.
- Kafka exporter: Kafka readiness 확인 후 `2026-08-29T06:47:00Z`에 시작했고 `2026-08-29T06:47:25Z`에 port `9308` metrics가 `kafka_brokers 1`을 반환했다. Terminal snapshot까지 `running`, `ExitCode=0`, `OOMKilled=false`, `RestartCount=0`이었다.
- Prometheus: `/-/ready` HTTP `200`.
- Grafana: `/api/health` HTTP `200`; effective hard limit `256 MiB` 확인.
- MySQL exporter 2개 및 Redis exporter: metrics endpoint HTTP `200`.
- Application 5개: scanner, ingest, processing, worker-1, worker-2의 Actuator health가 모두 HTTP `200`.

현재 evidence는 staged startup이 이번 환경의 startup instability를 해소했음을 보여주지만, 이전 exporter 종료의 Root Cause를 확정하지 않는다. Startup-readiness race는 여전히 working hypothesis이다.

### Healthy Baseline Resource Evidence

No-fault baseline은 `2026-08-29T06:50:07Z`에 시작했다. 확인 작업 자체의 수행 시간이 sampling interval에 추가되어 최소 요구 60초를 넘긴 `134초` 동안 관측했으며, 이는 Kafka outage 또는 material traffic을 포함하지 않는다.

- 14개 required container: 전체 구간 `running`
- `OOMKilled`: 모두 `false`
- `RestartCount`: 모두 `0`
- 전체 readiness/metrics endpoint: 모든 sample에서 HTTP `200`
- Kafka actual responsiveness: 모든 sample에서 성공
- Kafka exporter: 모든 sample에서 `kafka_brokers=1`
- MySQL: 모든 sample에서 responsive
- Redis: 모든 sample에서 `PONG`
- Docker daemon: 모든 sample에서 responsive
- 관측 최고 memory 비율: worker-2 `85.68%`; 90% 미만
- Grafana 관측 최고 memory 비율: `45.33%` (`116 MiB / 256 MiB`)
- `>= 90%`가 30초 연속 유지된 container: 없음
- macOS `memory_pressure -Q` system-wide free percentage: baseline 중 `40~42%`; critical indication 관측 없음
- Swap: baseline 전/후 모두 `920.62 MiB`; 증가 `0 MiB`

### Clean End

동일한 네 Compose file set으로 `down -v --remove-orphans`를 수행했다.

- Project container: `0`
- Project network: `0`
- Project volume: `0`
- Unrelated resource: 실행 전과 동일하게 container/volume 없음, 기본 network 3개만 유지
- Docker daemon: responsive, running/stopped container `0/0`
- Image `13개`와 build cache는 유지; global prune 미수행
- 종료 후 system-wide memory free percentage: `39%`
- 종료 후 swap: `920.62 MiB`

### 현재 판정 및 남은 미해결 사항

Execution Environment Readiness Preflight는 `PASS`이다. 이 판정은 현재 Task-local resource envelope와 staged startup procedure가 clean healthy baseline을 통과했다는 의미로 제한된다.

남은 사항:

- Kafka Material Failure Run은 시작하지 않았으며 별도 Human Gate가 필요하다.
- Kafka outage의 Failure Signature, Recovery, backlog drain 및 final reconciliation은 아직 평가하지 않았다.
- 현재 staged startup 성공만으로 이전 `kafka-exporter` failure의 Root Cause를 확정할 수 없다.
- worker-2의 이번 관측 최고치는 `85.68%`로 pass criterion 이내지만, production sizing 근거가 아니다.

### Candidate Improvements

다음 항목은 구현하지 않았으며 별도 review 대상으로 유지한다.

1. Kafka exporter startup/readiness handling
2. Mutable exporter image version/digest pinning
3. 실제 Docker Engine capacity 기반 resource-envelope 계산
4. Permanent monitoring resource sizing
5. Obsolete Compose `version` 정리

`EXECUTION ENVIRONMENT READINESS: PASS`

`BIP-FR-001 MATERIAL RUN: NOT STARTED`
