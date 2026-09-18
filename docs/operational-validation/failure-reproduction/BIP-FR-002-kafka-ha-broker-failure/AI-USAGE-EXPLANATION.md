# BIP-FR-002 AI 활용 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: BIP-FR-002 검증에서 AI와 사람이 어떤 책임을 맡았는지 알고 싶은 개발자

## 한눈에 보기

BIP-FR-002에서 AI는 장애 성공 기준을 먼저 문서로 고정하고, 전용 Kafka HA 환경과 증거 수집 절차를 구현하며, 실행 결과를 Evidence와 대조하는 데 사용됐다. 인간 개발자는 장애 범위와 위험을 결정하고, AI가 따라야 할 Engineering Rule과 단계별 Human Gate를 통제하며, 최종 주장의 범위를 승인했다.

이 방식의 핵심은 AI에게 모든 결정을 맡기는 것이 아니다. 인간이 목적·규칙·권한 경계를 정하고, AI가 그 안에서 설계·구현·실행·검증을 연결하는 구조다.

## 사용한 AI 제원과 역할 구성

| 항목 | 적용 내용 |
|---|---|
| 모델 | `GPT-5.6 Sol` |
| 추론 수준 | `Normal`부터 `Extra High`까지 작업 복잡도에 따라 선택 |
| 설계·검토 역할 | Failure Question, 성공 기준, 인과관계와 주장 경계 검토 |
| 저장소 실행 역할 | 파일 구현, 명령 실행, 정적 검증, Material Run과 Evidence 수집 |
| 인간 통제 | Engineering Rule, 실행 권한, Human Gate와 최종 결과 승인 |

추론 수준은 모든 작업에 가장 높은 값을 고정하지 않았다.

- `Normal`: 정해진 규칙에 따른 탐색, 단순 수정과 형식 확인
- `High`: 장애 시나리오 설계, 구현 검토와 원인 분석
- `Extra High`: Evidence 간 모순 검사, 최종 판정과 주장 경계 검토

모델과 추론 수준 범위는 인간 개발자가 확인한 실행 제원이다. 다만 각 과거 turn에 적용된 세부 설정값까지 Repository Evidence로 독립 재구성하지는 않는다.

AI 작업은 책임에 따라 다음처럼 나눴다.

| AI 작업 | 사용 목적 | 주요 결과 |
|---|---|---|
| 설계·검토 대화 | Failure Question, 성공·실패·무효 조건, 사람 승인 경계 정리 | `REPRODUCTION-CONTRACT.md` |
| 저장소 실행 작업 | Compose, topic 초기화, 상태 수집 도구와 실행 절차 구현 | `docker-compose.validation.yml`, `init-kafka-topics.sh`, `capture-kafka-ha-state.sh` |
| Evidence 분석 | Kafka 상태, 애플리케이션 로그, 최종 데이터 집합 대조 | `REPRODUCTION-RECORD.md`, `TECHNICAL-REPORT.md`, Material Run Evidence |

과거 프롬프트 전문과 AI 내부 추론 과정은 Repository Evidence에 보존돼 있지 않다. 이 문서는 확인 가능한 산출물, 실행 이력과 인간 개발자가 확인한 AI 제원만 설명한다.

## 인간이 정한 Rule과 AI Workflow

다음은 BIP-FR-002에 적용한 전체 개발 흐름이다. 위쪽의 Rule은 특정 한 단계가 아니라 모든 AI 작업을 통제한다.

```text
┌──────────────────────── 인간 개발자가 정한 Engineering Rule ────────────────────────┐
│ R1. 설계와 실행의 책임을 분리한다.                                                   │
│ R2. 장애 실행 전에 질문·범위·성공/실패/무효 기준을 계약으로 고정한다.                │
│ R3. 승인된 범위와 Human Gate 밖의 mutation·실행·장애 주입은 진행하지 않는다.         │
│ R4. 사실·관찰·해석·추론을 구분하고, 원본 Evidence보다 AI 설명을 우선하지 않는다.    │
│ R5. 기준 미충족 또는 증거 부족은 성공으로 보정하지 않고 FAIL/INVALID로 닫는다.       │
│ R6. 교정은 성공 기준을 완화하지 않고 발견된 실행 편차만 최소 수정한다.               │
│ R7. 검증 결과를 production HA·SLA 등 미검증 범위로 확대하지 않는다.                 │
└──────────────────────────────────┬───────────────────────────────────────────────────┘
                                   │ 모든 단계 통제
                                   ▼
[1. Human: 목적·위험·권한 경계 결정]
                                   │
                                   ▼
[2. AI: Failure Question과 Reproduction Contract 설계]
                                   │
                      Human Gate: 설계·범위 승인
                                   │
                                   ▼
[3. AI 실행: 전용 topology·관측 도구 구현 → 정적 검증]
                                   │
                      Human Gate: runtime 실행 승인
                                   │
                                   ▼
[4. AI 실행: 정상 기준선 → active traffic → 장애 주입 → 복구]
                                   │
                                   ▼
[5. AI 분석: Evidence 보존 → 시간·상태·identity 대사]
                                   │
                                   ▼
[6. 계약 대조: PASS / FAIL / INVALID]
              ├─ 기준 미충족 또는 증거 공백
              │      → 이력 보존 → 최소 교정 → Human Gate → 재실행
              └─ 모든 기준 충족
                     → Human: 결과·주장 경계 확인 → 최종 확정
```

### Rule이 개발 품질을 지킨 지점

| Rule | FR-002에서의 적용 | 품질 효과 |
|---|---|---|
| R1 설계·실행 분리 | 검증 질문과 계약을 먼저 정한 뒤 저장소 구현·실행 | 구현 편의가 검증 의미를 바꾸는 것을 방지 |
| R2 계약 우선 | leader election, ISR, 처리 지속, 복구와 정합성 기준 사전 고정 | 결과에 맞춘 성공 기준 변경 방지 |
| R3 권한과 Human Gate | 구현, runtime, 장애 주입과 복구를 단계별 승인 | AI의 임의 실행과 영향 반경 확대 방지 |
| R4 Evidence 우선 | 원본 Kafka 상태·로그·identity 집합을 보존해 AI 해석과 대조 | 설명이 아니라 재검증 가능한 사실로 판정 |
| R5 Fail-closed | 첫 실행의 시간 중첩 실패를 `Partial / Inconclusive`로 보존 | 불완전한 실험의 성공 승격 방지 |
| R6 최소 교정 | 성공 기준은 유지하고 장애 주입 timing orchestration만 수정 | 회귀 원인만 교정하고 Scenario 의미 보존 |
| R7 주장 제한 | 로컬 단일 controller, 단일 broker와 bounded traffic으로 한정 | 제한된 Evidence의 과도한 일반화 방지 |

## FR-002에 실제 적용된 결과

- AI는 `RF=3`, `min.insync.replicas=2`, `acks=all` 경계에서 단일 leader broker 장애를 검증하는 질문과 성공·실패·무효 조건을 계약으로 고정했다.
- 전용 KRaft controller 1개, broker 3개, 명시적 topic 생성과 읽기 전용 상태 수집 도구를 저장소에 구현했다.
- 첫 Material Run은 active traffic 종료 후 SIGKILL이 실행된 증거 공백 때문에 `Partial / Inconclusive Evidence`로 보존했다.
- 성공 기준을 완화하지 않고 `traffic start < SIGKILL < traffic end`를 보장하도록 실행 timing만 교정한 뒤 Strict Run을 수행했다.

Strict Run에서는 다음 인과관계를 Evidence로 연결했다.

```text
broker-2 실패
→ controller fencing
→ leader 2에서 3으로 전환
→ ISR 3개에서 2개로 축소
→ broker down 상태의 새 acks=all 쓰기와 downstream 진행
→ broker-2 복귀와 replica catch-up
→ ISR 3, URP 0, unavailable 0
→ logical input 66과 MySQL unique 66 대사
```

## AI 결과는 어떻게 검증됐는가

AI의 설명만으로 성공을 판정하지 않았다. 다음 정본을 서로 대조했다.

- 사전 계약: `REPRODUCTION-CONTRACT.md`
- 두 실행의 이력과 편차: `REPRODUCTION-RECORD.md`
- 원본 명령·로그·상태: `evidence/`
- 최종 해석과 주장 경계: `TECHNICAL-REPORT.md`

Strict Run의 직접 Evidence는 active traffic 중 SIGKILL, clean leader election, broker down 상태의 새 producer acknowledgment, 복구 후 ISR과 backlog 수렴, 식별자 수준의 최종 정합성을 확인했다.

## 자동화하기 적합한 일과 사람이 판단할 일

| AI 자동화에 적합 | 사람의 이해·판단이 필요한 부분 |
|---|---|
| topology와 설정 수집 | 어떤 장애와 위험을 허용할지 |
| leader·ISR·lag 변화 추적 | 허용 가능한 중단 시간과 중복 영향 |
| 명령과 로그의 시각 정렬 | 서비스 불변조건 정의 |
| 입력·Kafka·MySQL 결과 대사 | production 적용과 RTO/RPO 결정 |
| 계약에 따른 PASS/FAIL 후보 계산 | 최종 주장과 공개 범위 승인 |

## 한계

이 AI 활용 결과는 재현 가능한 Evidence를 만들고 계약에 따라 판정하는 데 강점이 있다. 그러나 controller HA, 다중 broker 장애, 네트워크 partition, storage 손실과 production SLA는 이번 작업에서 검증하지 않았다. AI가 현재 실행을 성공으로 판정했다고 해서 이 미검증 영역까지 안전하다는 뜻은 아니다.
