package com.barcode.barcode_scanner_service.service;

import java.util.List;

import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

import com.barcode.barcode_scanner_service.dto.BarcodeRequest;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Component
@RequiredArgsConstructor
public class ApiGatewayTransmitter {

    private final FailureRetryService failureRetryService;

    @Async 
    public void transmitBatch(List<BarcodeRequest> batch) {
        if (batch.isEmpty()) {
            log.warn("전송할 바코드 배치가 비어 있습니다. 전송을 건너뜁니다.");
            return;
        }

        log.info("📤 바코드 배치 전송 시작. 전송 건수: {} 건", batch.size());

        for (BarcodeRequest request : batch) {
            failureRetryService.sendWithRetry(request);
        }
        
        log.info("✅ 바코드 배치 전송 완료. 전송 건수: {} 건", batch.size());
    }

}
