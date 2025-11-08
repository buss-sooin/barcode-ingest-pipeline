package com.barcode.barcode_ingest_service.service;

import java.util.concurrent.CompletableFuture;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;

import com.barcode.barcode_ingest_service.dto.BarcodeIngestRequest;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Service
@RequiredArgsConstructor
public class BarcodeProducer {
    
    private static final String TOPIC = "barcode-events";
    private final KafkaTemplate<String, Object> kafkaTemplate;
    
    public void sendBarcodeEvent(BarcodeIngestRequest event) {
        // device ID를 Key로 사용 (같은 센터PC는 같은 파티션으로)
        String key = event.deviceId();
        
        CompletableFuture<SendResult<String, Object>> future = 
            kafkaTemplate.send(TOPIC, key, event);
        
        future.whenComplete((result, ex) -> {
            if (ex == null) {
                log.info("✅ Sent barcode event - Key: {}, Barcode: {}, Partition: {}, Offset: {}", 
                    key,
                    event.barcode(),
                    result.getRecordMetadata().partition(),
                    result.getRecordMetadata().offset());
            } else {
                log.error("❌ Failed to send barcode event - Key: {}, Barcode: {}", 
                    key, event.barcode(), ex);
            }
        });
    }
}
