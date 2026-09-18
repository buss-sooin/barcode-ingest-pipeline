# README 반영 후보 — Kafka 동기화 복제본 부족 시 쓰기 보호

> 상태: `HUMAN CONFIRMED — README INTEGRATION PENDING`
> 기준: `main`의 현재 루트 `README.md` 문체·설명 깊이·Mermaid·결과 표·제한 표현을 따른다.
> 주의: 루트 `README.md`에는 아직 반영하지 않는다.

## Kafka 동기화 복제본 부족 시 쓰기 보호

Kafka를 브로커 3대와 파티션별 복제본 3개로 구성해도, 장애 중 모든 복제본이 최신 상태를 유지하는 것은 아닙니다. 이 프로젝트는 동기화 복제본 집합(ISR)이 2개 이상일 때만 쓰기를 성공으로 승인하도록 `min.insync.replicas=2`와 producer `acks=all`을 함께 적용했습니다.

**설계 경계**

- 복제본 3개 중 최소 2개가 ISR에 있을 때만 새 쓰기 성공
- 최신 상태가 보장되지 않는 replica의 leader 승격 차단
- 복제 안전성을 충족하지 못하면 leader가 살아 있어도 쓰기 거부
- 이탈한 replica가 복구되면 설정 완화 없이 쓰기 재개

**장애와 검증**

바코드 요청이 계속 들어오는 동안 현재 leader broker를 중단해 clean leader election과 ISR 3→2를 만들었습니다. 새 leader가 안정된 상태에서는 쓰기가 성공했습니다. 이어서 새 leader는 살려 둔 채 남은 follower 하나를 추가로 중단해 ISR을 1로 낮추자, 새 요청이 HTTP 503과 `NotEnoughReplicasException`을 남기며 거부됐습니다.

```mermaid
flowchart LR
  A[정상<br/>leader 존재·ISR 3] --> B[기존 leader 중단]
  B --> C[새 leader 선출<br/>ISR 2·쓰기 가능]
  C --> D[남은 follower 추가 중단]
  D --> E[leader 존재·ISR 1<br/>쓰기 거부]
  E --> F[follower 복구<br/>ISR 2·쓰기 회복]
  F --> G[전체 broker 복구<br/>ISR 3·정합성 수렴]
```

Leader 존재 여부와 안전한 쓰기 가능 여부가 서로 다른 상태임을 확인한 흐름입니다.

| 확인 항목 | 결과 |
| :--- | :--- |
| 내구성 경계 | RF 3, `min.insync.replicas=2`, producer `acks=all` |
| ISR 2 | 새 쓰기 HTTP 200, Kafka acknowledgment 확인 |
| ISR 1 | Leader는 유지됐지만 HTTP 503, `NotEnoughReplicasException`, offset 불변 |
| 기능 복구 | Follower 복구로 ISR 2가 되자 설정 변경 없이 새 쓰기 성공 |
| 전체 복구 | 모든 partition ISR 3, 복제 부족·사용 불가 partition 0 |
| 최종 정합성 | 논리 입력 54건 = MySQL 고유 저장 53건 + 직접 확인된 거부 1건 |
| 중복 | Kafka transport duplicate 1건, 최종 business duplicate 0건 |

이 결과는 Kafka가 가용성을 위해 내구성 조건을 자동으로 낮추지 않는다는 점을 보여줍니다. 운영에서는 broker process와 leader 존재만 확인해서는 부족하며, partition별 ISR, topic의 `min.insync.replicas`, producer `acks`를 함께 봐야 합니다. 또한 ISR이 2로 회복돼 쓰기가 재개된 시점과, 전체 ISR·consumer lag·Redis PEL·최종 데이터가 수렴한 복구 완료 시점을 구분해야 합니다.

이번 검증은 전용 controller가 유지된 로컬 환경의 제한된 실행 결과입니다. Controller 장애, 세 번째 broker 장애, network partition, disk 손실·손상, 운영 환경의 SLA·RTO/RPO, 모든 Kafka/client 버전의 동일 동작과 exactly-once 처리를 보장하지는 않습니다.

## 통합 메모

`main`의 현재 루트 README는 성능, 장애 전파, 유실, 중복 검증을 중심으로 구성돼 있으며 아직 별도의 운영 장애 검증 절이 없다. 따라서 이 Draft를 그대로 추가하기 전에 FR-001·FR-002·FR-003을 묶는 상위 “운영 장애 검증” 절과 목차 항목을 먼저 둘지, FR-003만 독립 절로 둘지 결정해야 한다.

이 문서는 FR-003 설명 후보만 제공하며 루트 README의 통합 구조를 확정하지 않는다.
