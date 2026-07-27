package com.barcode.barcode_persistence_worker.repository;

import java.util.List;

import com.barcode.barcode_persistence_worker.entity.BarcodeEntity;

public interface BarcodeRepositoryCustom {

    /**
     * IDENTITY 전략이 JDBC 배치 인서트를 막는 문제를 우회하기 위해 JdbcTemplate으로
     * 다중 값 INSERT 한 문장을 실행한다. 유니크 제약 위반 시 이 문장 전체가 실패해
     * 트랜잭션이 롤백되는 동작은 기존 saveAll과 동일하다.
     *
     * MySQL Connector/J의 rewriteBatchedStatements=true가 DB_URL에 설정돼 있어야
     * 실제로 한 문장으로 재작성된다. 이 옵션이 없으면 오류 없이 조용히 건별 실행으로
     * 되돌아간다(FIX-PLAN 항목 10 참고, 완료 시점 기준 .env 미설정 상태였음).
     */
    void batchInsert(List<BarcodeEntity> entities);

    /**
     * 항목 22 측정용: 최근 삽입된 행 중 일부를 UPDATE해 실제 앱 커넥션 풀을 통한
     * 행 경합을 재현한다.
     */
    void touchRecent(int limit);
}
