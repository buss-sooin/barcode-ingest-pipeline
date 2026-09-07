# BIP-FR-004 R2 Material Run Phase Controller

## 1. 책임과 비책임

[`r2-phase-controller.sh`](./r2-phase-controller.sh)는 R2 Material Run의 단계 전이와 Evidence precondition을 검증·기록하는 안전 controller다. MySQL stop/start, traffic 실행, XCLAIM, XACK 또는 다른 runtime mutation을 직접 수행하지 않는다.

Human operator는 controller의 `start`가 PASS한 뒤 승인된 exact runtime command를 별도로 실행하고, 결과 Evidence가 준비된 뒤 `finish`를 호출한다. 선행 단계가 PASS가 아니거나 precondition이 없으면 다음 단계를 거부한다.

`BIP-FR-004-RC-R2`는 [R2 Reproduction Contract](./REPRODUCTION-CONTRACT-R2.md)에 freeze됐다. 기존 사람 승인 관문(Human Gate)의 Scope와 위험 경계는 유지되지만 `NEW MATERIAL RUN AUTHORIZATION`은 `00J`의 readiness 검토 전까지 `SUSPENDED`다. 따라서 authorization 복원 전에는 `register`하거나 runtime phase를 시작하지 않는다.

## 2. 고정 phase graph

```text
register
→ baseline
→ traffic-pre
→ traffic-fault
→ mysql-stop
→ observe-outage
→ mysql-start
→ traffic-post
→ observe-reclaim
→ reconcile
```

각 phase는 `start_utc`, `end_utc`, `STARTED/PASS/FAIL/STOP`과 event log를 Run-scoped controller state에 기록한다. `FAIL` 또는 `STOP`은 후속 전이를 차단한다.

등록 이후에도 각 `start`/`finish`에서 branch와 approved HEAD를 다시 확인한다. tracked working tree나 index 변경은 거부하되, Run-scoped raw Evidence처럼 새로 생성되는 untracked 파일은 허용한다.

## 3. State 위치와 호출 형식

기본 state 위치:

```text
./evidence/<RUN_ID>/controller/
```

CLI:

```bash
SCENARIO_DIR="docs/operational-validation/failure-reproduction/BIP-FR-004-mysql-persistence-unavailable"
CONTROLLER="$SCENARIO_DIR/r2-phase-controller.sh"

"$CONTROLLER" register "$RUN_ID" \
  approved_head="$APPROVED_HEAD" \
  gate_reference="$HUMAN_GATE_REFERENCE" \
  contract_file="$SCENARIO_DIR/REPRODUCTION-CONTRACT-R2.md"

"$CONTROLLER" start "$RUN_ID" <phase> [key=value ...]
"$CONTROLLER" finish "$RUN_ID" <phase> <PASS|FAIL|STOP> [key=value ...]
"$CONTROLLER" status "$RUN_ID"
```

`register`는 다음을 직접 거부한다.

- `BIP-FR-004-MR-YYYYMMDDTHHMMSSZ`가 아닌 Run ID
- target branch 불일치
- approved HEAD 불일치
- dirty working tree
- repository 밖 Contract
- `BIP-FR-004-RC-R2`가 식별되지 않는 Contract
- 이미 등록된 Run ID

Contract path와 SHA-256은 controller state에 함께 고정된다.

`register`의 clean-tree 검사는 아직 untracked file까지 거부하지만, 등록 뒤 phase 검사는 run-scoped untracked Evidence를 허용한다. R1 Evidence를 canonical commit에 포함해 clean registration prerequisite를 충족하는 현재 경로에서는 실행을 막지 않는다. 설명과 구현의 이 비대칭은 `NON-BLOCKING FOLLOW-UP DEFECT`이며, 이번 R2 계약이나 controller semantics를 재설계하는 근거로 사용하지 않는다.

## 4. Phase별 precondition과 Evidence

### 4.1 baseline

```bash
"$CONTROLLER" start "$RUN_ID" baseline preflight_file="$PREFLIGHT_EVIDENCE"
"$CONTROLLER" finish "$RUN_ID" baseline PASS \
  baseline_evidence="$BASELINE_EVIDENCE" \
  mysql_container_id="$MYSQL_CONTAINER_ID"
```

- preflight 파일에 `RESOURCE_PREFLIGHT=PASS`가 있어야 한다.
- baseline Evidence가 실제 파일이어야 한다.
- MySQL container ID를 Run state에 고정하고 현재 `running`인지 read-only inspect한다.
- 이후 기본 600초를 넘긴 baseline은 stale로 거부한다.

### 4.2 traffic-pre / traffic-fault

Traffic driver의 phase label은 exact `RUN_ID`를 사용한다.

```bash
"$CONTROLLER" start "$RUN_ID" traffic-pre
"$CONTROLLER" finish "$RUN_ID" traffic-pre PASS \
  traffic_pid="$TRAFFIC_PID" traffic_log="$TRAFFIC_LOG"

"$CONTROLLER" start "$RUN_ID" traffic-fault
"$CONTROLLER" finish "$RUN_ID" traffic-fault PASS \
  traffic_pid="$TRAFFIC_PID" traffic_log="$TRAFFIC_LOG"
```

Controller는 PID가 살아 있고 command line에 `traffic-driver.sh`가 있으며, log가 exact Run ID의 `DRIVER_START`를 포함하고 기본 30초 이내 갱신됐는지 확인한다. stale log나 종료된 driver에서는 `mysql-stop`으로 진행할 수 없다.

### 4.3 mysql-stop / observe-outage

```bash
"$CONTROLLER" start "$RUN_ID" mysql-stop mysql_container_id="$MYSQL_CONTAINER_ID"
# start PASS 뒤에만 Human이 승인된 stop mysql 명령 실행
"$CONTROLLER" finish "$RUN_ID" mysql-stop PASS \
  mysql_stop_evidence="$MYSQL_STOP_EVIDENCE"

"$CONTROLLER" start "$RUN_ID" observe-outage
"$CONTROLLER" finish "$RUN_ID" observe-outage PASS \
  outage_evidence="$OUTAGE_EVIDENCE" \
  pending_evidence="$PENDING_EVIDENCE"
```

`mysql-stop` 시작 전 traffic overlap과 baseline freshness, baseline에서 고정한 exact container ID/current running state를 재확인한다. 종료 PASS에는 same ID가 `exited` 상태이고 stop Evidence가 있어야 한다. Outage PASS에는 unavailable과 PEL Evidence가 모두 필요하다.

### 4.4 mysql-start / traffic-post

```bash
"$CONTROLLER" start "$RUN_ID" mysql-start
# start PASS 뒤에만 Human이 승인된 start mysql 명령 실행
"$CONTROLLER" finish "$RUN_ID" mysql-start PASS \
  mysql_container_id="$MYSQL_CONTAINER_ID" \
  mysql_recovery_evidence="$MYSQL_RECOVERY_EVIDENCE"

"$CONTROLLER" start "$RUN_ID" traffic-post
# traffic log에 post-recovery DRIVER_EVENT가 추가된 뒤
"$CONTROLLER" finish "$RUN_ID" traffic-post PASS \
  traffic_post_evidence="$TRAFFIC_LOG"
```

MySQL recovery는 baseline container ID와 현재 running state를 비교한다. `traffic-post`는 시작 시 log line count를 고정하고, 종료 시 실제 증가와 `DRIVER_EVENT` Evidence를 요구한다.

### 4.5 observe-reclaim / reconcile

```bash
"$CONTROLLER" start "$RUN_ID" observe-reclaim
"$CONTROLLER" finish "$RUN_ID" observe-reclaim PASS \
  reclaim_evidence="$RECLAIM_EVIDENCE"

"$CONTROLLER" start "$RUN_ID" reconcile
"$CONTROLLER" finish "$RUN_ID" reconcile PASS \
  reconciliation_evidence="$RECONCILIATION_EVIDENCE"
```

`observe-reclaim` 시작 시 기본 420초 deadline을 기록한다. PASS에는 deadline 이내 Evidence의 `pending=0`이 필요하다. Reconciliation 시작 전 baseline, traffic, stop, outage, pending, recovery, post-traffic, reclaim Evidence locator를 모두 확인한다.

Reconciliation PASS에는 다음 세 값이 필요하다.

```text
unaccounted=0
multi_state_conflict=0
pending=0
```

Controller PASS는 Evidence 파일에 필요한 판정 값이 존재하고 phase 전이가 유효하다는 뜻이다. Material Run Outcome과 주장 경계는 R2 Contract/Record review에서 별도로 판정한다.

## 5. 두 Worker와 reclaim 의미

Phase controller는 Worker ownership을 강제로 바꾸지 않는다. 수정된 application scheduler가 `XPENDING` 상세에서 5분 이상 idle인 ID를 고르고, non-empty ID만 Redis `XCLAIM`에 전달한다. 두 Worker가 같은 candidate를 조회해도 Redis는 claim 시점의 `minIdle`을 다시 검사한다. 먼저 claim한 Worker가 idle timer와 ownership을 바꾸므로 뒤의 경합자는 빈 결과를 받을 수 있으며, controller나 Human은 이를 대신해 manual XCLAIM하지 않는다.

## 6. Automated verification

```bash
./test-r2-phase-controller.sh
```

Test는 임시 Git repository, fake read-only Docker inspect와 fake traffic process를 사용하며 실제 validation runtime을 변경하지 않는다. 다음을 검증한다.

- 잘못된 Run ID와 invalid transition 거부
- stale baseline 거부
- traffic process/log freshness 확인
- MySQL target ID 불일치 거부
- same-container stop/start state 검증
- post-recovery traffic 부재 거부
- reclaim phase와 pending 0 요구
- reconciliation 전 Evidence 누락 거부
- 전체 valid phase graph 완료
