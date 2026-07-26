package com.barcode.barcode_ingest_service.controller;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Function;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.kafka.support.SendResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.barcode.barcode_ingest_service.dto.BarcodeIngestRequest;
import com.barcode.barcode_ingest_service.dto.BatchIngestResult;
import com.barcode.barcode_ingest_service.dto.ScannerApiRequest;
import com.barcode.barcode_ingest_service.service.BarcodeProducer;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 바코드 요청을 받아 Kafka로 발행하고, HTTP 응답 전에 발행 확인까지 기다린다.
 * 확인 타임아웃이 나도 실제 전송은 취소되지 않고 백그라운드에서 계속 진행된다
 * (TECH-NOTES 참고) — 이 컨트롤러의 실패 응답은 전송이 확정적으로 실패했다는
 * 뜻이 아니라 그 시간 안에 성공을 확인하지 못했다는 뜻이다.
 */
@Slf4j
@RestController
@RequestMapping("/ingest")
@RequiredArgsConstructor
public class BarcodeIngestController {

    private static final long SEND_CONFIRM_TIMEOUT_SECONDS = 5L;

    private final BarcodeProducer barcodeProducer;
    private final ExecutorService kafkaSendExecutor;

    /**
     * 배치의 모든 건을 가상 스레드로 동시에 발행하고 SEND_CONFIRM_TIMEOUT_SECONDS
     * 안에 완료를 기다린다. 대기 후에는 각 future를 논블로킹으로 조회해 실패
     * 인덱스를 가려낸다. 일부만 실패하면 207 Multi-Status로 실패 인덱스를 함께
     * 반환한다 — 배치 부분 실패에 206을 쓰는 것은 Range 요청 전용 의미를
     * 빌리는 표준 위반이라 207을 택했다(TECH-NOTES 참고).
     */
    @PostMapping("/barcodes")
    public ResponseEntity<BatchIngestResult> ingestBarcodes(@RequestBody @Valid List<ScannerApiRequest> requests) {
        log.info("Received {} barcode requests", requests.size());

        List<CompletableFuture<SendResult<String, Object>>> futures = requests.stream()
            .map(request -> CompletableFuture
                .supplyAsync(() -> barcodeProducer.sendBarcodeEvent(request.toIngestRequest()), kafkaSendExecutor)
                .thenCompose(Function.identity()))
            .toList();

        try {
            CompletableFuture.allOf(futures.toArray(new CompletableFuture[0]))
                .get(SEND_CONFIRM_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (ExecutionException | TimeoutException e) {
            // 개별 실패/미완료 여부는 아래에서 논블로킹으로 판정한다.
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        List<Integer> failedIndices = new ArrayList<>();
        for (int i = 0; i < futures.size(); i++) {
            CompletableFuture<SendResult<String, Object>> future = futures.get(i);
            if (!future.isDone() || future.isCompletedExceptionally()) {
                failedIndices.add(i);
            }
        }

        if (!failedIndices.isEmpty()) {
            log.error("Kafka 전송 확인 실패 - 실패 인덱스: {}", failedIndices);
        }

        BatchIngestResult result =
            new BatchIngestResult(requests.size(), requests.size() - failedIndices.size(), failedIndices);
        HttpStatus status = failedIndices.isEmpty() ? HttpStatus.OK : HttpStatus.MULTI_STATUS;
        return ResponseEntity.status(status).body(result);
    }

    @PostMapping("/barcode")
    public ResponseEntity<String> ingestBarcode(@RequestBody @Valid ScannerApiRequest request) {
        log.info("Received barcode request: {}", request.barcode());

        BarcodeIngestRequest event = request.toIngestRequest();
        CompletableFuture<SendResult<String, Object>> future = barcodeProducer.sendBarcodeEvent(event);

        if (!awaitSendConfirmed(request.barcode(), future)) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body("Failed to ingest barcode " + request.barcode());
        }

        return ResponseEntity.ok("Ingested barcode " + request.barcode());
    }

    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("Barcode Ingest Service is running");
    }

    /**
     * Kafka 전송 완료를 지정된 시간(SEND_CONFIRM_TIMEOUT_SECONDS) 안에 확인한다.
     * 타임아웃이 나도 실제 전송은 취소되지 않고 백그라운드에서 계속 진행되므로, 여기서의
     * 실패 판정은 "그 시간 안에 성공을 확인하지 못함"이지 "전송이 확정적으로 실패함"이 아니다.
     */
    private boolean awaitSendConfirmed(String barcode, CompletableFuture<SendResult<String, Object>> future) {
        try {
            future.get(SEND_CONFIRM_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            return true;
        } catch (ExecutionException | TimeoutException e) {
            log.error("Kafka 전송 확인 실패 - Barcode: {}", barcode, e);
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.error("Kafka 전송 확인 대기 중 인터럽트 발생 - Barcode: {}", barcode, e);
            return false;
        }
    }
}