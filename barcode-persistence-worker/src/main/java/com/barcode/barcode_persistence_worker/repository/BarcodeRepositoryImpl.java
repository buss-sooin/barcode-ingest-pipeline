package com.barcode.barcode_persistence_worker.repository;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;

import org.springframework.jdbc.core.BatchPreparedStatementSetter;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import com.barcode.barcode_persistence_worker.entity.BarcodeEntity;

import lombok.RequiredArgsConstructor;

@Repository
@RequiredArgsConstructor
public class BarcodeRepositoryImpl implements BarcodeRepositoryCustom {

    private static final String INSERT_SQL =
        "INSERT INTO barcodes "
        + "(internal_barcode_id, original_barcode, center_id, device_id, scan_time, processed_time, saved_time) "
        + "VALUES (?, ?, ?, ?, ?, ?, ?)";

    private static final String TOUCH_RECENT_SQL =
        "UPDATE barcodes SET touched_at = ? "
        + "WHERE id IN (SELECT id FROM (SELECT id FROM barcodes ORDER BY id DESC LIMIT ?) recent)";

    private final JdbcTemplate jdbcTemplate;

    @Override
    @Transactional
    public void batchInsert(List<BarcodeEntity> entities) {
        jdbcTemplate.batchUpdate(INSERT_SQL, new BatchPreparedStatementSetter() {
            @Override
            public void setValues(PreparedStatement ps, int i) throws SQLException {
                BarcodeEntity entity = entities.get(i);
                ps.setString(1, entity.getInternalBarcodeId());
                ps.setString(2, entity.getOriginalBarcode());
                ps.setString(3, entity.getCenterId());
                ps.setString(4, entity.getDeviceId());
                ps.setTimestamp(5, Timestamp.from(entity.getScanTime()));
                ps.setTimestamp(6, Timestamp.from(entity.getProcessedTime()));
                ps.setTimestamp(7, Timestamp.from(entity.getSavedTime()));
            }

            @Override
            public int getBatchSize() {
                return entities.size();
            }
        });
    }

    @Override
    @Transactional
    public void touchRecent(int limit) {
        jdbcTemplate.update(TOUCH_RECENT_SQL, Timestamp.from(Instant.now()), limit);
    }
}
