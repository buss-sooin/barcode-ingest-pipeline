# BIP-FR-006 재현 계약

## 계약 식별자

- Contract ID: `BIP-FR-006-RC`
- Contract Revision: `BIP-FR-006-RC-R1`
- Human Decision: `HG-FR006-01 — PASS`
- Scenario: `Kafka Cluster-Wide Unavailability & DR Failover`

## 공학적 목적과 주장 경계

이 계약은 같은 호스트의 Docker 환경에서 Cluster A 전체 장애와 Cluster B로의 명시적 책임 이전을 실행하여, Active/Passive Kafka 재해 복구(Disaster Recovery) 메커니즘과 관측된 RPO/RTO를 제한적으로 검증한다.

포함 범위는 Cluster A 전체 중단, MirrorMaker 2 기반 A→B 단방향 복제, producer/consumer 책임 이전, 논리 식별자 단위 RPO 노출, 관측된 RTO, replay/duplicate/backlog, 최종 MySQL·DLT 정합성이다.

다음 주장은 범위 밖이다.

- 실제 multi-DC 또는 multi-region DR
- 물리적 장애 영역(Failure Domain) 격리
- production-scale DR
- 자동 failover
- Cluster B의 HA
- zero-RPO 또는 zero-RTO
- exactly-once failover

## 고정 토폴로지

- Cluster A: KRaft dedicated controller 1개, broker 3개, application topic RF=3, `min.insync.replicas=2`
- Cluster B: combined broker/controller 1개, application topic RF=1
- MirrorMaker 2: A→B only, `IdentityReplicationPolicy`
- 복제 데이터: `barcode-events`, `barcode-events-dlt`
- 연속성 데이터: `barcode-processing-group` checkpoint/translated offset
- 공유 하위 시스템: Redis, persistence worker, MySQL
- failover: 환경 설정으로 A/B 애플리케이션 인스턴스를 명시적으로 전환

Cluster B는 DR 메커니즘 시험 대상일 뿐이며 HA cluster로 해석하지 않는다. Java production source 변경과 승인되지 않은 fallback topology는 허용하지 않는다.

## 정량 정의

- Publication Recovery = `t_B_publish - t_A_unavailable`
- Observed Failover RTO = `t_B_e2e - t_A_unavailable`
- RPO exposure identities = `A publish acknowledgement가 확인된 pre-fault 식별자 - B에 확인된 식별자 - 이미 downstream에 durable하게 완료된 식별자`

RPO는 raw source/target offset의 단순 차가 아니라 checkpoint 경계와 논리 식별자로 계산한다. RPO 노출은 잠재 노출 창이며 최종 데이터 손실과 동일하지 않다.

## 유효성 경계

Material Run은 RC-R1, 정상 A/B baseline, MM2 복제 및 offset continuation, failover 전 B consumer 비활성, A만을 대상으로 한 fault, B/Redis/MySQL 지속 가용성, 설명 가능한 B consumer 시작 위치, 일관된 timestamp와 최종 식별자 정합성이 모두 확인되어야 유효하다.

## Material Run 연결

- 적용 Material Run: `BIP-FR-006-MR-20260923T042048Z`
- 정본 실행·판정 기록: [재현 기록](./REPRODUCTION-RECORD.md)
- 등록 Evidence: `evidence/BIP-FR-006-MR-20260923T042048Z/00-run-registration.txt`
