# README 반영 후보 — Kafka cluster 전체 장애와 DR failover

> 상태: `HUMAN CONFIRMED — README INTEGRATION PENDING`
> 이 문서는 portfolio 설명의 초안이다. 루트 `README.md` 반영은 별도 책임에서 수행하며, 통합 시 상대 링크를 새 위치에 맞게 조정한다.

## Kafka cluster 전체 장애와 DR failover

브로커 한 대의 장애는 같은 Kafka cluster 안의 복제본과 새 leader로 넘길 수 있다. 그러나 primary Kafka cluster 전체가 불가하면 그 cluster 안에 broker를 더 둔 것만으로는 메시지 처리 경로가 돌아오지 않는다. 이 검증은 **cluster 바깥에 어떤 상태가 미리 있어야 하는지, 생산·소비 책임을 어떻게 넘기며, 무엇을 확인해야 복구 완료라고 할 수 있는지**를 다뤘다.

같은 호스트의 로컬 Docker에서 controller 1개와 broker 3개로 구성한 Primary Cluster A, 별도 single broker/controller의 DR Cluster B를 만들었다. MirrorMaker 2가 A의 application topic과 소비 연속성 정보를 B로 단방향 복제했다. A 전체를 중단한 뒤 A application 책임을 정지하고 B producer와 consumer를 명시적으로 활성화했다.

| 검증 경계 | 관측 결과 |
|---|---:|
| A 전체 불가 → B 첫 producer acknowledgement | `103.613초` |
| A 전체 불가 → 첫 post-failover MySQL 저장, Observed Failover RTO | `181.420272초` |
| 관측된 RPO exposure / replay / B transport duplicate identity | `0 / 0 / 0건` |
| B consumer 연속 시작 | partition 1, offset 37 |
| 수용·최종 MySQL 고유 식별자 / 미설명 식별자 | `41 / 41 / 0건` |

B에 레코드가 복제돼 있어도 소비자가 이어서 읽을 위치와 이전 처리 결과를 확인하지 않으면 안전한 전환을 선언할 수 없다. 이번 실행은 MM2 internal topic, B의 target group offset과 실제 consumer 시작 위치로 연속성을 확인하고, Processing → Redis → MySQL의 최종 식별자까지 대사했다. raw checkpoint record를 직접 해석한 결과는 아니다. 결과 판정은 `REPRODUCED`, 실험 유효성은 `PASS`, Evidence 충분성은 `PARTIAL`이다.

이 결과는 **같은 호스트의 제한된 로컬 DR 메커니즘 검증**이다. B는 single broker이고 failover는 수동이다. 마지막 A 요청과 fault 사이 약 20초가 있어 복제 중인 레코드의 RPO 경계를 강하게 시험하지 못했다. 실제 multi-DC/multi-region DR, 자동 failover, DR cluster HA, production RTO, zero-RPO 또는 exactly-once failover를 주장하지 않는다. 세부 판정은 [재현 기록](./REPRODUCTION-RECORD.md)에 보존돼 있다.
