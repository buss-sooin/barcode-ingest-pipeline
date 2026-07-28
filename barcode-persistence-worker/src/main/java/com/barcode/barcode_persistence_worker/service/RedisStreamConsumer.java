package com.barcode.barcode_persistence_worker.service;

import java.sql.BatchUpdateException;
import java.sql.SQLException;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.CannotAcquireLockException;
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.dao.RecoverableDataAccessException;
import org.springframework.dao.TransientDataAccessResourceException;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.RedisSystemException;
import org.springframework.data.redis.connection.RedisStreamCommands.XAddOptions;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.PendingMessagesSummary;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.jdbc.UncategorizedSQLException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import io.micrometer.core.instrument.MeterRegistry;

import com.barcode.barcode_persistence_worker.entity.BarcodeEntity;
import com.barcode.barcode_persistence_worker.entity.DeviceCenterMappingEntity;
import com.barcode.barcode_persistence_worker.repository.BarcodeRepository;
import com.barcode.barcode_persistence_worker.repository.DeviceCenterMappingRepository;

import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Service
@RequiredArgsConstructor
public class RedisStreamConsumer {

    private static final int MAX_SAVE_ATTEMPTS = 3;
    private static final int MYSQL_LOCK_WAIT_TIMEOUT_ERROR_CODE = 1205;

    private final RedisTemplate<String, String> redisTemplate;
    private final BarcodeRepository barcodeRepository;
    private final DeviceCenterMappingRepository deviceMappingRepository;
    private final MeterRegistry meterRegistry;

    @Value("${redis.stream.key}")
    private String streamKey;

    @Value("${redis.stream.consumer-group}")
    private String consumerGroup;

    /**
     * WORKER_NAME 환경변수로 주입된다. 재기동 후에도 이름이 고정되어야 PEL(Pending
     * Entries List)에 남은 미확인 메시지를 이 인스턴스가 다시 회수할 수 있다
     * (FIX-PLAN 항목 15 참고).
     */
    @Value("${worker.consumer-name}")
    private String consumerName;

    @Value("${worker.batch-size}")
    private int batchSize;

    @Value("${worker.block-time}")
    private long blockTime;

    @Value("${redis.stream.dlq-key}")
    private String dlqStreamKey;

    @Value("${redis.stream.dlq-maxlen}")
    private long dlqMaxLen;

    /**
     * RedisConnectionFailureException(연결 자체 실패)과 RedisSystemException(BUSYGROUP 등 서버
     * 응답 오류)은 상속 관계가 없는 형제 분기라 각각 잡아야 섞이지 않는다(TECH-NOTES 참고).
     * 연결 실패는 "이미 존재"로 위장하지 않고 기동을 중단한다.
     * BUSYGROUP 텍스트는 RedisSystemException 자신의 메시지("Error in execution")가 아니라
     * 원인 예외(io.lettuce.core.RedisBusyException)의 메시지에 있다 — 실측으로 확인.
     * getMostSpecificCause()로 원인 체인 끝까지 내려가야 한다.
     */
    @PostConstruct
    public void initialize() {
        try {
            redisTemplate.opsForStream().createGroup(streamKey, consumerGroup);
            log.info("Created consumer group: {}", consumerGroup);
        } catch (RedisConnectionFailureException e) {
            log.error("Redis 연결 실패로 기동 중단: {}", consumerGroup, e);
            throw e;
        } catch (RedisSystemException e) {
            String rootMessage = e.getMostSpecificCause().getMessage();
            if (rootMessage != null && rootMessage.contains("BUSYGROUP")) {
                log.info("Consumer group already exists: {}", consumerGroup);
            } else {
                throw e;
            }
        }
    }
    
    @Scheduled(fixedDelayString = "${worker.poll-interval}")
    public void processBatch() {
        try {
            List<MapRecord<String, Object, Object>> records = redisTemplate.opsForStream()
                .read(
                    Consumer.from(consumerGroup, consumerName),
                    StreamReadOptions.empty()
                        .count(batchSize)
                        .block(Duration.ofMillis(blockTime)),
                    StreamOffset.create(streamKey, ReadOffset.lastConsumed())
                );
            
            if (records == null || records.isEmpty()) {
                return;
            }
            
            log.info("Read {} messages from Redis Stream", records.size());
            processAndSaveRecords(records);

        } catch (RedisConnectionFailureException e) {
            log.warn("Redis 연결 실패, 다음 주기에 재시도", e);
        } catch (DataAccessException e) {
            log.error("배치 처리 실패, 이미 읽은 레코드는 ack되지 않아 pending에 남고 다음 재처리 때 다시 시도됨", e);
        }
    }
    
    @Scheduled(fixedDelay = 60000)
    public void processPendingMessages() {
        try {
            PendingMessagesSummary summary = redisTemplate.opsForStream()
                .pending(streamKey, consumerGroup);
            
            if (summary.getTotalPendingMessages() > 0) {
                log.warn("Found {} pending messages, reprocessing...",
                    summary.getTotalPendingMessages());

                List<MapRecord<String, Object, Object>> claimedRecords =
                    redisTemplate.opsForStream()
                        .claim(
                            streamKey,
                            consumerGroup,
                            consumerName,
                            Duration.ofMinutes(5)
                        );

                if (claimedRecords == null || claimedRecords.isEmpty()) {
                    return;
                }

                log.info("Claimed {} pending messages for reprocessing", claimedRecords.size());
                processAndSaveRecords(claimedRecords);
            }
        } catch (RedisConnectionFailureException e) {
            log.warn("Redis 연결 실패, 다음 주기에 재시도", e);
        } catch (DataAccessException e) {
            log.error("pending 재처리 실패, 레코드는 pending에 남아 다음 주기에 다시 시도됨", e);
        }
    }

    private void processAndSaveRecords(List<MapRecord<String, Object, Object>> records) {
        Map<RecordId, MapRecord<String, Object, Object>> rawRecordById = new HashMap<>();
        Set<String> deviceIds = new HashSet<>();
        for (MapRecord<String, Object, Object> record : records) {
            rawRecordById.put(record.getId(), record);
            String deviceId = (String) record.getValue().get("deviceId");
            if (deviceId != null) {
                deviceIds.add(deviceId);
            }
        }

        Map<String, String> centerIdByDeviceId = new HashMap<>();
        if (!deviceIds.isEmpty()) {
            for (DeviceCenterMappingEntity mapping : deviceMappingRepository.findByDeviceIdIn(deviceIds)) {
                centerIdByDeviceId.put(mapping.getDeviceId(), mapping.getCenterId());
            }
        }

        List<BarcodeEntity> entities = new ArrayList<>();
        List<RecordId> processedIds = new ArrayList<>();
        List<RecordId> invalidIds = new ArrayList<>();

        for (MapRecord<String, Object, Object> record : records) {
            try {
                BarcodeEntity entity = mapToEntity(record, centerIdByDeviceId);
                entities.add(entity);
                processedIds.add(record.getId());
            } catch (Exception e) {
                log.error("Failed to map record: {}", record.getId(), e);
                invalidIds.add(record.getId());
            }
        }

        if (!invalidIds.isEmpty()) {
            sendToDlqThenAck(invalidIds, rawRecordById, "매핑 실패 또는 데이터 형식 오류");
        }

        if (!entities.isEmpty()) {
            saveWithRetry(entities, processedIds, rawRecordById);
        }
    }

    /**
     * batchInsert는 다중 값 INSERT 한 문장으로 실행되므로, 실패 원인에 따라 처리가 갈린다.
     * 중복 키는 재조회 후 잔여 건만 재시도(기존 로직). 그 외 데이터 위반(길이 초과, NOT
     * NULL 등)은 어느 행이 원인인지 예외가 알려주지 않으므로 건별 삽입으로 분리해 원인
     * 행만 DLQ로 보낸다. 데드락·락 타임아웃·커넥션 단절 같은 일시 실패는 데이터가
     * 정상이므로 재시도하되, 상한을 소진하면 마지막에는 DLQ로 보낸다(무한 pending 방치
     * 방지). 분류·근거는 TECH-NOTES 참고.
     */
    private void saveWithRetry(
        List<BarcodeEntity> entities,
        List<RecordId> recordIds,
        Map<RecordId, MapRecord<String, Object, Object>> rawRecordById
    ) {
        Map<String, List<RecordId>> recordIdsByBarcodeId = new LinkedHashMap<>();
        Map<String, BarcodeEntity> entityByBarcodeId = new LinkedHashMap<>();

        Iterator<RecordId> recordIdIterator = recordIds.iterator();
        for (BarcodeEntity entity : entities) {
            RecordId recordId = recordIdIterator.next();
            String barcodeId = entity.getInternalBarcodeId();
            entityByBarcodeId.putIfAbsent(barcodeId, entity);
            recordIdsByBarcodeId.computeIfAbsent(barcodeId, key -> new ArrayList<>()).add(recordId);
        }

        int duplicateCount = entities.size() - entityByBarcodeId.size();
        if (duplicateCount > 0) {
            log.warn("Batch 내 중복 internalBarcodeId {}건 제외 (성능 목적, 최종 판정은 DB 유니크 제약)",
                duplicateCount);
        }

        List<BarcodeEntity> toSave = new ArrayList<>(entityByBarcodeId.values());
        List<RecordId> toAck = new ArrayList<>();
        String exhaustedReason = null;

        int attempt = 0;
        while (!toSave.isEmpty() && exhaustedReason == null) {
            attempt++;
            try {
                barcodeRepository.batchInsert(toSave);
                for (BarcodeEntity entity : toSave) {
                    toAck.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
                }
                toSave = List.of();
            } catch (DuplicateKeyException e) {
                List<String> remainingIds = new ArrayList<>();
                List<String> remainingOriginalBarcodes = new ArrayList<>();
                for (BarcodeEntity entity : toSave) {
                    remainingIds.add(entity.getInternalBarcodeId());
                    remainingOriginalBarcodes.add(entity.getOriginalBarcode());
                }
                Set<String> existingIds = new HashSet<>(barcodeRepository.findExistingInternalBarcodeIds(remainingIds));
                Set<String> existingOriginalBarcodes =
                    new HashSet<>(barcodeRepository.findExistingOriginalBarcodes(remainingOriginalBarcodes));

                List<BarcodeEntity> stillFailing = new ArrayList<>();
                for (BarcodeEntity entity : toSave) {
                    if (existingIds.contains(entity.getInternalBarcodeId())
                            || existingOriginalBarcodes.contains(entity.getOriginalBarcode())) {
                        log.warn("이미 저장된 바코드라 saveAll 대상에서 제외: {}", entity.getInternalBarcodeId());
                        toAck.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
                    } else {
                        stillFailing.add(entity);
                    }
                }

                log.error("saveAll 롤백, 중복 키 (시도 {}/{}, 대상 {}건 중 원인 미상 {}건)",
                    attempt, MAX_SAVE_ATTEMPTS, toSave.size(), stillFailing.size(), e);
                toSave = stillFailing;
                if (!toSave.isEmpty() && attempt >= MAX_SAVE_ATTEMPTS) {
                    exhaustedReason = "저장 실패(중복 판정 후에도 원인 미상, 재시도 상한 "
                        + MAX_SAVE_ATTEMPTS + "회 초과): " + e.getMessage();
                }
            } catch (DataIntegrityViolationException e) {
                log.error("saveAll 롤백, 영구 실패로 판단해 건별 삽입으로 전환 (시도 {}, 대상 {}건)",
                    attempt, toSave.size(), e);
                insertIndividuallyIsolatingFailure(toSave, recordIdsByBarcodeId, toAck, rawRecordById);
                toSave = List.of();
            } catch (CannotAcquireLockException | QueryTimeoutException
                    | TransientDataAccessResourceException | RecoverableDataAccessException e) {
                log.error("saveAll 롤백, 일시 실패 (시도 {}/{}, 대상 {}건)",
                    attempt, MAX_SAVE_ATTEMPTS, toSave.size(), e);
                if (attempt >= MAX_SAVE_ATTEMPTS) {
                    exhaustedReason = "저장 실패(일시, 재시도 " + MAX_SAVE_ATTEMPTS + "회 소진): " + e.getMessage();
                }
            } catch (UncategorizedSQLException e) {
                if (isLockWaitTimeout(e)) {
                    log.error("saveAll 롤백, 락 대기 타임아웃이라 재시도 없이 DLQ (대상 {}건)", toSave.size(), e);
                    exhaustedReason = "저장 실패(락 대기 타임아웃, 재시도 생략): " + e.getMessage();
                } else {
                    log.error("saveAll 롤백, 원인 불명(uncategorized) (시도 {}/{}, 대상 {}건)",
                        attempt, MAX_SAVE_ATTEMPTS, toSave.size(), e);
                    if (attempt >= MAX_SAVE_ATTEMPTS) {
                        exhaustedReason = "저장 실패(원인 불명): " + e.getMessage();
                    }
                }
            } catch (DataAccessException e) {
                log.error("saveAll 롤백, 원인 불명 (시도 {}/{}, 대상 {}건)",
                    attempt, MAX_SAVE_ATTEMPTS, toSave.size(), e);
                if (attempt >= MAX_SAVE_ATTEMPTS) {
                    exhaustedReason = "저장 실패(원인 불명): " + e.getMessage();
                }
            }
        }

        if (!toSave.isEmpty() && exhaustedReason != null) {
            List<RecordId> dlqIds = new ArrayList<>();
            for (BarcodeEntity entity : toSave) {
                dlqIds.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
            }
            sendToDlqThenAck(dlqIds, rawRecordById, exhaustedReason);
        }

        if (!toAck.isEmpty()) {
            acknowledge(toAck);
        }
    }

    /**
     * 다중 값 INSERT가 중복이 아닌 데이터 위반으로 실패하면 어느 행이 원인인지 예외가
     * 알려주지 않는다. 건별로 다시 삽입해 원인 행만 골라낸다. 장애 상황에서만 도는
     * 경로라 성능은 고려하지 않는다. 중복은 ack, 그 외(영구·일시·원인불명 불문)는 DLQ —
     * 이 좁은 단위에서는 재시도해도 성공 확률이 낮고, pending 방치보다 DLQ가 안전하다.
     */
    private void insertIndividuallyIsolatingFailure(
        List<BarcodeEntity> toSave,
        Map<String, List<RecordId>> recordIdsByBarcodeId,
        List<RecordId> toAck,
        Map<RecordId, MapRecord<String, Object, Object>> rawRecordById
    ) {
        for (BarcodeEntity entity : toSave) {
            List<RecordId> recordIds = recordIdsByBarcodeId.get(entity.getInternalBarcodeId());
            try {
                barcodeRepository.batchInsert(List.of(entity));
                toAck.addAll(recordIds);
            } catch (DuplicateKeyException e) {
                log.warn("건별 삽입 중 이미 저장된 바코드라 제외: {}", entity.getInternalBarcodeId());
                toAck.addAll(recordIds);
            } catch (DataAccessException e) {
                sendToDlqThenAck(recordIds, rawRecordById, "저장 실패(영구): " + e.getMessage());
            }
        }
    }

    /**
     * UncategorizedSQLException이 감싼 BatchUpdateException은 MySQL 드라이버가 실패 원인의
     * SQLState·errorCode를 생성자 인자로 그대로 복사해 만든다(TECH-NOTES 참고). 그래도
     * getNextException()이 있으면 그쪽을 우선한다 — 다른 JDBC 드라이버로 바뀌어도 안전하도록.
     */
    private boolean isLockWaitTimeout(UncategorizedSQLException e) {
        SQLException sqlException = e.getSQLException();
        if (sqlException == null) {
            return false;
        }
        if (sqlException instanceof BatchUpdateException && sqlException.getNextException() != null) {
            sqlException = sqlException.getNextException();
        }
        return sqlException.getErrorCode() == MYSQL_LOCK_WAIT_TIMEOUT_ERROR_CODE;
    }

    /**
     * DLQ 적재가 성공한 건만 원본 스트림을 ack 한다. 적재에 실패한 건은 ack하지
     * 않아 다음 pending 재처리 때 이 흐름을 다시 탄다.
     */
    private void sendToDlqThenAck(
        List<RecordId> recordIds,
        Map<RecordId, MapRecord<String, Object, Object>> rawRecordById,
        String reason
    ) {
        List<RecordId> dlqAcked = new ArrayList<>();

        for (RecordId recordId : recordIds) {
            MapRecord<String, Object, Object> original = rawRecordById.get(recordId);
            Map<String, String> dlqPayload = new HashMap<>();
            for (Map.Entry<Object, Object> entry : original.getValue().entrySet()) {
                dlqPayload.put(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
            }
            dlqPayload.put("failureReason", reason);
            dlqPayload.put("originalRecordId", recordId.toString());

            try {
                redisTemplate.opsForStream().add(
                    StreamRecords.newRecord().ofStrings(dlqPayload).withStreamKey(dlqStreamKey),
                    XAddOptions.maxlen(dlqMaxLen).approximateTrimming(true));
                dlqAcked.add(recordId);
                meterRegistry.counter("barcode.worker.dlq.sent").increment();
            } catch (Exception e) {
                log.error("DLQ 적재 실패, 원본 ack 보류: {}", recordId, e);
            }
        }

        if (!dlqAcked.isEmpty()) {
            log.warn("DLQ로 이동: {}건, 사유={}", dlqAcked.size(), reason);
            acknowledge(dlqAcked);
        }
    }

    private void acknowledge(List<RecordId> recordIds) {
        redisTemplate.opsForStream()
            .acknowledge(streamKey, consumerGroup, recordIds.toArray(new RecordId[0]));
        log.info("Acknowledged {} messages", recordIds.size());
    }

    /**
     * 이 메서드는 DB를 직접 호출하지 않는다(매핑은 processAndSaveRecords가 일괄 조회해 넘긴
     * centerIdByDeviceId로 대체됨). 그래서 여기서 던지는 예외는 전부 이 레코드 자체의 데이터
     * 문제(미등록 deviceId, 숫자 형식 오류 등)이지 일시적 인프라 장애가 아니다. 재시도해도
     * 결과가 달라지지 않으므로 호출부에서 재시도 없이 바로 DLQ로 보내도 안전하다.
     */
    private BarcodeEntity mapToEntity(
        MapRecord<String, Object, Object> record,
        Map<String, String> centerIdByDeviceId
    ) {
        Map<Object, Object> value = record.getValue();

        String internalBarcodeId = (String) value.get("internalBarcodeId");
        String originalBarcode = (String) value.get("originalBarcode");
        String deviceId = (String) value.get("deviceId");
        String centerId = centerIdByDeviceId.get(deviceId);
        if (centerId == null) {
            throw new IllegalStateException("Unknown deviceId: " + deviceId);
        }
        Long scanTime = Long.parseLong((String) value.get("scanTime"));
        Long processedTime = Long.parseLong((String) value.get("processedTime"));

        return BarcodeEntity.builder()
            .internalBarcodeId(internalBarcodeId)
            .originalBarcode(originalBarcode)
            .deviceId(deviceId)
            .centerId(centerId)
            .scanTime(Instant.ofEpochMilli(scanTime))
            .processedTime(Instant.ofEpochMilli(processedTime))
            .savedTime(Instant.now())
            .build();
    }

}