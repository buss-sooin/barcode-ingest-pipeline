package com.barcode.barcode_ingest_service.service;

import java.util.concurrent.CompletableFuture;

import org.springframework.kafka.KafkaException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;

import com.barcode.barcode_ingest_service.dto.BarcodeIngestRequest;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 바코드 이벤트를 Kafka 토픽("barcode-events")에 발행한다. deviceId를 파티션
 * 키로 써서 같은 센터 PC의 이벤트가 같은 파티션에 순서대로 쌓이게 한다.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class BarcodeProducer {

    private static final String TOPIC = "barcode-events";
    private final KafkaTemplate<String, Object> kafkaTemplate;

    /**
     * @return 발행 결과 Future. 호출자가 전송 확인 대기에 쓴다(awaitSendConfirmed 참고).
     */
    public CompletableFuture<SendResult<String, Object>> sendBarcodeEvent(BarcodeIngestRequest event) {
        String key = event.deviceId();

        CompletableFuture<SendResult<String, Object>> future;
        try {
            future = kafkaTemplate.send(TOPIC, key, event);
        } catch (KafkaException e) {
            // max.block.ms 안에 메타데이터 조회·버퍼 할당이 끝나지 않으면 send() 자체가
            // Future를 반환하기 전에 이 예외를 던진다. 실패로 통일해서 다루도록 실패한
            // future로 감싼다.
            log.error("Failed to send barcode event - Key: {}, Barcode: {}", key, event.barcode(), e);
            return CompletableFuture.failedFuture(e);
        }

        future.whenComplete((result, ex) -> {
            if (ex == null) {
                log.info("Sent barcode event - Key: {}, Barcode: {}, Partition: {}, Offset: {}",
                    key,
                    event.barcode(),
                    result.getRecordMetadata().partition(),
                    result.getRecordMetadata().offset());
            } else {
                log.error("Failed to send barcode event - Key: {}, Barcode: {}",
                    key, event.barcode(), ex);
            }
        });

        return future;
    }
}
