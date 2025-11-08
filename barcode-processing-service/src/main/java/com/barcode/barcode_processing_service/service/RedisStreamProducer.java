package com.barcode.barcode_processing_service.service;

import java.util.HashMap;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.core.ReactiveRedisTemplate;
import org.springframework.stereotype.Service;


import com.barcode.barcode_processing_service.dto.InternalBarcode;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import reactor.core.publisher.Mono;

@Slf4j
@Service
@RequiredArgsConstructor
public class RedisStreamProducer {
    
    private final ReactiveRedisTemplate<String, String> redisTemplate;
    
    @Value("${redis.stream.key}")
    private String streamKey;
    
    public Mono<RecordId> addToStream(InternalBarcode barcode) {
        Map<String, String> data = new HashMap<>();
        data.put("internalBarcodeId", barcode.internalBarcodeId());
        data.put("originalBarcode", barcode.originalBarcode());
        data.put("deviceId", barcode.deviceId());
        data.put("scanTime", String.valueOf(barcode.scanTime()));
        data.put("processedTime", String.valueOf(barcode.processedAt()));
        
        return redisTemplate.opsForStream()
            .add(StreamRecords.newRecord()
                .ofStrings(data)
                .withStreamKey(streamKey))
            .doOnSuccess(recordId -> 
                log.info("📤 Added to Redis Stream - ID: {}, Barcode: {}", 
                    recordId, barcode.internalBarcodeId()))
            .doOnError(error -> 
                log.error("❌ Failed to add to Redis Stream: {}", barcode.internalBarcodeId(), error));
    }
}
