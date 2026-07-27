package com.barcode.barcode_scanner_service.service;

import java.util.List;

import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import com.barcode.barcode_scanner_service.dto.BarcodeRequest;
import com.barcode.barcode_scanner_service.dto.BatchIngestResult;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 배치를 ingest-service에 전송하고 확인 응답을 기다린다. 배치 중 일부만 실패로
 * 확인되면 실패한 건만 FailureRetryService의 건별 재전송 경로로 폴백하고,
 * 호출 자체가 실패하면 배치 전체를 폴백한다.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class ApiGatewayTransmitter {

    private final RestClient restClient;
    private final FailureRetryService failureRetryService;

    /**
     * 호출자(BarcodeBatchSender)의 스레드를 막지 않도록 별도 스레드에서 비동기로
     * 실행된다.
     */
    @Async
    public void transmitBatch(List<BarcodeRequest> batch) {
        if (batch.isEmpty()) {
            log.warn("전송할 바코드 배치가 비어 있습니다. 전송을 건너뜁니다.");
            return;
        }

        log.info("바코드 배치 전송 시작. 전송 건수: {} 건", batch.size());

        try {
            BatchIngestResult result = restClient.post()
                .uri("/ingest/barcodes")
                .body(batch)
                .retrieve()
                .body(BatchIngestResult.class);

            if (result == null || result.failedIndices().isEmpty()) {
                log.info("바코드 배치 전송 완료. 전송 건수: {} 건", batch.size());
                return;
            }

            // 실패한 인덱스만 건별 재전송 경로로 폴백한다. 일부는 이미 Kafka에 실제로
            // 들어갔을 수 있지만(타임아웃일 뿐 백그라운드 전송은 안 취소됨), processing 쪽
            // dedupe(7일 TTL)가 흡수한다.
            log.warn("배치 중 {}건 확인 실패, 건별 재전송으로 폴백. 전체 {} 건",
                result.failedIndices().size(), batch.size());
            for (int index : result.failedIndices()) {
                failureRetryService.sendWithRetry(batch.get(index));
            }
        } catch (Exception e) {
            // 배치 호출 자체가 실패하면(예: ingest 미기동) 어떤 건이 성공했는지 알 방법이
            // 없으므로 전체를 건별 재전송으로 폴백한다.
            log.warn("배치 전송 자체가 실패해 전체 {} 건을 건별 재전송으로 폴백합니다.", batch.size(), e);
            for (BarcodeRequest request : batch) {
                failureRetryService.sendWithRetry(request);
            }
        }
    }

}
