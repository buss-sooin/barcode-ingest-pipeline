# BIP-FR-006 AI 활용 설명

> 상태: `FINAL — HUMAN CONFIRMED`
> 대상: FR-006에서 사람의 결정과 AI 실행 책임을 구분하려는 개발자

## 한눈에 보기

FR-006에서 AI는 저장소의 구현 가능성 점검, DR 토폴로지와 검증 경계 분석, 재현 계약 준비, 전용 환경 구현, runtime 사전 점검(Preflight), Material Run 실행, Evidence 수집·보존과 종료 검증을 수행했다. 사람은 Engineering 목적과 주장 한계, 실행 권한 경계를 결정하고, 실행 결과의 의미와 외부에 제시할 주장 범위를 문서 검토로 확인했다.

사람이 확정한 핵심 결정은 FR-006을 실제 multi-datacenter DR 검증이 아니라 **로컬 A/B Kafka cluster로 cluster-level failover 원리와 RPO/RTO를 측정하는 제한된 DR 메커니즘 검증**으로 두는 것이다. 이 결정은 [재현 계약](./REPRODUCTION-CONTRACT.md)의 범위와 비주장 항목에 반영됐다.

## 단계별 책임과 확인 근거

| 단계 | AI의 실행·분석 책임 | 사람의 결정·통제 책임 | 확인 근거 |
|---|---|---|---|
| 저장소 가능성 점검 | 기존 처리 경로와 독립 A/B 환경 구성 가능성 확인 | 검증 목적과 허용 범위 결정 | [재현 계약](./REPRODUCTION-CONTRACT.md), [재현 기록](./REPRODUCTION-RECORD.md) |
| DR 설계·계약 | A=controller 1/broker 3, B=broker/controller 1, MM2 A→B, Active/Passive와 판정 기준 구체화 | 로컬 메커니즘 검증으로 범위 제한, 계약 승인 | [재현 계약](./REPRODUCTION-CONTRACT.md) |
| 구현 | Compose, topic 초기화, MM2 설정, A/B application profile, 상태·식별자 수집 도구 작성 | 승인된 topology·mutation 경계 유지 | [재현 기록](./REPRODUCTION-RECORD.md#4-구현-결과) |
| Preflight | A/B 상태, 복제, checkpoint/offset continuation, B consumer 비활성, downstream 기준선 확인 | Material Run의 허용 조건과 위험 판단 | [재현 기록](./REPRODUCTION-RECORD.md#5-preflight) |
| Material Run | A 전체 fault, producer/consumer 책임 이전, 시간선과 결과 관측 | 사전에 정한 실행 권한과 주장 경계 유지 | [재현 기록](./REPRODUCTION-RECORD.md#7-fault-및-failover-타임라인) |
| Evidence·종료 | 로그·offset·식별자 대사, Evidence 포장, 제한 사항과 종료 상태 확인 | 최종 문서 해석 및 대외 주장 확인 | [재현 기록](./REPRODUCTION-RECORD.md#8-정량-결과), [정합성 집계](./evidence/BIP-FR-006-MR-20260923T042048Z/12-reconciliation/13-counts.txt) |

AI의 과거 프롬프트 전문이나 내부 추론은 이 저장소의 Evidence로 재구성할 수 없다. 위 표는 보존된 계약, 구현물, 실행 기록과 Evidence가 뒷받침하는 역할만 기술한다.

## 한정된 오케스트레이션 시험

[재현 기록의 시험 결과](./REPRODUCTION-RECORD.md#13-선택적-오케스트레이션-로컬-시험)에 따르면 통합 실행 지시 이후 추가 Human engineering decision은 0회, Human command relay는 0회였다. 구현 → Preflight → Material Run → Evidence packaging은 하나의 제한된 Codex 실행 책임에서 완료됐다. 이는 승인된 로컬 실험의 실행 연결성에 관한 관측이며 자율적인 production 운영 능력을 입증하지 않는다.

초기 저장소 쓰기 권한과 Docker socket 접근에는 실행 환경의 Tool Permission Prompt가 필요했다. 이 대기는 fault 전 약 20초 quiet window에도 영향을 주었다. 권한 프롬프트는 실행 표면의 접근 허용 절차이며, 검증 목적·위험·계약을 결정하는 사람 승인 관문(Human Gate)이 아니다.

`Human Gate ≠ Tool Permission Prompt`

## AI 결과를 어떻게 검증하는가

AI 설명보다 [재현 계약](./REPRODUCTION-CONTRACT.md), [재현 기록](./REPRODUCTION-RECORD.md), [Material Run Evidence](./evidence/BIP-FR-006-MR-20260923T042048Z/)를 우선한다. 이 실행은 Outcome `REPRODUCED`, Experiment Validity `PASS`, Evidence Sufficiency `PARTIAL`이다. FR-006 재현 종료 상태와 이 문서의 Human 확인 상태는 별개다.

B consumer는 partition 1의 offset 37에서 이어서 시작했고, 최종 accepted 41건과 MySQL unique 41건이 대사됐다. 관측된 RPO exposure 0건은 이번 실행의 결과다. 복제 중인 레코드를 장애로 절단하는 강한 RPO 시험은 이루어지지 않았고, exactly-once failover·자동 failover·production RTO 또는 실제 multi-region DR은 검증하지 않았다.
