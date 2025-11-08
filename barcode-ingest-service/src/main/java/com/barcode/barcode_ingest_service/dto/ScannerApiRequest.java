package com.barcode.barcode_ingest_service.dto;

import jakarta.validation.constraints.NotNull;

public record ScannerApiRequest(
    @NotNull(message = "스캔 시간(scanTime)은 필수 입력값입니다.")
    Long scanTime,
    @NotNull(message = "바코드 데이터는 필수입니다.")
    String barcode,
    @NotNull(message = "디바이스 ID는 필수입니다.")
    String deviceId
) {

    public ScannerApiRequest {
        if (scanTime != null) {
            if (scanTime <= 0L) {
                throw new IllegalArgumentException("Scan time must be a positive value.");
            }
            
            if (scanTime > System.currentTimeMillis() + 1000L) {
                throw new IllegalArgumentException("Scan time cannot be in the future (exceeds 1-second grace period).");
            }
        }

        if (barcode == null || barcode.isBlank()) {
            throw new IllegalArgumentException("Barcode must not be empty or blank.");
        }
        
        if (deviceId == null || deviceId.isBlank()) {
            throw new IllegalArgumentException("Device ID must not be empty or blank.");
        }
    }

    /**
     * 검증이 완료된 요청 데이터를 내부 Kafka/Redis 전송용 DTO로 변환합니다.
     */
    public BarcodeIngestRequest toIngestRequest() {
        return BarcodeIngestRequest.create(
            this.barcode, 
            this.scanTime.longValue(),
            this.deviceId
        );
    }

}
