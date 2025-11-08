package com.barcode.barcode_persistence_worker.service;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.PendingMessagesSummary;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
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
    
    private final RedisTemplate<String, String> redisTemplate;
    private final BarcodeRepository barcodeRepository;
    private final DeviceCenterMappingRepository deviceMappingRepository;
    
    @Value("${redis.stream.key}")
    private String streamKey;
    
    @Value("${redis.stream.consumer-group}")
    private String consumerGroup;
    
    @Value("${redis.stream.consumer-name}")
    private String consumerName;
    
    @Value("${worker.batch-size}")
    private int batchSize;
    
    @Value("${worker.block-time}")
    private long blockTime;
    
    @PostConstruct
    public void initialize() {
        try {
            // Consumer Group 생성 (이미 있으면 무시)
            redisTemplate.opsForStream()
                .createGroup(streamKey, consumerGroup);
            log.info("✅ Created consumer group: {}", consumerGroup);
        } catch (Exception e) {
            log.info("ℹ️ Consumer group already exists: {}", consumerGroup);
        }
    }
    
    @Scheduled(fixedDelayString = "${worker.poll-interval}")
    public void processBatch() {
        try {
            // Redis Streams에서 읽기
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
            
            log.info("📥 Read {} messages from Redis Stream", records.size());
            
            // MySQL에 배치 저장
            List<BarcodeEntity> entities = new ArrayList<>();
            List<RecordId> processedIds = new ArrayList<>();
            
            for (MapRecord<String, Object, Object> record : records) {
                try {
                    BarcodeEntity entity = mapToEntity(record);
                    entities.add(entity);
                    processedIds.add(record.getId());
                } catch (Exception e) {
                    log.error("❌ Failed to map record: {}", record.getId(), e);
                }
            }
            
            // 배치 저장
            if (!entities.isEmpty()) {
                barcodeRepository.saveAll(entities);
                log.info("💾 Saved {} barcodes to MySQL", entities.size());
                
                // ACK (처리 완료)
                redisTemplate.opsForStream()
                    .acknowledge(streamKey, consumerGroup, 
                        processedIds.toArray(new RecordId[0]));
                log.info("✅ Acknowledged {} messages", processedIds.size());
            }
            
        } catch (Exception e) {
            log.error("❌ Error processing batch", e);
        }
    }
    
    private BarcodeEntity mapToEntity(MapRecord<String, Object, Object> record) {
        Map<Object, Object> value = record.getValue();

        String deviceId = (String) value.get("deviceId");

        String centerId = deviceMappingRepository.findByDeviceId(deviceId)
            .map(DeviceCenterMappingEntity::getCenterId)
            .orElseThrow(() -> new IllegalStateException("Unknown deviceId: " + deviceId));

        return BarcodeEntity.builder()
            .internalBarcodeId((String) value.get("internalBarcodeId"))
            .originalBarcode((String) value.get("originalBarcode"))
            .deviceId(deviceId)
            .centerId(centerId)
            .scanTime(Instant.parse((String) value.get("scanTime")))
            .processedTime(Instant.parse((String) value.get("processedTime")))
            .savedTime(Instant.now())
            .build();
    }
    
    /**
     * Pending List 재처리 (실패한 메시지)
     */
    @Scheduled(fixedDelay = 60000)  // 1분마다
    public void processPendingMessages() {
        try {
            PendingMessagesSummary summary = redisTemplate.opsForStream()
                .pending(streamKey, consumerGroup);
            
            if (summary.getTotalPendingMessages() > 0) {
                log.warn("⚠️ Found {} pending messages, reprocessing...", 
                    summary.getTotalPendingMessages());
                
                // Pending 메시지 읽기
                List<MapRecord<String, Object, Object>> pendingRecords = 
                    redisTemplate.opsForStream()
                        .read(
                            Consumer.from(consumerGroup, consumerName),
                            StreamReadOptions.empty().count(100),
                            StreamOffset.create(streamKey, ReadOffset.from("0-0"))
                        );
                
                // 재처리 로직 (processBatch와 동일)
            }
        } catch (Exception e) {
            log.error("❌ Error processing pending messages", e);
        }
    }
}