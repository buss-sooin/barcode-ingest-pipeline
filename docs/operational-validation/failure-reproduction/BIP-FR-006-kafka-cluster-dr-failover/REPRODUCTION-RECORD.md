# BIP-FR-006 — Kafka Cluster DR Failover 재현 기록

## 1. 문서 책임

이 문서는 BIP-FR-006의 실행·증거·종료 상태를 보존하는 정본 재현 기록(Reproduction Record)이다. 실행 전에 고정한 조건과 판정 기준은 [재현 계약](./REPRODUCTION-CONTRACT.md)이 담당하며, 상세 실행 Evidence는 이 문서가 연결하는 `evidence/` 아래에 보존한다.

## 2. 최종 판정

- Material Run: `COMPLETED`
- Experiment Validity: `PASS`
- Evidence Sufficiency: `PARTIAL`
- Failure Signatures FS-1~FS-5: `PASS`
- Outcome: `REPRODUCED`

Material Run은 계약 유효성 조건을 충족했다. 다만 마지막 pre-fault 요청 완료와 fault 시작 사이에 20초가 있어, fault 순간의 in-flight 복제 창을 강하게 자극하지 못했다. 따라서 실험 유효성은 `PASS`, Evidence 충분성은 `PARTIAL`로 구분한다.

## 3. 저장소 상태

- 대상: 이 문서가 포함된 `barcode-ingest-pipeline` 저장소
- Material Run 등록 branch: `validation/bip-fr-006-kafka-cluster-dr-failover`
- 기준 HEAD: `761afd9facf25266e31e15f2b3ffc5b88a94c4af`
- closure 검증 branch/HEAD: 위 branch/HEAD와 동일
- working tree: FR-006 artifact와 이를 추적하기 위한 `.gitignore` 예외만 변경
- commit: NO
- push: NO

## 4. 구현 결과

- Cluster A: dedicated controller 1개와 broker 3개, application topic RF=3/minISR=2
- Cluster B: 별도 KRaft cluster ID, service/container/network/volume/port, broker/controller 1개, RF=1
- MM2: A→B only, 명시적 topic/group filter, checkpoint/offset-sync/heartbeat, RF=1 internal topic, `IdentityReplicationPolicy`
- 책임 이전: `ingest-a`/`processing-a`와 profile-gated `ingest-b`/`processing-b`를 환경 설정으로 분리
- Evidence: Kafka topic/offset/group, MM2 process/log/internal topic, HTTP, Redis Stream/PEL/DLQ, MySQL, container resource와 논리 식별자 수집
- 트래픽: 명시적 identity, attempt 결과, HTTP status/time을 TSV manifest에 보존
- Java production source 변경: 없음

## 5. Preflight

| 검사 | 결과 | 근거 |
|---|---|---|
| Docker memory/disk/resource budget | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/01-container-stats.txt` |
| Cluster A controller 및 broker 3개 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/00-compose-ps.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/02-a-quorum.txt` |
| A RF=3, full ISR, URP=0, unavailable=0 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/03-a-topics.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/04-a-urp.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/05-a-unavailable.txt` |
| Cluster B healthy 및 RF=1 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/10-b-quorum.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/11-b-topics.txt` |
| Redis/MySQL/Processing/Persistence baseline | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/00-compose-ps.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/30-http-health.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/31-redis.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/32-mysql.txt` |
| MM2 image/process/classes/config | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/23-mm2-logs.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/24-mm2-process.txt` |
| `barcode-events` A→B | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/16-b-events.txt` |
| `barcode-events-dlt` 경로 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/11-b-topics.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/17-b-dlt.txt` |
| checkpoint/offset-sync 동작 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/13-b-group.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/18-mm2-topics.txt`, `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/23-mm2-logs.txt` |
| B consumer pre-failover 비활성 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/14-b-group-members.txt` |
| offset continuation 실동작 | PASS | `evidence/PREFLIGHT-20260923T032348Z/02-after-a-traffic/33-app-logs.txt` |
| B topic naming과 consumer 설정 | PASS | `evidence/PREFLIGHT-20260923T032348Z/04-resource-safe-final/16-b-events.txt`, B consumer 실제 시작 offset 6 검증 |

Preflight에서는 A에 7개 식별자를 발행하고 B 복제 및 MySQL 저장을 확인했다. A processing을 정지한 뒤 B processing이 동기화된 committed offset 6에서 시작하여 7번째 식별자를 처리하는 것을 실증했다. 이후 A 책임으로 복귀하고 B consumer가 비활성임을 다시 확인했다.

전용 `connect-mirror-maker` 프로세스의 REST 18083 응답은 제공되지 않았다. worker process, connector/task 시작 로그, internal topic, target group offset, 실제 continuation으로 런타임 동작을 검증했다.

## 6. Material Run 식별자

- Run ID: `BIP-FR-006-MR-20260923T042048Z`
- Contract Revision: `BIP-FR-006-RC-R1`
- 등록/시작: `2026-09-23T04:20:48Z`
- 검증 범위 종료(최종 정합성 산출): `2026-09-23T04:34:06Z`
- 등록 정보와 설정 hash: `evidence/BIP-FR-006-MR-20260923T042048Z/00-run-registration.txt`

## 7. Fault 및 failover 타임라인

| 사건 | UTC | Evidence |
|---|---:|---|
| healthy baseline traffic | 04:24:36–04:24:37 | `evidence/BIP-FR-006-MR-20260923T042048Z/traffic-manifest.tsv` |
| active pre-fault traffic | 04:26:31–04:26:40 | `evidence/BIP-FR-006-MR-20260923T042048Z/traffic-manifest.tsv` |
| fault command 시작 | 04:27:00 | `evidence/BIP-FR-006-MR-20260923T042048Z/03-fault-and-unavailability.txt` |
| `t_A_unavailable` | 04:27:01 | `evidence/BIP-FR-006-MR-20260923T042048Z/03-fault-and-unavailability.txt` |
| B offset/checkpoint 경계 수집 | 04:27:37 | `evidence/BIP-FR-006-MR-20260923T042048Z/04-b-boundary.txt` |
| A application 책임 정지 | 04:28:13 | `evidence/BIP-FR-006-MR-20260923T042048Z/07-producer-switch.txt` |
| B ingest 시작/ready | 04:28:14 / 04:28:22 | `evidence/BIP-FR-006-MR-20260923T042048Z/07-producer-switch.txt` |
| `t_B_publish` producer ack | 04:28:44.613 | `evidence/BIP-FR-006-MR-20260923T042048Z/11-final/33-app-logs.txt` |
| B processing 시작/ready | 04:29:54 / 04:30:02 | `evidence/BIP-FR-006-MR-20260923T042048Z/08-consumer-switch.txt` |
| 실제 B consumer 시작 offset | 04:30:02.313, partition 1 offset 37 | `evidence/BIP-FR-006-MR-20260923T042048Z/09-b-processing-start-and-first-consumption.log` |
| 첫 B consumption | 04:30:02.366 (identity log 04:30:02.367) | `evidence/BIP-FR-006-MR-20260923T042048Z/09-b-processing-start-and-first-consumption.log` |
| `t_B_e2e`, 첫 post-failover MySQL 저장 | 04:30:02.420272 | `evidence/BIP-FR-006-MR-20260923T042048Z/10-mysql-after-first-b.tsv` |
| 추가 B traffic 완료 | 04:30:55 | `evidence/BIP-FR-006-MR-20260923T042048Z/traffic-manifest.tsv` |
| backlog stable 확인 | 04:31:30 | 실행 중 polling 결과, 최종 상태는 `evidence/BIP-FR-006-MR-20260923T042048Z/11-final/13-b-group.txt`, `evidence/BIP-FR-006-MR-20260923T042048Z/11-final/31-redis.txt` |
| 최종 정합성 | 04:34:06 | `evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/13-counts.txt` |

## 8. 정량 결과

- Publication Recovery: `103.613초` = 04:28:44.613 - 04:27:01
- Observed Failover RTO: `181.420272초` = 04:30:02.420272 - 04:27:01
- accepted logical identities: 41
- A에서 fault 전 accepted: 30
- fault 경계 B 확인: 30
- fault 경계 MySQL durable 완료: 30
- 관측된 RPO exposure: 0건, identity set 빈 집합
- replay: 0건. B consumer는 경계 offset 37에서 시작했고 최초 소비도 새 B record offset 37이었다.
- B transport duplicate identity: 0건
- processing duplicate observation: 0건
- Redis dedupe 재처리: 0건
- 초기 failover backlog peak: 1건으로 추론. B consumer 비활성 상태에서 offset 37에 한 건을 발행했다.
- 초기 backlog 회복: consumer start command 후 첫 MySQL 저장까지 8.420272초
- post-failover burst의 보수적 안정 확인: 마지막 HTTP 완료 후 약 35초 이내, 최종 Kafka lag=0/Redis PEL=0/Redis lag=0
- DLT: 0건
- quarantine: 0건
- rejected/not accepted: 0건
- 최종 B identity: 41
- 최종 MySQL unique identity: 41
- unaccounted: 0건
- 최종 분류: fault 전 persisted 30건, B에 직접 발행되어 failover 후 persisted 11건

`RPO exposure=0`은 이 Material Run의 관측 결과다. 마지막 A 요청과 fault 사이 20초 때문에 복제 중인 레코드를 fault로 절단한 시험은 아니며, 일반적인 zero-RPO 보장을 의미하지 않는다.

## 9. Failure Signature 평가

| Signature | 평가 | 근거와 해석 |
|---|---|---|
| FS-1 Whole Cluster A Unavailability | PASS | `evidence/BIP-FR-006-MR-20260923T042048Z/03-fault-and-unavailability.txt`: controller와 broker 3개 정지, B/Redis/MySQL healthy |
| FS-2 Primary Responsibility Failure | PASS, 제한 있음 | A Kafka 구성요소 전체의 독립적 unavailable 확인. 다만 fault 후 A HTTP 요청을 별도로 발생시키지는 않았다. |
| FS-3 DR Data Availability | PASS | `evidence/BIP-FR-006-MR-20260923T042048Z/04-b-boundary.txt`: A accepted 30건 모두 B에 존재, B group offset 37, active member 없음 |
| FS-4 DR Responsibility Transfer | PASS | `evidence/BIP-FR-006-MR-20260923T042048Z/11-final/33-app-logs.txt`, `evidence/BIP-FR-006-MR-20260923T042048Z/09-b-processing-start-and-first-consumption.log`, `evidence/BIP-FR-006-MR-20260923T042048Z/10-mysql-after-first-b.tsv` |
| FS-5 End-to-End Failover Accountability | PASS | `evidence/BIP-FR-006-MR-20260923T042048Z/traffic-manifest.tsv`, `evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/`, 최종 group/Redis/MySQL Evidence로 RTO/RPO/identity disposition 도출 |

## 10. 실험 유효성

`PASS`

RC-R1, 승인된 A=3/B=1 topology, 정상 baseline, MM2 replication/offset continuation, pre-failover B consumer 비활성, A에 한정된 fault, B/Redis/MySQL의 지속 가용성, 설명 가능한 B start offset, 일관된 timestamp, identity-level reconciliation을 모두 충족했다. fallback topology나 Material Run 중 설계 변경은 없었다.

## 11. Evidence 충분성

`PARTIAL`

핵심 failover 메커니즘, offset 경계, RTO와 최종 식별자 정합성은 직접 입증됐다. 다만 다음 제약으로 RPO stress evidence와 운영 관측 범위는 제한된다.

- 마지막 pre-fault 요청 완료와 fault 사이 20초 공백
- fault 후 A-targeted HTTP 실패를 별도 probe하지 않음
- 전용 MM2 런타임이 REST connector status endpoint를 제공하지 않아 process/log/internal topic/offset으로 대체
- checkpoint/offset-sync raw record formatter가 이미지에 없어 target group offset과 실제 start position으로 검증

## 12. 검증된 재현 주장과 제한

검증된 재현 주장(Verified Reproduction Claim)은 다음 범위로 한정한다. 같은 호스트의 bounded local Active/Passive Kafka DR topology에서 Primary Cluster A 전체를 사용할 수 없게 만들었고, MirrorMaker 2가 Cluster B로 데이터를 복제한 상태에서 producer 책임을 B로 명시적으로 이전했다. B consumer가 설명 가능한 offset 경계에서 이어서 처리하고 Processing → Redis → MySQL 경로가 재개됨을 확인했다. 이 과정의 Observed Failover RTO와 관측된 RPO exposure를 측정했으며, 최종 논리 식별자 정합성은 `unaccounted=0`으로 완료됐다.

이 주장은 다음 제한을 모두 가진다.

- 같은 호스트의 Docker topology이며 물리적 장애 영역 격리를 검증하지 않았다.
- Cluster B는 single broker이며 DR cluster의 HA 검증 대상이 아니다.
- failover는 명시적·수동 운영 절차이며 자동 failover가 아니다.
- checkpoint interval과 장애 시점에 따라 replay 또는 노출 창이 생길 수 있다.
- exactly-once failover를 주장하지 않는다.
- 관측된 `RPO exposure=0`은 이 실행의 결과일 뿐 zero-RPO를 보장하지 않는다.
- 마지막 pre-fault traffic과 fault 사이 약 20초의 quiet window로 RPO stress 경계가 약화됐다.
- fault 후 Cluster A를 대상으로 한 HTTP 실패는 독립적으로 시험하지 않았다.
- 실제 multi-DC/multi-region DR 결과가 아니다.
- RTO는 이 로컬 운영 절차의 관측값이며 production RTO가 아니다.
- Evidence Sufficiency는 `PARTIAL`이다.

## 13. 선택적 오케스트레이션 로컬 시험

- directive 이후 Human engineering decision: 0
- manual Human command relay: 0
- AI execution interruption: 2개 유형
  1. canonical repository가 초기 sandbox write root 밖에 있어 파일/Git 작업에 환경 승인이 필요했다.
  2. Docker socket 접근에 환경 승인이 필요했다. 승인 대기로 마지막 pre-fault 요청과 fault 사이 20초 공백이 발생했다.
- 단일 Codex 실행 책임으로 구현→preflight→Material Run→Evidence packaging: 완료
- 책임/권한 모호성: 초기 current working directory와 명시된 target repository 경로가 달랐다. 실행 중인 Docker label, 기대 branch와 기준 HEAD를 대조하여 이 문서가 포함된 저장소를 canonical target으로 확정했다.

승인 UI는 실행 환경의 Tool Permission Prompt이며 사람 승인 관문(Human Gate), Engineering decision 또는 command relay로 집계하지 않았다. 즉, `Human Gate ≠ Tool Permission Prompt`다.

## 14. 주요 Evidence 경로

- `evidence/PREFLIGHT-20260923T032348Z/`
- `evidence/BIP-FR-006-MR-20260923T042048Z/00-run-registration.txt`
- `evidence/BIP-FR-006-MR-20260923T042048Z/traffic-manifest.tsv`
- `evidence/BIP-FR-006-MR-20260923T042048Z/03-fault-and-unavailability.txt`
- `evidence/BIP-FR-006-MR-20260923T042048Z/04-b-boundary.txt`
- `evidence/BIP-FR-006-MR-20260923T042048Z/07-producer-switch.txt`
- `evidence/BIP-FR-006-MR-20260923T042048Z/08-consumer-switch.txt`
- `evidence/BIP-FR-006-MR-20260923T042048Z/09-b-processing-start-and-first-consumption.log`
- `evidence/BIP-FR-006-MR-20260923T042048Z/10-mysql-after-first-b.tsv`
- `evidence/BIP-FR-006-MR-20260923T042048Z/11-final/`
- `evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/`

## 15. 종료 검증

- 검증 시각: `2026-09-23T06:47:12Z`
- 종료 명령 경계: FR-006 Compose 프로젝트에만 `down --remove-orphans` 적용, `-v` 미사용
- 컨테이너: FR-006 application/MM2/Kafka/Redis/MySQL container 잔존 없음
- 네트워크: FR-006 전용 network 3개 제거 완료
- 볼륨: Kafka A/B, Redis, MySQL의 FR-006 named volume 7개 의도적 보존
- artifact hygiene: 설정·스크립트·Preflight Evidence·Material Run Evidence·정합성 자료를 보존했고, 삭제 대상인 임시 파일·캐시·credential은 발견되지 않음
- 문서 링크와 Evidence locator: closure 검증 통과
- Git 동기화: commit/push/merge 미수행
