package com.barcode.barcode_scanner_service.service;

import java.util.List;

import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import com.barcode.barcode_scanner_service.dto.BarcodeRequest;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Component
@RequiredArgsConstructor
public class ApiGatewayTransmitter {

    // private static final String API_GATEWAY_URL = "/ingest/barcode";
    private final RestClient restClient; 

    @Async 
    public void transmitBatch(List<BarcodeRequest> batch) {
        if (batch.isEmpty()) {
            log.warn("전송할 바코드 배치가 비어 있습니다. 전송을 건너뜁니다.");
            return;
        }

        try {
            restClient.post()
                    //   .uri(API_GATEWAY_URL) 
                    .body(batch)
                    .retrieve()
                    .toBodilessEntity(); 
            
            log.info("✅ 바코드 배치 전송 성공. 전송 건수: {} 건, 첫 번째 DeviceID: {}",
            batch.size(),
            batch.get(0).deviceId());

        } catch (Exception e) {
            log.error("❌ 바코드 배치 전송 실패! 전송 건수: {} 건, 에러: {}", 
                    batch.size(), 
                    e.getMessage(), 
                    e);
        }
    }

}
