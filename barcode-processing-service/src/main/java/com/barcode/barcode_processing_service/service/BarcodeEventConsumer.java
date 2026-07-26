package com.barcode.barcode_processing_service.service;

import java.time.Duration;
import java.util.List;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.ReactiveRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;
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

/**
 * "barcode-events" Kafka 토픽을 소비해 InternalBarcode로 변환하고, 중복 여부
 * 확인과 함께 내부 Redis Stream으로 발행한다.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class BarcodeEventConsumer {

    private static final long DUPLICATE_MARK_TTL_SECONDS = Duration.ofDays(7).toSeconds();

    private final BarcodeConverter barcodeConverter;
    private final ReactiveRedisTemplate<String, String> redisTemplate;
    private final RedisScript<Long> dedupeAndPublishScript;

    @Value("${redis.stream.key}")
    private String streamKey;

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

    /**
     * 중복 체크·스트림 발행·중복 표시를 dedupe-and-publish.lua 스크립트로 한 번에 원자
     * 실행한다. 두 번의 별도 Redis 호출로 나누면 그 사이 창에서 재시도가 자기 표시에
     * 막히거나(먼저 표시하는 경우) 동시 요청이 중복 발행되는(먼저 발행하는 경우) 문제가
     * 생긴다 — FIX-PLAN 항목 5 참고.
     */
    private Mono<Void> processEvent(BarcodeEvent event) {
        InternalBarcode internalBarcode = barcodeConverter.convert(event);
        String duplicateKey = "barcode:processed:" + event.barcode();
        List<String> keys = List.of(duplicateKey, streamKey);

        return redisTemplate.execute(dedupeAndPublishScript, keys,
                internalBarcode.internalBarcodeId(),
                internalBarcode.originalBarcode(),
                internalBarcode.deviceId(),
                String.valueOf(internalBarcode.scanTime()),
                String.valueOf(internalBarcode.processedAt()),
                String.valueOf(DUPLICATE_MARK_TTL_SECONDS))
            .next()
            .doOnNext(result -> {
                if (result == 1L) {
                    log.debug("New barcode, proceeding: {}", event.barcode());
                } else {
                    log.warn("Duplicate barcode detected: {}", event.barcode());
                }
            })
            .then();
    }
}
