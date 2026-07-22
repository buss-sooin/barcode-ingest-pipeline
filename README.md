# 🚀 대규모 트래픽 분산 처리를 위한 비동기 Kafka/Redis Streams 파이프라인 구축

본 문서는 Kafka와 Redis Streams를 활용하여 **고성능 데이터 수집**을 달성하는 동시에, 시스템 장애 발생 시 **데이터의 무결성 (Integrity)과 순서 (Ordering)** 를 보장하는 핵심 메커니즘을 설명합니다.

---

## I. 🎯 프로젝트 개요 및 핵심 문제 정의

### 1.1. 프로젝트 요약: 아키텍처 진화와 고성능 인제스트 파이프라인

**\[모듈러 모놀리스 진화\] 피크 부하(Peak Load) 처리에 최적화된 고성능 바코드 인제스트 파이프라인 구축**

Kafka와 Redis Streams 기반의 비동기 부하 분산 아키텍처를 도입하여 **기존 동기식 DB 병목 현상과 시스템 동시성 (Concurrency) 문제**를 해결하고, 대규모 물량 처리 환경에 적합한 **Exactly-Once 논리**를 보장하는 견고한 시스템을 구축했습니다.

---

### 1.2. ⚡ 문제 착수 동기: 4시간의 물류 대기 시간

본 프로젝트는 전 직장 **팀프레시 새벽 배송** 팀 근무 당시 겪었던 심각한 운영 이슈에서 비롯되었습니다.

* **문제 상황:** 고객사 프로모션 및 명절 등 **피크 부하 (Peak Load)** 시점에 대량의 바코드 스캔 데이터가 유입되면서, 기존 **배송 모놀리스 시스템의 자원 사용량이 임계치를 초과**했습니다.
* **치명적 결과:** 동기식으로 설계된 모놀리스의 DB 처리 지연이 **물류 센터의 바코드 스캔 스케줄러까지 묶어두면서** 최종적으로 **최대 4시간에 달하는 물류 작업 대기 시간**을 발생시켰습니다. 이는 새벽 배송의 생명인 **정시성**을 심각하게 위협하는 핵심 장애 요인이었습니다.
* **문제 의식:** 이 문제의 근본 원인을 **동기식 I/O 결합 (Synchronous Coupling)** 에서 찾았으며, 시스템의 처리량 (Throughput)과 안정성을 개선하기 위해 아키텍처 전환을 추진했습니다.

---

### 1.3. 기술적 문제 정의 및 목표

| 구분 | 문제점 (기존 아키텍처) | 해결 목표 (신형 아키텍처) |
| :--- | :--- | :--- |
| **병목 원인** | `delivery-monolith`의 **동기식 DB 커밋 대기** 및 스레드 Blocking | **비동기 핸드오프 (Handoff)** 를 통한 Latency 분리 |
| **시스템 부하** | DB I/O Latency에 따른 API 서버의 **동시성 저하** 및 자원 고갈 | **DB 부하 분산** 및 **Batch Insert**를 통한 I/O 효율성 극대화 |
| **데이터 무결성** | 분산 환경 전환 시 **메시지 중복 및 유실** 위험 | **Exactly-Once 논리** 및 **장애 복구 메커니즘** 구축 |

---

### 1.4. 아키텍처 개념 (Modular Monolith Rationale)

* **설계 접근:** 본 프로젝트는 **'바코드 인제스트' 도메인**만을 분리하여 고성능 파이프라인으로 재구성했습니다.
* **개념적 배경:** API(`barcode-ingest-service`)와 DB 처리(`barcode-persistence-worker`)를 **Kafka/Redis 기반의 메시지**로 분리하여 **기능적 모듈화**를 달성했습니다. 이는 모놀리스의 안정성을 유지하며 특정 기능을 고도화하는 **모듈러 모놀리스 (Modular Monolith)** 의 진화적 장점을 구현한 사례입니다.
    

---
---

## II. 📉 기존 동기식 아키텍처 분석 및 비효율성 증명

### 2.0. 분석 대상 아키텍처 재현 범위 (Disclaimer)

본 챕터에서 분석하는 구형 아키텍처 코드는 퇴사 후 **아키텍처 관점의 문제점 및 병목 구간**을 증명하기 위해 **기억과 경험에 의존하여 재현한 프로젝트**입니다. 모든 디테일한 기능이 복원된 것은 아니며, **동기식 결합 (Synchronous Coupling)** 으로 인한 Latency 폭증 문제를 유발했던 **핵심 구조 및 로직**에 초점을 맞춰 증명에 사용되었음을 미리 밝힙니다.

---

### 2.1. 동기식 I/O 결합 (Synchronous Coupling)의 구조적 문제

기존 아키텍처는 `barcode-scheduler` (클라이언트)가 **[구형 아키텍처](https://github.com/buss-sooin/barcode-old-pipeline)** (API)를 호출하고, Monolith가 DB에 **데이터를 저장하고 커밋이 완료될 때까지** 응답을 대기하는 전형적인 동기식 구조였습니다.
<img width="766" height="345" alt="Image" src="https://github.com/user-attachments/assets/ecf6aaf1-d958-440c-a0e7-8d20d7e9c19a" />

* **문제의 본질:** **배송 모놀리스** 내의 DB 접근 코드는 **트랜잭션 커밋 완료** 시점까지 HTTP 요청을 처리하는 스레드를 **Blocking** 했습니다. 이는 DB의 쓰기 Latency (지연)가 곧바로 클라이언트의 API 응답 시간으로 전이되는 구조적 결함이었습니다.
* **운영적 결과:** 이 구조적 결함이 챕터 I에서 언급된 **'4시간의 물류 작업 대기 시간'** 을 유발한 근본 원인이었습니다.

---

### 2.2. 정량적 데이터를 통한 비효율성 입증

JMeter를 통해 동일한 부하 환경을 조성하고 Prometheus/Grafana로 모니터링한 결과, 기존 동기식 아키텍처의 비효율성은 다음 두 가지 핵심 지표에서 명확하게 드러났습니다.

#### 1. Latency 개선 효과: API 스레드 I/O 대기 시간 제거 증명

<img width="1411" height="623" alt="Image" src="https://github.com/user-attachments/assets/8a339dfe-9000-4dcf-92e7-7baa2dee7ee3" />

**(그래프 해석: **Ingest Service** (신형 아키텍처 API)와 `delivery-monolith` (구형 아키텍처 API)의 평균 응답 시간을 비교함.)**

* **지표:** API 평균 응답 시간
* **결과:** 구형 아키텍처는 평균 **27.97ms**에 달했으나, 신형 아키텍처는 평균 **6.22ms**로 측정되어 **약 4.5배** 성능이 개선되었습니다.
* **기술적 의미:**
    * **동시성 개선의 핵심 근거:** 구형 시스템에서 API 응답 시간의 대부분은 DB I/O를 기다리는 **스레드 Blocking 시간**이었습니다. 비동기 구조로 전환하여 이 Blocking 시간 (약 $\mathbf{21.75 \text{ms}}$)을 응답 경로에서 **완전히 제거**함으로써, API 스레드가 즉시 풀에 반환되어 **서버의 동시 요청 처리 능력 (Concurrency)** 이 I/O 제약에서 해방되었음을 입증합니다.

#### 2. DB 물리적 I/O 효율성 증대: Batch Insert 효과

<img width="1414" height="627" alt="Image" src="https://github.com/user-attachments/assets/c72e00bd-d741-4e48-ac80-71278d8983e4" />

**(그래프 해석: **Persistence Worker** (신형 아키텍처)의 DB 부하와 `delivery-monolith` (구형 아키텍처)의 DB 부하를 비교함.)**

* **지표:** `rate(mysql_global_status_innodb_data_writes{job="mysql_central"}[1m])` (초당 데이터 쓰기 횟수)
* **결과:** 구형 DB의 평균 Data Writes 횟수 (**46.58 QPS**)가 신형 DB (**12.21 QPS**) 대비 **약 73.7%** 절감되었습니다.
* **기술적 의미:** 비동기 Worker의 **Batch Insert 최적화** 전략이 성공적으로 적용되어, 요청 하나당 발생하던 비효율적인 물리적 Disk I/O 부하를 획기적으로 줄여 DB 리소스 효율성을 높였음을 증명합니다.

---

### 2.3. Batch Insert를 넘어선 Decoupling (결합 해제)의 가치 (Concurrency Resiliency)

일반적으로 DB 성능 개선을 위해 **Batch Insert**를 구형 아키텍처에 적용할 수 있으며, 이는 **물리적 I/O 횟수**를 줄여 Latency를 부분적으로 개선합니다. 그러나 이는 구조적 결함을 해결하지 못합니다.

* **구형 시스템의 취약점:** Batch Insert를 사용하더라도, DB 트랜잭션 처리 중 발생하는 **예외적인 I/O 지연 시간**은 **API 스레드에 그대로 전이**되어 Latency와 Concurrency를 불안정하게 만듭니다. **피크 부하 시 스레드 스타베이션 (Thread Starvation)** 의 위험은 여전히 존재합니다.
* **신형 시스템의 강점:** 비동기 아키텍처는 **DB의 성능 변동성**으로부터 API 서버를 완전히 격리합니다. API 서버의 응답 시간은 오직 메시징 시스템 (Kafka/Redis)의 Latency에만 의존하며, 이는 **DB Latency 대비 수 배 빠른 속도**로 안정적입니다.

따라서, 성능 개선뿐만 아니라 **시스템의 근본적인 안정성 (Resiliency)** 을 확보하기 위해 **Decoupling**은 필수적인 **아키텍처적 전환점** 이었습니다.

---
---

## III. 🏗️ 신형 비동기 아키텍처 설계 및 구현

### 3.1. 아키텍처 다이어그램 (신형 인제스트 파이프라인)

신형 아키텍처는 **Decoupling**과 **비동기 부하 분산**을 핵심 목표로 설계되었습니다. 바코드 데이터는 API Gateway를 거쳐 Ingest Service로 유입된 후, DB 작업과는 완전히 분리되어 Worker에 의해 비동기적으로 처리됩니다.

<img width="905" height="208" alt="Image" src="https://github.com/user-attachments/assets/47d36277-1185-4b4c-8a5e-6462e41a52b9" />

**(참고:** 성능 시뮬레이션은 API Gateway와 NGINX의 부하를 제외하고 Ingest Service부터 Worker까지의 순수 처리 성능을 측정하는 데 집중했습니다. **API Gateway (Spring Cloud Gateway)** 는 로컬 환경의 자원 제약으로 인해 성능 고려 사항에서 제외되었습니다.)

---

### 3.2. 핵심 컴포넌트 역할 및 데이터 흐름

신형 아키텍처는 **Ingest Service, Kafka, Redis Streams, Persistence Worker**의 네 가지 핵심 논리적 컴포넌트로 구성됩니다.

| 컴포넌트 | 역할 | 기술적 의의 |
| :--- | :--- | :--- |
| **Ingest Service** | 외부 요청 수신 및 **즉시 Kafka로 전달 (Handoff)** | API Latency를 DB I/O에서 분리하여 **Blocking 시간을 제거** |
| **Kafka** | 대규모 트래픽의 **1차 Queue 역할** 및 데이터 유실 방지 | High Throughput 및 영구 보존 (Persistence)을 통한 **최초 데이터 무결성** 보장 |
| **Processing Service** | Kafka Consumer로서 메시지를 읽어 Redis Streams에 기록 | **중복 메시지 필터링 (Redis Set 활용)** 및 Streams를 통한 **세분화된 분배** |
| **Redis Streams** | Worker 간의 **메시지 분배 및 순서 보장** 역할 | Consumer Group 기능을 통해 **XACK/XCLAIM 기반의 장애 복구 메커니즘** 구현 |
| **Persistence Worker** | Redis Streams로부터 메시지를 읽어 DB에 저장 | DB Batch Insert를 수행하여 **물리적 I/O 횟수를 절감**하고 효율 극대화 |

### 3.3. 주요 데이터 흐름 (Decoupling 상세)

1.  **Ingest (Decoupling):** Scanner 요청 → (Nginx/Gateway) → **Ingest Service**는 DB 커밋 대기 없이, 수신한 바코드 데이터를 고속으로 Kafka에 메시지 생산 (Produce) 후 클라이언트에게 **즉시 응답을 반환**하여 I/O Latency를 분리합니다. (평균 응답 시간: $\mathbf{6.22 \text{ms}}$)
2.  **Queueing (Isolation):** Kafka에 쌓인 메시지는 **Processing Service**로 전달됩니다.
3.  **Distribution (Ordering/Resiliency):** Processing Service는 메시지를 Redis Streams에 기록하며, Streams는 Consumer Group 기능을 통해 **다수의 Persistence Worker**에게 메시지를 병렬적으로 분배합니다.
4.  **Persistence (Efficiency/Idempotency):** Worker들은 Streams에서 메시지를 읽어 **Batch Insert**로 DB에 저장하고, 저장 성공 시 `XACK`으로 승인합니다. 이 과정에서 **DB의 Unique Index**를 활용하여 데이터의 **최종 멱등성 (Exactly-Once 논리)** 을 보장합니다.

---
---

## IV. 🔑 기술적인 고찰: 데이터 무결성 및 복구 메커니즘

비동기 분산 시스템의 가장 큰 도전 과제는 **데이터의 무결성 (Integrity)** 과 **Exactly-Once 논리**를 보장하는 것입니다. 처리량 (Throughput) 개선을 넘어, 장애 발생 시 데이터 손실이나 중복 없이 작업을 지속할 수 있도록 다음과 같은 다중 안전장치를 설계하고 구현했습니다.

### 4.1. 멱등성 (Idempotency) 달성을 위한 핵심 매커니즘

장애 복구 로직은 각 단계가 상호작용하여 최종적으로 데이터베이스에 단 하나의 레코드만 저장됨을 보장하는 **"Exactly-Once 논리"** 를 달성하는 것을 목표로 합니다.

| 매커니즘 | 관련 시스템 | 핵심 로직 | 보장되는 사항 |
| :--- | :--- | :--- | :--- |
| **순서 보장 (Ordering)** | **Redis Streams (단일 파티션)** | Kafka의 데이터는 단일 Redis Streams 파티션에 저장되며, Worker들은 **단일 Consumer Group**으로 이 파티션을 처리합니다. | **[데이터 순서]** Kafka에 기록된 순서대로 Redis Streams를 통해 Worker에게 전달됨을 보장합니다. |
| **메시지 추적 (Tracking)** | **Redis Streams (Message ID)** | Redis Streams의 고유 메시지 ID (`Stream_ID`)를 사용하여 **어디까지 처리했는지**를 정확히 추적합니다. | **[처리 위치]** Worker의 작업 경계가 명확히 식별되어 정확한 지점부터 재처리가 가능합니다. |
| **장애 복구 (Delivery)** | **Redis Streams (XACK, XCLAIM)** | Worker가 메시지 처리를 완료하면 **`XACK`**을 보내고, 정해진 시간 동안 승인되지 않은 메시지는 **`XCLAIM`**을 통해 다른 Worker에게 재할당되어 **재처리**됩니다. | **[최소 1회 처리]** 시스템 장애 발생 시에도 메시지가 **최소 한 번 이상** 처리되도록 보장합니다. |
| **중복 방지 (멱등성)** | **DB Unique Index** | JPA 저장 시 **`internalBarcodeId`** 컬럼에 **UNIQUE 인덱스**를 설정하여 DB 수준에서 **중복 저장을 원천 차단**합니다. | **[최종 보장]** 재전송된 메시지가 DB에 도달하더라도, DB의 **UNIQUE 제약 조건**이 두 번째 쿼리를 **실패 (무시)** 시키므로, 최종적으로 **데이터는 한 번만 저장됨**을 보장합니다. |

### 4.2. 멱등성 보장 상호작용 및 결론

시스템은 메시징 계층에서 **"최소 1회 처리 (At-Least-Once)"** 를 목표로 장애 상황에 적극적으로 대응하고, 영속성 계층에서 **"정확히 1회 처리 (Exactly-Once 논리)"** 를 최종적으로 확정합니다.

* **메시징 계층 (Redis Streams):** Worker 장애 시 `XCLAIM` 기능을 통해 미처리 메시지를 정확히 파악하여 안전한 **재전송을 유도**합니다.
* **영속성 계층 (DB Unique Index):** 재전송 과정에서 발생할 수 있는 중복 메시지를 **데이터베이스의 고유 제약 조건**으로 필터링하여, 데이터 손상을 방지하고 최종 데이터 무결성을 유지합니다.

### 4.3. 장애 시나리오 및 복구 분석

핵심 서비스의 일시적인 다운 (2~3시간 이내) 및 복구 상황에 대한 복구 메커니즘 동작을 분석했습니다.

| 시나리오 | 발생 장애 | 복구 메커니즘 동작 | 데이터 무결성 결과 |
| :--- | :--- | :--- | :--- |
| **Ingest Worker 다운** | Worker가 처리 도중 다운되어 **`XACK`을 보내지 못한** 메시지 발생. | **재시작 후 `XCLAIM`:** Worker 재시작 시, Pending Entry List를 확인하여 `XCLAIM`을 통해 메시지를 가져와 **재처리**를 시도합니다. | DB Unique Index를 통해 데이터 중복 없이 **누락된 처리만 안전하게 완료**됩니다. |
| **Redis Streams 다운** | Ingest API가 데이터를 쓸 수 없고, Worker가 메시지를 읽을 수 없는 상태. | **API 중단 및 복구 대기:** Ingest API는 DB 대신 Redis에 의존하므로 503 오류를 반환하며 작업을 중단하고 대기합니다. | 모든 데이터는 **Kafka에 안전하게 보존**되어 있어, Redis 복구 후 Ingest API가 Kafka로부터 데이터를 다시 가져와 Streams에 기록함으로써 **데이터 손실 없이** 작업이 재개됩니다. |
| **MySQL DB 다운** | Worker가 데이터를 DB에 저장하지 못하고 트랜잭션 실패. | **트랜잭션 실패 & 메시지 재처리:** DB 트랜잭션 실패 시 Worker는 `XACK`을 보내지 않고 다운됩니다. Worker 재시작 시 `XCLAIM`으로 재처리됩니다. | DB 복구 후 재처리된 메시지는 DB Unique Index를 통해 안전하게 저장되므로 **데이터 손실은 발생하지 않습니다.** |

---
---

## V. 📈 정량적 성과 분석 및 기술적 의미 해석

본 프로젝트는 구조적인 **동기식 결합 (Coupling)** 을 해소하고 비동기 기반의 인제스트 파이프라인을 구축함으로써, 근본적인 동시성 문제였던 **'4시간의 물류 대기 시간'** 문제를 성공적으로 해결했음을 정량적 지표를 통해 입증합니다.

### 5.1. 핵심 지표별 성과 요약

| 지표 | 구형 동기식 아키텍처 | 신형 비동기 아키텍처 | 개선율 | 기술적 기여 |
| :--- | :--- | :--- | :--- | :--- |
| **API 평균 응답 시간 (Latency)** | **27.97ms** | **6.22ms** | **약 4.5배 개선** | 스레드 Blocking 시간 (I/O 대기) 제거를 통한 동시성 (Concurrency) **개선 효과** |
| **DB 물리적 I/O (평균 QPS)** | **46.58 QPS** | **12.21 QPS** | **약 73.7% 절감** | Persistence Worker의 Batch Insert 전략 성공적 적용 및 DB 부하 절감 |

### 5.2. 기술적 의미 해석

#### 1. Concurrency (동시성) 및 Throughput (처리량) 개선 효과

가장 결정적인 성과는 **API Latency를 4.5배 단축**시킨 것입니다. 이는 DB I/O ($\approx \mathbf{21.75 \text{ms}}$)를 기다리느라 낭비되던 API 스레드의 대기 시간을 Kafka로의 **핸드오프 (Handoff)** 로 대체했음을 의미합니다. 결과적으로, API 서버의 동시 요청 처리 능력이 DB 성능 제약에서 벗어나게 되었으며, 이는 피크 부하 시에도 안정적인 대용량 트래픽 처리가 가능함을 뜻합니다.

#### 2. Resiliency (시스템 안정성) 확보 및 위험 분리

새로운 아키텍처는 DB의 성능 변동성으로부터 API 서버를 완전히 격리함으로써 시스템의 **안정성 (Resiliency)** 을 근본적으로 확보했습니다. DB에 장애가 발생하더라도, Ingest Service는 Kafka에 데이터를 계속 쌓으며 6.22ms의 안정적인 응답 시간을 유지합니다. **DB Layer와 API Layer의 장애 도메인이 분리**되어 한 쪽의 문제가 전체 시스템 마비로 이어지는 위험을 제거했습니다.

#### 3. 모듈형 아키텍처의 확장성 기여

'바코드 인제스트' 도메인만을 모듈화하고 비동기 파이프라인으로 분리함으로써, 해당 도메인의 성능 개선이 다른 모놀리스 서비스에 미치는 영향을 최소화했습니다. 이는 향후 트래픽 증가에 따라 Ingest Service나 Persistence Worker의 인스턴스만 독립적으로 확장할 수 있는 **수평적 확장성 (Horizontal Scalability)** 을 확보한 중요한 **아키텍처적 진전**입니다.

### 5.3. 💡 단순 계산의 함정과 아키텍처적 이점 고찰 (실질적인 개선 효과)

정량적 데이터는 API Latency가 **4.5배** 단축되었음을 명확히 보여줍니다. 그러나 이 수치만을 가지고 기존의 **'4시간 소요'** 문제를 단순 비교하는 것에는 **중대한 함정**이 있습니다.

* **단순 계산의 한계:** $4 \text{시간}$의 작업 시간을 $4.5$로 나누면 약 $53 \text{분} 20 \text{초}$라는 결과가 나옵니다. **50분대**라는 시간은 여전히 물류 작업의 **'실시간성'** 측면에서 느리게 느껴질 수 있으며, 이는 아키텍처 개선의 실질적인 가치를 오해하게 만들 수 있습니다.
* **아키텍처적 이점의 본질 (처리량 붕괴 해소):** 기존 4시간 지연의 근본 원인은 **$\mathbf{27.97 \text{ms}}$의 동기식 I/O 대기**가 유발한 **스레드 고갈 및 시스템 처리량(Throughput)의 붕괴**였습니다. 새로운 아키텍처는 **개별 요청**을 DB 종속성에서 완전히 분리(Decoupling)하여, 기존 시스템을 마비시켰던 **'대기열 적체'** 문제를 원천적으로 해소합니다.
* **수평적 확장과의 결합:** **Ingest Service**와 **Persistence Worker** 모두 인스턴스를 자유롭게 **수평 확장**할 수 있습니다. 즉, 피크 부하 시 요청이 들어오는 족족 **고속 Ingest API**를 통해 처리되고, 대기열(Kafka/Redis)에 쌓인 물량은 **다수의 Worker**가 병렬로 처리합니다.
* **최종 기대 효과:** 따라서, 이 프로젝트의 실질적인 개선 효과는 단순한 $4.5 \text{배}$의 속도 향상을 넘어, **시스템의 처리 능력 한계를 해제**하고 대규모 물량을 **'실시간 처리에 가까운'** 속도로 안정적으로 소화할 수 있는 **압도적인 처리량 안정성(Throughput Stability)** 을 확보했다는 점입니다.

**참고 사항**  
본 프로젝트는 제가 직접 아키텍처를 고민하고 설계한 후, Claude AI를 활용해 초기 구조 초안을 빠르게 프로토타이핑했습니다.  
실제 코드 구현, Prometheus 설정, JMeter 부하 테스트, Grafana 분석 및 그래프 캡처 등 핵심 작업은 모두 직접 수행했습니다.
