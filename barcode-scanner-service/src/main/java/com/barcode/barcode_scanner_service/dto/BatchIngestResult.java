package com.barcode.barcode_scanner_service.dto;

import java.util.List;

/**
 * ingest-service의 /ingest/barcodes 응답과 같은 모양이다. failedIndices는 전송한 리스트에서의
 * 위치(0-based)를 가리킨다.
 */
public record BatchIngestResult(int total, int succeeded, List<Integer> failedIndices) {
}
