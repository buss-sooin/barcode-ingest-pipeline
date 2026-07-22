package com.barcode.barcode_processing_service.service;

import java.time.Duration;

import org.springframework.data.redis.core.ReactiveRedisTemplate;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Service;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.dto.InternalBarcode;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import reactor.core.publisher.Mono;

@Slf4j
@Service
@RequiredArgsConstructor
public class BarcodeEventConsumer {
    
    private final BarcodeConverter barcodeConverter;
    private final RedisStreamProducer redisStreamProducer;
    private final ReactiveRedisTemplate<String, String> redisTemplate;
    
    /**
     * 여기서 예외를 잡아 삼키지 않는다. 예외가 컨테이너까지 전파되어야
     * 오프셋이 커밋되지 않고 Spring Kafka의 기본 에러 핸들러가 재시도/재소비를 수행한다.
     */
    @KafkaListener(
        topics = "barcode-events",
        groupId = "barcode-processing-group",
        concurrency = "3"
    )
    public void consumeBarcodeEvent(
        @Payload BarcodeEvent event,
        @Header(KafkaHeaders.RECEIVED_PARTITION) int partition,
        @Header(KafkaHeaders.OFFSET) long offset,
        @Header(KafkaHeaders.RECEIVED_KEY) String key
    ) {
        log.info("Received barcode event - Key: {}, Partition: {}, Offset: {}",
            key, partition, offset);
        log.info("Barcode: {}, Device: {}, scanTime: {}",
            event.barcode(), event.deviceId(), event.scanTime());

        processEvent(event).block();
        log.info("Successfully processed barcode: {}", event.barcode());
    }
    
    private Mono<Void> processEvent(BarcodeEvent event) {
        // 1. 회사 바코드 규칙으로 변환
        InternalBarcode internalBarcode = barcodeConverter.convert(event);
        
        // 2. 중복 체크 (Redis Set 사용)
        String duplicateKey = "barcode:processed:" + event.barcode();
        
        return redisTemplate.opsForValue()
            .setIfAbsent(duplicateKey, internalBarcode.internalBarcodeId(), Duration.ofDays(7))
            .flatMap(isNew -> {
                if (Boolean.TRUE.equals(isNew)) {
                    log.debug("New barcode, proceeding: {}", event.barcode());
                    // 3. Redis Streams에 추가
                    return redisStreamProducer.addToStream(internalBarcode)
                        .then();
                } else {
                    log.warn("Duplicate barcode detected: {}", event.barcode());
                    return Mono.empty();
                }
            });
    }
}
