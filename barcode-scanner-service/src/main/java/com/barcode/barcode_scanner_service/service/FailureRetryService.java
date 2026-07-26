package com.barcode.barcode_scanner_service.service;

import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import com.barcode.barcode_scanner_service.dto.BarcodeRequest;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 전송에 실패한 요청을 메모리 큐에 쌓아뒀다가 주기적으로 재시도한다. 큐는
 * maxQueueSize로 상한을 두며, 가득 찬 상태에서 실패가 계속되면 새 요청이든
 * 재시도 대상이든 그대로 버려진다 — 프로세스 재시작 시에도 소실된다.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class FailureRetryService {
    
    private final RestClient restClient;
    private final Queue<BarcodeRequest> failedQueue = new ConcurrentLinkedQueue<>();
    
    @Value("${retry.max-queue-size:10000}")
    private int maxQueueSize;
    
    /**
     * HTTP 전송을 시도하고, 실패 시 재시도 큐에 저장합니다.
     */
    public void sendWithRetry(BarcodeRequest request) {
        try {
            restClient.post()
                .uri("/ingest/barcode")
                .body(request)
                .retrieve()
                .toBodilessEntity();
            
            log.debug("Successfully sent to Ingest: {}", request.barcode());

        } catch (Exception e) {
            if (failedQueue.size() >= maxQueueSize) {
                log.error("Retry queue is full ({}). Dropping barcode: {}",
                    maxQueueSize, request.barcode());
                return;
            }

            log.warn("Failed to send, adding to retry queue: {}", request.barcode());
            failedQueue.offer(request);
            log.info("Retry queue size: {}/{}", failedQueue.size(), maxQueueSize);
        }
    }

    /**
     * 5초마다 실패한 요청을 재시도합니다.
     */
    @Scheduled(fixedDelay = 5000)
    public void retryFailedRequests() {
        if (failedQueue.isEmpty()) {
            return;
        }

        log.info("Retrying {} failed requests", failedQueue.size());
        
        int successCount = 0;
        int failCount = 0;
        
        // 현재 큐 크기만큼만 재시도 (무한 루프 방지)
        int currentSize = failedQueue.size();
        
        for (int i = 0; i < currentSize; i++) {
            BarcodeRequest request = failedQueue.poll();
            
            if (request == null) {
                break;
            }
            
            try {
                restClient.post()
                    .uri("/ingest/barcode")
                    .body(request)
                    .retrieve()
                    .toBodilessEntity();
                
                successCount++;
                log.debug("Retry success: {}", request.barcode());

            } catch (Exception e) {
                failCount++;

                if (failedQueue.size() < maxQueueSize) {
                    failedQueue.offer(request);  // 다시 큐에 추가
                    log.debug("Retry failed, re-queued: {}", request.barcode());
                } else {
                    log.error("Retry failed and queue is full. Dropping: {}", request.barcode());
                }

                break;  // 연속 실패 시 다음 스케줄까지 대기
            }
        }

        if (successCount > 0 || failCount > 0) {
            log.info("Retry summary - Success: {}, Failed: {}, Remaining in queue: {}/{}",
                successCount, failCount, failedQueue.size(), maxQueueSize);
        }
    }
    
    /**
     * 재시도 큐의 현재 크기를 반환합니다. (모니터링용)
     */
    public int getQueueSize() {
        return failedQueue.size();
    }
    
}
