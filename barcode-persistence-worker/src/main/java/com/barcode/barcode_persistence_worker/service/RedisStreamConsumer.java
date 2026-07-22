package com.barcode.barcode_persistence_worker.service;

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
import org.springframework.dao.DataIntegrityViolationException;
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
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

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

    private final RedisTemplate<String, String> redisTemplate;
    private final BarcodeRepository barcodeRepository;
    private final DeviceCenterMappingRepository deviceMappingRepository;

    @Value("${redis.stream.key}")
    private String streamKey;

    @Value("${redis.stream.consumer-group}")
    private String consumerGroup;

    // @Value("${redis.stream.consumer-name}")
    // private String consumerName;

    @Value("${worker.consumer-name}")  // 설정에서 주입
    private String consumerName;

    @Value("${worker.batch-size}")
    private int batchSize;

    @Value("${worker.block-time}")
    private long blockTime;

    @Value("${redis.stream.dlq-key}")
    private String dlqStreamKey;

    @Value("${redis.stream.dlq-maxlen}")
    private long dlqMaxLen;

    @PostConstruct
    public void initialize() {
        try {
            redisTemplate.opsForStream().createGroup(streamKey, consumerGroup);
            log.info("Created consumer group: {}", consumerGroup);
        } catch (Exception e) {
            log.info("Consumer group already exists: {}", consumerGroup);
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

        } catch (Exception e) {
            log.error("Error processing batch", e);
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
        } catch (Exception e) {
            log.error("Error processing pending messages", e);
        }
    }

    private void processAndSaveRecords(List<MapRecord<String, Object, Object>> records) {
        List<BarcodeEntity> entities = new ArrayList<>();
        List<RecordId> processedIds = new ArrayList<>();
        Map<RecordId, MapRecord<String, Object, Object>> rawRecordById = new HashMap<>();

        for (MapRecord<String, Object, Object> record : records) {
            try {
                BarcodeEntity entity = mapToEntity(record);
                entities.add(entity);
                processedIds.add(record.getId());
                rawRecordById.put(record.getId(), record);
            } catch (Exception e) {
                log.error("Failed to map record: {}", record.getId(), e);
            }
        }

        if (!entities.isEmpty()) {
            saveWithRetry(entities, processedIds, rawRecordById);
        }
    }

    /**
     * saveAll의 DB I/O 효율은 유지하되, 유니크 제약 위반으로 롤백되면 이미 저장된
     * 건을 걸러내고 남은 건만 새 트랜잭션(barcodeRepository.saveAll의 새 호출)에서
     * 재시도한다. 실패한 트랜잭션의 영속성 컨텍스트는 재사용하지 않는다 — 각
     * saveAll 호출은 Spring Data 프록시를 통해 독립된 트랜잭션으로 실행된다.
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

        for (int attempt = 1; attempt <= MAX_SAVE_ATTEMPTS && !toSave.isEmpty(); attempt++) {
            try {
                barcodeRepository.saveAll(toSave);
                for (BarcodeEntity entity : toSave) {
                    toAck.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
                }
                toSave = List.of();
            } catch (DataIntegrityViolationException e) {
                List<String> remainingIds = new ArrayList<>();
                for (BarcodeEntity entity : toSave) {
                    remainingIds.add(entity.getInternalBarcodeId());
                }
                Set<String> existing = new HashSet<>(barcodeRepository.findExistingInternalBarcodeIds(remainingIds));

                List<BarcodeEntity> stillFailing = new ArrayList<>();
                for (BarcodeEntity entity : toSave) {
                    if (existing.contains(entity.getInternalBarcodeId())) {
                        log.warn("이미 저장된 바코드라 saveAll 대상에서 제외: {}", entity.getInternalBarcodeId());
                        toAck.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
                    } else {
                        stillFailing.add(entity);
                    }
                }

                log.error("saveAll 롤백 (시도 {}/{}, 대상 {}건 중 원인 미상 {}건)",
                    attempt, MAX_SAVE_ATTEMPTS, toSave.size(), stillFailing.size(), e);
                toSave = stillFailing;
            }
        }

        if (!toSave.isEmpty()) {
            List<RecordId> dlqIds = new ArrayList<>();
            for (BarcodeEntity entity : toSave) {
                dlqIds.addAll(recordIdsByBarcodeId.get(entity.getInternalBarcodeId()));
            }
            sendToDlqThenAck(dlqIds, rawRecordById,
                "saveAll 재시도 상한(" + MAX_SAVE_ATTEMPTS + "회) 초과");
        }

        if (!toAck.isEmpty()) {
            acknowledge(toAck);
        }
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

        private BarcodeEntity mapToEntity(MapRecord<String, Object, Object> record) {
        Map<Object, Object> value = record.getValue();

        String internalBarcodeId = (String) value.get("internalBarcodeId");
        String originalBarcode = (String) value.get("originalBarcode");
        String deviceId = (String) value.get("deviceId");
        String centerId = deviceMappingRepository.findByDeviceId(deviceId)
            .map(DeviceCenterMappingEntity::getCenterId)
            .orElseThrow(() -> new IllegalStateException("Unknown deviceId: " + deviceId));
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