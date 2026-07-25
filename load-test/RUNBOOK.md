# load-test — 실행 가이드

이 문서는 `measure.sh`/`run.sh` 두 스크립트의 사용법과, 항목 7 이후 컨테이너로 전체를
기동·확인하는 방법을 다룬다. 각 단계가 왜 이렇게 구성됐는지, 손으로 직접 따라 하는 절차,
결과 요약 문서 작성법은 저장소 루트의 `TEST-PLAN.md`를 본다(현재 이 파일은 존재하지
않음 — 아직 작성되지 않은 상태). 이 문서와 `TEST-PLAN.md`는 같은 절차를 가리켜야 한다 —
스크립트에만 있고 문서에 없는 단계가 생기면 `TEST-PLAN.md`도 함께 고친다.

## 사전 준비

- `barcode-old-pipeline` 저장소가 이 저장소와 같은 부모 디렉터리 아래 형제로 있어야
  한다(`measure.sh`가 `../barcode-old-pipeline`을 상대경로로 찾는다). git worktree
  안에서 실행하는 경우(예: 이 저장소 자체를 개발 중일 때) 이 상대경로가 깨지므로
  `OLD_REPO_PATH` 환경변수로 실제 경로를 직접 넘긴다.
  예: `OLD_REPO_PATH=/Users/me/Documents/MyProject/barcode-old-pipeline ./measure.sh old-first`
- `monitoring-compose.yml`/`prometheus/`/`grafana/`는 항목 7에서 gitignore가 해제돼
  이제 이 저장소(worktree 포함) 안에 `docker-compose.yml`과 같은 위치로 들어와 있다.
  다른 위치에 따로 두고 쓰는 경우에만 `MONITORING_ROOT_PATH`로 그 루트를 넘긴다.
- Docker Desktop이 떠 있어야 한다. `measure.sh`/수동 컨테이너 기동만 쓸 경우
  `jmeter` CLI·`mysql` 클라이언트는 필요 없다(JMeter 부하까지 직접 돌릴 때만 필요).
- `.env`가 저장소 루트(또는 이 worktree 루트)에 있어야 한다(worker 신원, DB 접속 정보,
  모니터링 자격증명).
- 스크립트는 전부 저장소 루트가 아니라 **`load-test/` 안에서** 실행한다.

## 컨테이너로 전체 기동하기 (항목 7)

`measure.sh`를 거치지 않고 그냥 시스템이 도는 걸 보고 싶거나, 대시보드를 띄워놓고 직접
관찰하고 싶을 때 쓴다. 신규와 구형은 완전히 별개 compose 프로젝트라 명령이 두 줄로
나뉜다(각각은 인프라+앱+관측을 한 줄로 묶은 것).

```bash
cd load-test/..   # 저장소(또는 worktree) 루트로

# 신규: 인프라(kafka/mysql/redis) + 앱 5개(ingest·processing·scanner·worker 2대) + 관측(Prometheus/Grafana) 전부 한 줄
docker compose --project-directory . -f docker-compose.yml -f docker-compose.apps.yml -f monitoring-compose.yml -p barcode-pipeline up -d --build

# 구형: DB 2개(mysql-local/mysql-central) + 앱 3개(delivery-monolith·barcode-input-simulator·barcode-scheduler)
docker compose -f ../barcode-old-pipeline/docker-compose-legacy.yml -p barcode-old-pipeline up -d --build
```

### 준비됐는지 확인

```bash
for p in 8081 8082 8084 8085 8086; do curl -s -o /dev/null -w "%{http_code} " http://localhost:$p/actuator/health; done; echo
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9091/actuator/health
```
전부 200이면 준비 완료.

### Grafana 대시보드 보기

- `http://localhost:3000` 접속, 로그인 `admin` / `.env`의 `GRAFANA_ADMIN_PASSWORD` 값
  (기본값 `admin`).
- "Spring Boot Dashboards" 폴더 — row 3개(비교용: 신구 대비 / 설명용: 신규 전용 큐 관측 /
  DLQ·DLT 카운터) 구성. 항목 17 참고.

### DLQ/DLT 적재 확인

```bash
docker exec redis redis-cli XLEN barcode:stream:dlq
curl -s http://localhost:8082/actuator/prometheus | grep barcode_processing_dlt_sent_total
```

### 종료

```bash
docker compose -f ../barcode-old-pipeline/docker-compose-legacy.yml -p barcode-old-pipeline down
docker compose --project-directory . -f docker-compose.yml -f docker-compose.apps.yml -f monitoring-compose.yml -p barcode-pipeline down
```

## measure.sh — 전체 자동 측정

인프라 기동 → 구형(또는 신규) 기동 → 부하 → 행 수 집계 → 종료 → 반대쪽 → 인프라 종료까지
한 번에 수행한다. 항목 7 이후로는 신구 앱 기동·종료도 내부적으로 컨테이너 compose를
쓴다(`gradlew bootRun`/`pkill` 아님). 측정 1회차 전체에 해당한다(`TEST-PLAN.md` 2~11절).

```bash
cd load-test

# 1회차: 구형 먼저
./measure.sh old-first

# 2회차: 순서를 바꿔서(순서 편향 확인용, TEST-PLAN.md 10절)
./measure.sh new-first
```

부하 조건을 바꾸려면 두 번째 인자부터 `-J`를 그대로 붙인다. 신구 양쪽에 동일하게
적용된다.

```bash
./measure.sh old-first -JnumberOfThreads=20 -Jstage2DurationSeconds=300
```

### 산출물

- `load-test/results/<타임스탬프>-old.jtl`, `-new.jtl` — JMeter 원시 결과.
- `load-test/results/<타임스탬프>-old-report/`, `-new-report/` — HTML 대시보드(백분위
  포함, `index.html`).
- `load-test/results/<타임스탬프>-measure-summary.txt` — 이번 실행의 각 단계 로그,
  UTC 타임스탬프, 부하 전후 행 수, DLQ/DLT 값.

이 파일들을 참고해 `docs/measurements/YYYY-MM-DD-HHmm-<round>.md`(결과 요약 문서,
`TEST-PLAN.md` 12절 형식)를 직접 작성한다 — `measure.sh`는 그 문서를 대신 써주지
않는다.

`KEEP_INFRA=1`을 앞에 붙이면 측정이 끝나도 관측 스택을 내리지 않는다 — 신구 구간이
모두 끝난 뒤 Prometheus에 쿼리(`TEST-PLAN.md` 9절)를 던지거나 Grafana 대시보드를 직접
보려면 인프라가 살아있어야 하므로, 이 옵션을 쓰고 확인까지 마친 뒤 스크립트가 출력하는
명령으로 직접 내린다.

```bash
KEEP_INFRA=1 ./measure.sh old-first
```

### 알아둘 것

- `set -euo pipefail`로 동작해 중간 단계(예: 앱 기동 대기 180초 초과)에서 실패하면
  즉시 멈춘다. 이 경우 떠 있는 컨테이너가 남을 수 있으므로 `docker ps -a`로 직접
  정리해야 한다.
- 구형·신규 DB 접속 정보(포트, 계정)는 스크립트 안에 상수로 박혀 있다
  (`central_user`/`central_pass`, `.env`의 `MYSQL_USER`/`MYSQL_PASSWORD`). 구형
  저장소의 계정을 바꾸면 스크립트도 같이 고쳐야 한다.
- kafka-exporter가 kafka보다 먼저 뜨는 레이스 컨디션을 자동으로 우회한다(재시작
  1회). 그 외 Docker 데몬 자체가 죽는 문제는 스크립트가 감지하지 못한다 —
  `docker info`가 막힌 채로 오래 걸리면 직접 확인해야 한다.

## run.sh — JMeter 한 쪽만 실행

`measure.sh`가 내부에서 호출하는 하위 스크립트다. 인프라·앱 기동 없이 JMeter
실행만 다시 하고 싶을 때(이미 앱이 떠 있는 상태에서 부하 조건만 바꿔 재측정하는 경우
등) 직접 쓴다.

```bash
./run.sh new                                  # barcode-real-test.jmx, 신규만
./run.sh old barcode-simple-test.jmx          # 다른 jmx 지정
./run.sh new barcode-real-test.jmx -JnumberOfThreads=20
```

첫 인자로 반대쪽 스레드 수를 자동으로 0으로 넘긴다(`new`면 `oldNumberOfThreads=0`,
`old`면 `numberOfThreads=0`). 자세한 동작은 `run.sh` 파일 상단 주석과
`TEST-PLAN.md`를 본다.

## fault-injection-run.sh — 신구 공용, DB 지연 주입(항목 21)

`run.sh <old|new>`를 백그라운드로 돌리면서 시작 90초 뒤 대상 DB의 `barcodes` 테이블을
`SELECT ... FOR UPDATE`(WHERE 없는 전체 스캔)로 60초간 잠가 정상/장애/회복 3구간을
만든다. 앱·인프라 기동은 이 스크립트의 책임이 아니다 — 호출 전에 이미 떠 있어야 한다.

```bash
./fault-injection-run.sh new    # worker가 쓰는 delivery.barcodes를 잠금
./fault-injection-run.sh old    # mysql-central.central_barcode.barcodes를 잠금
```

**주의 — `old` 인자의 의미가 `run.sh old`와 다르다.** `run.sh old`가 실제로 때리는 건
`barcode-input-simulator`(9081)이고, 그건 `local_barcode`에만 동기 저장한다.
`central_barcode`(이 스크립트가 잠그는 대상)는 `delivery-monolith`가 쓰는 DB라서
`barcode-scheduler`를 통해 비동기로만 채워진다 — 즉 `fault-injection-run.sh old`는
"simulator 쪽 응답이 central_barcode 지연에 영향받는지"는 검증하지 못한다(항목 21에서
실측으로 확인, 무효 처리됨). delivery-monolith 자체의 자원 경합을 보려면 아래
`fault-injection-direct-old.sh`를 쓴다.

결과는 `results/<jtl과 같은 타임스탬프>-phase-{normal,fault,recovery}.jtl`(+`-report/`)로
3구간이 나뉘어 남고, `<타임스탬프>.fault-meta.txt`에 잠금 시작·해제 시각이 기록된다.

## fault-injection-direct-old.sh — delivery-monolith 직접 타격(항목 21)

`barcode-real-test.jmx`를 거치지 않고 `delivery-monolith`(9091, `/api/barcode`)를 curl로
직접 때리면서 `central_barcode.barcodes`를 잠근다. HikariCP `maximum-pool-size`(10)보다
많은 동시 워커(15개)를 써서 잠금으로 인한 지연뿐 아니라 풀 고갈로 인한 타임아웃/에러까지
관측한다. delivery-monolith와 mysql-central만 떠 있으면 되고(simulator·scheduler
불필요), 인자 없이 실행한다.

```bash
./fault-injection-direct-old.sh
```

결과는 `results/<타임스탬프>-delivery-monolith-direct.csv`(요청별
`timestamp_ms,duration_ms,http_status`)와 `.fault-meta.txt`로 남는다. jtl이 아니라
CSV이므로 구간별 통계는 `jmeter -g`가 아니라 직접 awk 등으로 집계해야 한다(예시는
`docs/measurements/2026-07-25-0055-fault-injection.md` 참고).

## fault-injection-domain-backlog.sh / pending-count-poll.sh — 도메인 관점 적체(항목 21 부록)

HTTP 응답시간이 아니라 "스캔이 central_barcode에 저장돼야 완성된다"는 도메인 기준으로
적체를 본다. `barcode-input-simulator`(9081)에 curl로 부하를 걸며 central_barcode를
길게(기본 180초) 잠그고, 그동안 `local_barcode.barcodes`의 `status='PENDING'` 건수가
쌓였다가 회복되는 과정을 `pending-count-poll.sh`로 5초 간격 폴링한다(Prometheus에
해당 지표가 없어 직접 SQL 폴링만 가능). delivery-monolith·simulator·scheduler가 모두
떠 있어야 한다.

```bash
./fault-injection-domain-backlog.sh
```

`pending-count-poll.sh <간격초> <총지속초> <출력csv경로>`는 단독으로도 쓸 수 있다.

**주의 — 실행 중인 프로세스의 로그 파일을 `: > 파일`로 비우지 말 것.** 그 프로세스가
이미 열어둔 파일 오프셋과 어긋나 NUL 바이트로 파일이 깨진다(항목 21 부록 작업 중 실제로
겪음, TECH-NOTES 미기록 — 대신 여기 남김). scheduler 로그처럼 실행 중 새로 남는 부분만
보고 싶으면 사전에 `wc -l`로 라인 수를 기록해두고 사후에 `tail -n +N`으로 잘라낸다.

결과는 `results/<타임스탬프>-simulator-direct.csv`(부하 로그),
`results/<타임스탬프>-local-barcode-pending.csv`(PENDING 추이),
`results/<타임스탬프>-scheduler.log`(scheduler 로그 사본), `.fault-meta.txt`(구간 시각)로
남는다.

## results/ 폴더 구조

`results/`는 `.gitignore` 대상이라(재생성 가능한 산출물) 저장소에는 안 들어간다.

스크립트(`run.sh`/`measure.sh`/`fault-injection-*.sh`)는 실행 중엔 항상 `results/` 바로
아래에 평평하게 쓴다 — 스크립트 자체는 어떤 항목(item) 작업인지 모르고, 이는 의도적이다
(여러 스크립트가 공유하는 검증된 자산이라 항목별 경로를 하드코딩하지 않는다). **항목 하나가
끝나면 그 항목에서 나온 파일들을 손으로 `results/item<N>/`으로 옮겨 정리한다.**

```
results/
├── item18/   측정 실행 구성 및 신구 실측 (measure.sh 기반, <타임스탬프>-{old,new}.jtl 등)
└── item21/   DB 지연 주입 시 자원 경합 격리 검증 (fault-injection-*.sh 기반)
```

정리 전(진행 중인 항목의 파일들)은 `results/` 루트에 그대로 있을 수 있다 — 항목이
끝나기 전엔 정상이다.
