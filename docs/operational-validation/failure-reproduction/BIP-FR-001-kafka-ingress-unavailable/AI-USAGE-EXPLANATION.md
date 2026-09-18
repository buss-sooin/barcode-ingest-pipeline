# BIP-FR-001 AI 활용 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: BIP-FR-001에서 AI와 인간 개발자가 맡은 역할과 판단 경계를 이해하려는 개발자
> 기준 실행: Material Run `20260829T073503Z`

## 한눈에 보기

BIP-FR-001에서는 활성 바코드 입력 중 Kafka가 사용할 수 없게 됐을 때 애플리케이션이 어떻게 반응하고, Kafka 복구 후 전체 입력이 최종 저장소까지 수렴하는지를 검증했다.

Repository에 보존된 문서에 따르면 AI는 다음 역할을 맡도록 구성됐다.

- 서로 다른 로그와 상태 정보를 동일한 시각축으로 정렬
- 최초 장애 경계(First Broken Boundary) 식별
- 최소 복구 조치와 검증 조건 제안
- 재시도 백로그, Kafka, Redis, MySQL 상태 대조
- 입력 식별자와 최종 저장 결과의 정합성 계산
- Evidence에 따른 기술적 `PASS` 또는 `FAIL` 평가

인간 개발자는 다음 책임을 보유했다.

- 재현할 장애와 영향 범위 결정
- 허용할 상태 변경과 금지할 조치 결정
- Kafka `stop/start`라는 복구 경계 승인
- Evidence 부족이나 범위 변경에 대한 판단
- 기술적 판정의 운영적 수용
- 최종 결과와 잔여 위험에 대한 책임

AI의 설명 자체를 성공 근거로 사용하지 않았다. 실행 결과는 Repository의 실행 기록, 로그, 상태 수집 결과와 최종 식별자 대사를 통해 검증됐다.

## 확인 가능한 AI 활용의 범위

Repository에는 다음 자료가 보존돼 있다.

- 장애 재현 실행과 결과를 기록한 `REPRODUCTION-RECORD.md`
- 장애 메커니즘과 결과를 종합한 `TECHNICAL-REPORT.md`
- 진단 절차를 설명한 `OPERATIONAL-DIAGNOSTIC-GUIDE.md`
- 승인된 복구 경계를 설명한 `RUNBOOK.md`
- 장애 동작 원리를 설명한 `KAFKA-FAILURE-LEARNING-NOTE.md`
- AI와 인간의 책임·권한을 정의한 `AI-HUMAN-RESOLUTION-MAPPING.md`
- 세 차례 실행의 원본 Evidence

`AI-HUMAN-RESOLUTION-MAPPING.md`에는 AI가 Evidence 수집·정렬, 진단 가설 작성, 기술적 검증과 정합성 계산을 지원하고, 권한 있는 인간이 Material Decision과 운영 책임을 보유하도록 정의돼 있다.

다만 이 문서는 과거의 모든 대화와 실행을 turn 단위로 기록한 감사 로그는 아니다. Repository에서 확인할 수 있는 사실과 역할 모델을 구분해야 한다.

| 구분 | 확인 가능한 내용 |
|---|---|
| Repository로 직접 확인 | 실행 순서, 명령 결과, 로그, 상태 변화, 최종 수치, 승인된 실행 경계 |
| 역할 문서로 확인 | AI와 인간에게 부여한 책임, 의사결정 권한과 중단 조건 |
| Repository만으로 확인 불가 | 각 대화의 전체 프롬프트, 내부 추론 과정, 모든 명령의 실제 입력 주체 |
| 확인되지 않음 | 사용한 AI 모델과 각 단계의 추론 수준 |

확인되지 않은 모델명이나 추론 수준을 추정하지 않는다.

## 설계·실행·검증의 책임 차이

### 장애 재현 설계

먼저 다음 질문을 고정했다.

> 활성 입력 중 Kafka가 일시적으로 사용할 수 없게 되면 입력은 어디에 남고, Kafka 복구 후 전체 입력이 손실이나 설명되지 않은 상태 없이 최종 저장소까지 도달하는가?

AI는 조건 정리와 검증 구조 작성을 지원할 수 있지만, 어떤 장애를 허용할지와 어느 정도의 위험을 감수할지는 인간 개발자의 결정 영역이었다.

### Repository와 실행 환경 작업

다음과 같은 결정론적 작업은 AI 자동화에 적합했다.

- 파일과 설정 간 일관성 확인
- 실행 환경과 이미지 식별 정보 수집
- Container 상태와 자원 제한 확인
- 시각이 포함된 로그와 상태 저장
- 최종 입력·처리·저장 결과 계산

Application source, Kafka topology, topic, offset 또는 다른 Component 상태를 임의로 변경할 권한은 부여되지 않았다.

### Runtime 실행

Material Run에서 허용된 핵심 상태 변경은 다음과 같이 제한됐다.

```text
활성 synthetic traffic
→ 동일 Kafka Container stop
→ 최대 60초의 bounded outage
→ 동일 Kafka Container start
→ 읽기 전용 복구 검증
```

다음 조치는 허용되지 않았다.

- Kafka Container 재생성
- Kafka 데이터 또는 Volume 삭제
- Topic·Partition·Offset 변경
- Scanner, Processing, Redis, Worker 또는 MySQL 재시작
- 수동 replay 또는 데이터 보정
- 추가 장애 주입

실행 주체가 AI인지 인간인지와 별개로 실행은 승인된 경계 안에서만 가능했다. 새로운 상태 변경이나 범위 확장이 필요하면 실행을 중단하고 인간 판단으로 돌아가도록 설계됐다.

### Evidence 분석과 최종 검증

AI가 지원하기 적합한 핵심 작업은 서로 다른 계층의 Evidence를 하나의 인과관계로 연결하는 것이었다.

```text
Kafka 연결 실패
→ Ingest publish confirmation 실패
→ Scanner fallback 및 retry 활성화
→ Processing과 Worker의 신규 진행 중단
→ 동일 Kafka Broker 복구
→ publish·consume·retry flow 재개
→ 백로그 수렴
→ 최종 식별자 정합성 확인
```

최종 결과는 다음과 같았다.

```text
논리 입력                    820
Kafka transport records    1,235
재시도로 인한 중복 전달       415
Processing unique             820
MySQL unique                  820
DLQ / DLT / pending             0
unaccounted                     0
```

`415`는 MySQL에 남은 업무 데이터 중복이 아니다. 같은 논리 입력에 대한 추가 전송 시도 때문에 Kafka에서 관측된 전송 중복이다. Processing의 Redis 기반 중복 제거가 1,235건을 820건의 고유 이벤트로 수렴시켰고, MySQL도 최종적으로 820개의 고유 식별자를 보유했다.

## 전체 Human–AI 협업 흐름

```text
[인간: 검증 목적과 허용 위험 결정]
                  ↓
[AI 지원: 장애 질문·성공 기준·중단 조건 구조화]
                  ↓
[인간: 실행 경계와 금지 행동 승인]
                  ↓
[AI 또는 승인된 실행자: 환경 준비와 Evidence 수집]
                  ↓
[중단 조건 발생 시 실행 중지]
                  ↓
[인간: 원인과 다음 변경 범위 판단]
                  ↓
[승인된 경계 안에서 Material Run 수행]
                  ↓
[AI 지원: 로그·상태·식별자 대사 및 기술 판정]
                  ↓
[인간: 주장 범위·잔여 위험·운영적 수용 결정]
```

AI는 반복 측정과 Evidence 계산을 담당할 수 있지만, Evidence 부족을 임의로 보충하거나 승인 범위를 확대할 수 없다.

## 실패하거나 수정된 실행의 처리

### 첫 번째 시도 — Resource Preflight 실패

Run `20260829T053958Z`에서는 `kafka-exporter`가 Kafka 연결 실패로 조기 종료됐고, Grafana가 설정된 메모리 상한에 근접했다. 정상 기준선이 안정적이라고 판단할 수 없어 Kafka 장애 주입을 시작하지 않았다.

```text
MATERIAL RUN NOT STARTED
```

### 두 번째 시도 — 실행 환경 준비 검증

Run `20260829T064402Z`에서는 staged startup과 승인된 Grafana 메모리 상한 조정을 통해 실행 환경 준비 상태를 검증했다. Resource Preflight는 `PASS`였지만 Kafka 장애를 재현하지 않았으므로 Material Run 성공으로 해석하지 않았다.

```text
Resource Readiness PASS
≠ Failure Reproduction PASS
```

### 세 번째 시도 — Material Run

Run `20260829T073503Z`에서 활성 트래픽 중 Kafka 중단과 복구, 백로그 수렴 및 최종 정합성을 검증했다.

이 이력은 다음 원칙을 보여준다.

- 중단 조건을 만나면 실행을 멈춘다.
- 준비 상태 검증과 장애 검증을 구분한다.
- 실패 이력을 삭제하거나 성공 결과로 덮어쓰지 않는다.
- 수정 후에도 기존 성공 기준을 완화하지 않는다.
- 최종 판정은 원본 Evidence와 함께 보존한다.

## 인간 개발자가 통제한 Engineering Rule

1. Kafka ingress unavailable을 검증 대상으로 선택한다.
2. 단일 Broker의 일시적 중단만 허용한다.
3. Outage 시간을 최대 60초로 제한한다.
4. 동일 Kafka Container의 `stop/start`만 복구 조치로 허용한다.
5. 데이터, Topic, Offset 및 다른 Component의 임의 변경을 금지한다.
6. 사전 조건이 충족되지 않으면 Material Run을 시작하지 않는다.
7. 복구를 Kafka Process 기동만으로 판정하지 않는다.
8. 백로그와 최종 데이터 정합성까지 확인한다.
9. Evidence가 증명하지 않은 production 보장을 주장하지 않는다.
10. 최종 운영 수용과 잔여 위험의 책임은 인간 또는 조직이 보유한다.

## Human Gate와 실행 경계

사람 승인 관문(Human Gate)은 모든 작은 작업을 사람이 대신 수행한다는 뜻이 아니다. 승인된 실행 경계가 정해지면 AI 또는 다른 실행자는 그 안에서 상태 확인, 로그·metric 수집, 정해진 명령 실행, 결과 계산과 성공 기준 적용을 수행할 수 있다.

다음 상황에서는 다시 인간 판단이 필요하다.

- 승인되지 않은 Component를 변경해야 한다.
- Kafka Container 재생성이나 Storage 변경이 필요하다.
- Topic, Partition 또는 Offset을 조작해야 한다.
- 데이터 삭제·수정 또는 수동 replay가 필요하다.
- Evidence가 서로 충돌한다.
- 관측할 수 없는 상태를 추정해야 한다.
- 기존 성공 기준이나 장애 범위를 변경해야 한다.

Human Gate는 AI가 명령을 실행하지 못해서 존재하는 것이 아니라, 중요한 범위·위험·권한 결정을 인간이 소유하기 위해 존재한다.

## AI 결과와 Repository Evidence 대조

| 검증 대상 | 대조한 Evidence |
|---|---|
| Kafka 장애가 실제 발생했는가 | Kafka Container 상태, Broker 연결 실패와 exporter 상태 |
| Ingest가 전달 실패를 감지했는가 | Producer와 batch confirmation 로그 |
| Scanner retry가 활성화됐는가 | fallback, enqueue, scheduled retry 로그 |
| Downstream 진행이 중단됐는가 | Processing receive와 Worker read 상태 |
| 동일 Broker가 복구됐는가 | Container identity와 Broker/Topic probe |
| Flow가 재개됐는가 | 첫 publish, consume 및 retry success 시각 |
| 백로그가 해소됐는가 | Scanner retry, Kafka lag, Redis lag와 PEL의 연속 표본 |
| 데이터가 최종 수렴했는가 | 생성 식별자 manifest와 MySQL 고유 식별자 집합 |
| 설명되지 않은 결과가 남았는가 | DLQ, DLT, pending, missing, extra, unaccounted 확인 |

한 개의 로그만으로 전체 장애 원인을 확정하지 않고, 서로 다른 Component와 저장 경계의 Evidence를 함께 사용했다.

## 자동화와 인간 판단의 적합성

| AI 자동화에 적합 | 사람의 이해·판단이 필요한 부분 |
|---|---|
| 많은 로그의 UTC 시각 정렬 | 어떤 장애가 실제 운영에서 중요한지 결정 |
| 반복 상태 수집과 형식화 | 허용 가능한 영향 반경과 복구 조치 결정 |
| Kafka·Redis·MySQL 수치 대조 | 업무 식별자와 불변조건 정의 |
| 생성·저장 식별자의 집합 비교 | Evidence가 없는 운영 보장 제한 |
| 성공 조건과 결과의 기계적 대조 | 후속 개선 위험 수용 여부 |
| Evidence locator와 실행 이력 정리 | 최종 결과의 공개 범위와 운영적 의미 결정 |

## 확인되지 않은 사항

- 각 단계에서 사용된 AI 모델과 정확한 추론 수준
- 과거 대화의 전체 프롬프트
- AI 내부 추론 과정
- 모든 명령을 AI와 인간 중 누가 직접 입력했는지
- 각 판단에 참여한 사람의 조직상 직책
- 415건 각각의 하위 재시도 메커니즘별 완전한 분해

확인되지 않은 정보를 AI 활용 성과로 보충하거나 추정하지 않는다.

## Claim Boundary

이 작업은 제한된 로컬 환경에서 AI를 이용해 장애 조건, 실행 경계, Evidence와 최종 정합성을 연결할 수 있음을 보여준다. 다음은 증명하지 않는다.

- AI가 운영 장애의 최종 결정권자라는 주장
- AI의 기술적 `PASS`가 인간의 운영 승인을 대체한다는 주장
- 모든 Kafka 장애에서 데이터가 동일하게 보존된다는 보장
- Scanner 재시작 또는 retry queue overflow 내구성
- Kafka Storage 손실이나 Container 재생성 복구
- Replicated Kafka HA
- Production SLA, RTO 또는 RPO
- End-to-end exactly-once 보장
- 이 협업 구조가 Project 전체의 표준으로 승인됐다는 주장

## 관련 자료

- [REPRODUCTION-RECORD.md](./REPRODUCTION-RECORD.md)
- [TECHNICAL-REPORT.md](./TECHNICAL-REPORT.md)
- [RUNBOOK.md](./RUNBOOK.md)
- [OPERATIONAL-DIAGNOSTIC-GUIDE.md](./OPERATIONAL-DIAGNOSTIC-GUIDE.md)
- [KAFKA-FAILURE-LEARNING-NOTE.md](./KAFKA-FAILURE-LEARNING-NOTE.md)
- [AI-HUMAN-RESOLUTION-MAPPING.md](./AI-HUMAN-RESOLUTION-MAPPING.md)
- [Material Run Evidence](./evidence/20260829T073503Z/)
