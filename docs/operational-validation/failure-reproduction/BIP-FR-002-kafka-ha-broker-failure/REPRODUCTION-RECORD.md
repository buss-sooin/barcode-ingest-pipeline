# BIP-FR-002 — Kafka HA 단일 브로커 장애 재현 기록

## 1. 문서 책임

이 문서는 BIP-FR-002의 실행·증거 이력을 보존하는 재현 기록(Reproduction Record)이다. 실행 전에 고정한 조건과 판정 기준은 [재현 계약](./REPRODUCTION-CONTRACT.md), 결과 해석과 최대 검증 주장은 [기술 보고서](./TECHNICAL-REPORT.md)가 담당한다. 이 문서는 원시 로그를 복사하지 않고 두 Material Run의 역할, 시간선, 증거 위치와 증거-주장 연결을 제공한다.

## 2. Material Run 이력과 Contract Revision 매핑

Contract ID는 `BIP-FR-002-RC`다. 각 Material Run에는 다음과 같이 정확히 하나의 적용 Revision을 연결한다.

| Material Run | 적용 Contract Revision | 분류 | 역할 | 판정 |
|---|---|---|---|---|
| `BIP-FR-002-MR-20260902T043510Z` | [`BIP-FR-002-RC-R1`](./REPRODUCTION-CONTRACT.md#bip-fr-002-rc-r1) | `Partial / Inconclusive Evidence` | Kafka 고가용성(High Availability, HA) 전이·저하 상태 쓰기·복구·실행 범위 정합성을 증명하고 시간 오케스트레이션 편차를 노출한 최초 실행 | 엄격한 시간 조건은 미충족. 나머지 관측은 유효한 Engineering history로 보존 |
| `BIP-FR-002-MR-20260902T053228Z` | [`BIP-FR-002-RC-R2`](./REPRODUCTION-CONTRACT.md#bip-fr-002-rc-r2) | `STRICT PASS` | active traffic과 SIGKILL의 시간 중첩을 포함해 승인된 시나리오를 검증한 주 실행 | 승인된 로컬 bounded run의 최대 검증 주장 충족 |

두 실행은 병합하거나 대체하지 않는다. 최초 실행은 폐기되거나 실패한 증거가 아니며, 엄격한 시간 술어를 충족하지 못한 원인을 드러내고 bounded rerun의 필요성을 결정한 근거다.

Revision 식별자는 사후 추적성 보정에서 Canonical Artifact에 기록됐다. Run → Revision 적용 관계는 Git 이력, 각 Run identity, 최초 실행의 시간 편차와 Strict Run에 보존된 orchestration 절차에 근거한다. 정확한 R2 사전 승인 시각·승인 식별자는 Evidence에 없으므로 이 기록에서 생성하지 않는다.

## 3. 증거 무결성과 탐색 시작점

각 디렉터리의 `MANIFEST.sha256`은 해당 실행에 속한 모든 보존 파일을 열거한다. 저장소 루트에서 다음 명령으로 독립 검증할 수 있다.

```bash
cd docs/operational-validation/failure-reproduction/BIP-FR-002-kafka-ha-broker-failure/evidence/BIP-FR-002-MR-20260902T043510Z
shasum -a 256 -c MANIFEST.sha256

cd ../BIP-FR-002-MR-20260902T053228Z
shasum -a 256 -c MANIFEST.sha256
```

- 최초 실행: [증거 디렉터리](./evidence/BIP-FR-002-MR-20260902T043510Z/), [SHA-256 manifest](./evidence/BIP-FR-002-MR-20260902T043510Z/MANIFEST.sha256), [파생 시간선과 편차](./evidence/BIP-FR-002-MR-20260902T043510Z/26-derived-timeline-and-deviation.txt)
- 엄격 실행: [증거 디렉터리](./evidence/BIP-FR-002-MR-20260902T053228Z/), [SHA-256 manifest](./evidence/BIP-FR-002-MR-20260902T053228Z/MANIFEST.sha256), [파생 시간선과 판정](./evidence/BIP-FR-002-MR-20260902T053228Z/23-derived-timeline-and-verdict.txt)

## 4. 최초 Material Run — `Partial / Inconclusive Evidence`

### 4.1 핵심 시간선

| UTC | 관측 |
|---|---|
| `04:40:29` | `SEOUL-CENTER-PC-001 → partition 1 → leader broker 2` 런타임 매핑 기록 |
| `04:47:00–04:48:18` | 75-request active traffic 실행, 모두 Scanner HTTP 200 |
| `04:51:39` | broker 2에 SIGKILL, active traffic 종료보다 201초 늦음 |
| `04:51:47` | controller가 broker 2 fencing |
| `05:05:53–05:06:07` | broker 2가 DOWN인 동안 15건의 새 producer acknowledgment, partition 1 end offset `77 → 92` |
| `05:07:13–05:07:40` | 같은 broker/container/volume 복구, ISR 3·복제 부족 파티션(Under-replicated Partition, URP) 0·unavailable 0 수렴 |
| `05:09:19` | 실행 범위 정합성 확인 완료: generated unique 91 = MySQL unique 91 |

근거는 [active traffic](./evidence/BIP-FR-002-MR-20260902T043510Z/07-active-traffic-session.txt), [장애 주입](./evidence/BIP-FR-002-MR-20260902T043510Z/08-failure-injection.txt), [저하 상태 쓰기와 파생 시간선](./evidence/BIP-FR-002-MR-20260902T043510Z/26-derived-timeline-and-deviation.txt), [최종 정합성 요약](./evidence/BIP-FR-002-MR-20260902T043510Z/final/21-run-scoped-reconciliation-summary.txt)에 있다.

### 4.2 증명한 내용과 편차

이 실행은 clean leader `2 → 3`, ISR `2,3,1 → 3,1`, broker 2 DOWN 상태의 새 `acks=all` 쓰기 15건, downstream 진행, 같은 volume 복구, ISR 회복과 실행 범위 정합성을 직접 증명했다.

그러나 승인된 엄격한 시간 조건은 다음과 같았고 실제 시간은 이를 충족하지 못했다.

```text
요구: traffic start < SIGKILL < traffic end
관측: traffic end < SIGKILL (201초 간격)
```

따라서 이 실행만으로는 “active scan traffic과 시간적으로 겹친 SIGKILL”을 주장할 수 없다. 시스템 메커니즘 증거는 유효하지만 시나리오 전체에는 증거가 불충분하므로 `Partial / Inconclusive Evidence`로 보존한다.

### 4.3 bounded rerun 결정

편차의 원인은 장애 전 상태를 수동 확인·승인하는 동안 active traffic이 먼저 끝난 시간 오케스트레이션 경계였다. 시스템 성공 기준을 사후 변경하지 않고, 동일한 토폴로지·장애 대상·정합성 기준을 유지한 채 실행 스크립트가 sequence 10 직전에 대상을 재검증하고 같은 traffic loop 안에서 SIGKILL하도록 bounded rerun을 수행했다. rerun 실행 절차 자체는 [보존된 스크립트](./evidence/BIP-FR-002-MR-20260902T053228Z/run-bounded-rerun.sh)로 확인할 수 있다.

## 5. Strict Material Run — `STRICT PASS`

### 5.1 실행 경계

- 저장소 HEAD: `1530bc6346c8255909c3e5851cbbae714305917c`
- branch: `validation/bip-fr-002-kafka-ha-broker-failure`
- 전용 KRaft controller 1개, broker-only 프로세스 3개
- `barcode-events`: partitions 3, 복제 계수(Replication Factor, RF) 3, `min.insync.replicas=2`
- producer `acks=all`, unclean leader election 비활성화
- 런타임 매핑: `SEOUL-CENTER-PC-001 → partition 1 → leader broker 2`
- 주입 대상: `broker-2` 하나, 데이터 volume 유지

[실행 정체성](./evidence/BIP-FR-002-MR-20260902T053228Z/00-run-identity-and-repository.txt), [건전한 사전 조건](./evidence/BIP-FR-002-MR-20260902T053228Z/02-healthy-preconditions.txt), [런타임 대상 매핑](./evidence/BIP-FR-002-MR-20260902T053228Z/06-runtime-target-mapping.txt)을 시작점으로 사용한다.

### 5.2 인과 시간선

| UTC | 직접 관측된 사건 | 상태 의미 |
|---|---|---|
| `05:36:46` | active traffic 시작 | partition 1에 run-scoped offset 진행 시작 |
| `05:36:59` | partition 1 leader인 broker 2 SIGKILL | traffic 구간 내부에서 단일 broker 실패 |
| `05:37:08.439` | controller가 broker 2 fencing | 실패 broker가 쓰기 경계에서 제외됨 |
| `05:37:08.504` | broker 3이 partition 1 leader로 시작 | pre-failure ISR member의 clean leader 선출, leader `2 → 3`, ISR `3,1,2 → 3,1` |
| `05:37:12.210` | 첫 post-kill producer acknowledgment, offset 103 | 남은 두 ISR에서 `acks=all` 새 쓰기 재개 |
| `05:37:54` | active traffic 종료, broker 2는 계속 DOWN | final broker-down acknowledgment offset 161, downstream 진행 및 backlog 0 |
| `05:39:32` | broker 2만 기존 container/volume으로 시작 | 데이터 상태를 초기화하지 않은 통제된 복구 |
| `05:39:35–05:39:36` | 등록·replica catch-up·unfence·ISR 재진입 | ISR `3,1 → 3,1,2` |
| `05:39:47` | 연속 회복 sample 완료 | ISR 3, URP 0, unavailable 0 |
| `05:43:04–05:43:09` | 정합성 확인과 terminal sample | `66 → 75 → 66`, lag/DLQ/DLT/pending 0 |

시간 중첩은 [traffic 경계](./evidence/BIP-FR-002-MR-20260902T053228Z/07-active-traffic-boundaries.txt)와 [SIGKILL 기록](./evidence/BIP-FR-002-MR-20260902T053228Z/08-failure-injection.txt), 전이와 판정은 [파생 시간선](./evidence/BIP-FR-002-MR-20260902T053228Z/23-derived-timeline-and-verdict.txt)에서 확인한다.

### 5.3 최종 정합성

```text
Generated unique 66
= MySQL unique 66
+ DLQ 0
+ DLT 0
+ pending 0
+ unaccounted 0
```

Missing 0, extra 0, business duplicate 0이며 Kafka consumer lag과 Redis group lag도 0으로 수렴했다. Transport 경계에서는 `66 logical events → 75 Kafka records → 9 duplicate detections → 66 unique business results`가 관측됐다. 자세한 책임 해석은 [기술 보고서](./TECHNICAL-REPORT.md)의 전송 중복 절을 따른다.

근거: [생성 manifest](./evidence/BIP-FR-002-MR-20260902T053228Z/03-generated-manifest.tsv), [실행 범위 정합성 요약](./evidence/BIP-FR-002-MR-20260902T053228Z/final/21-run-scoped-reconciliation-summary.txt), [terminal 수렴 sample](./evidence/BIP-FR-002-MR-20260902T053228Z/final/22-terminal-convergence-sample.txt).

## 6. 증거 → 주장 매핑

| 주장 | 분류 | 주 증거 |
|---|---|---|
| 두 실행의 branch/HEAD와 최초 실행 보존 | 직접 증명(Directly Proven) | [최초 실행 정체성](./evidence/BIP-FR-002-MR-20260902T043510Z/00-run-identity-and-repository.txt), [Strict Run 정체성](./evidence/BIP-FR-002-MR-20260902T053228Z/00-run-identity-and-repository.txt) |
| Strict Run의 건전한 토폴로지와 설정 | 직접 증명 | [사전 조건](./evidence/BIP-FR-002-MR-20260902T053228Z/02-healthy-preconditions.txt), [topic/config 원본](./evidence/BIP-FR-002-MR-20260902T053228Z/before/05-barcode-events-topic.txt) |
| `traffic start < SIGKILL < traffic end` | 직접 증명 | [traffic 경계](./evidence/BIP-FR-002-MR-20260902T053228Z/07-active-traffic-boundaries.txt), [장애 주입](./evidence/BIP-FR-002-MR-20260902T053228Z/08-failure-injection.txt) |
| clean leader `2 → 3`, ISR `3 → 2` | 직접 증명 | [저하 상태 snapshot](./evidence/BIP-FR-002-MR-20260902T053228Z/down/00-active-traffic-degraded-snapshot.txt), [controller/broker logs](./evidence/BIP-FR-002-MR-20260902T053228Z/final/10-controller-and-broker-logs.txt) |
| broker 2 DOWN 중 새 acknowledgment·offset·downstream 진행 | 직접 증명 | [material window application logs](./evidence/BIP-FR-002-MR-20260902T053228Z/down/01-material-window-application-logs.txt), [저하 상태 terminal](./evidence/BIP-FR-002-MR-20260902T053228Z/down/02-degraded-terminal-state.txt) |
| 같은 container/volume 복구와 ISR 재수렴 | 직접 증명 | [broker restart](./evidence/BIP-FR-002-MR-20260902T053228Z/09-broker-restart.txt), [replica catch-up](./evidence/BIP-FR-002-MR-20260902T053228Z/10-replica-catch-up-timeline.txt) |
| `66 → 75 → 66`과 9건 중복 검출 | 직접 증명 | [정합성 요약](./evidence/BIP-FR-002-MR-20260902T053228Z/final/21-run-scoped-reconciliation-summary.txt), [producer/processing logs](./evidence/BIP-FR-002-MR-20260902T053228Z/final/11-producer-and-processing-logs.txt) |
| 7회 Scanner 폴백 + 2회 HTTP 503 자동 재실행 | 직접 증명 | [material window application logs](./evidence/BIP-FR-002-MR-20260902T053228Z/down/01-material-window-application-logs.txt) |
| 효과적 런타임 `enable.idempotence=true` 등 Kafka client 기본값 | 강한 추론(Strongly Inferred) | 해당 버전 기본값과 정합하지만 런타임 `ProducerConfig` snapshot 없음 |
| SIGKILL 순간 특정 in-flight record의 append/ACK wire-level 상태 | 미해결(Unresolved) | producer ID/epoch/sequence 및 protocol capture 없음 |

## 7. 기록 판정

최초 Material Run은 시간 중첩을 제외한 Kafka HA·복구·정합성 증거로 유지한다. Strict Material Run은 같은 성공 기준을 변경하지 않고 누락됐던 시간 술어까지 충족했으므로 이 시나리오의 주 검증 실행이며 최종 판정은 `STRICT PASS`다. 이 판정은 [기술 보고서의 최대 검증 주장과 명시적 비주장](./TECHNICAL-REPORT.md#17-최대-검증-주장)에 의해 제한된다.
