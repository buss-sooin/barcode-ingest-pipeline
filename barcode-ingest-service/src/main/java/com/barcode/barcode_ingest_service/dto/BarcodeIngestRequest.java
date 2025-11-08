package com.barcode.barcode_ingest_service.dto;

public record BarcodeIngestRequest(
    String barcode,
    long scanTime,
    String deviceId
) {

    public BarcodeIngestRequest {
        
        if (barcode == null || barcode.isBlank()) {
            throw new IllegalArgumentException("Barcode must not be empty or blank.");
        }
        
        if (deviceId == null || deviceId.isBlank()) {
            throw new IllegalArgumentException("Device ID must not be empty or blank.");
        }
    }

    /**
     * static factory method: 이벤트를 생성하는 명확한 진입점을 제공합니다.
     * @param barcode 검증이 완료된 바코드 데이터
     * @param scanTime 검증이 완료된 스캔 시간 (long)
     * @param deviceId 검증이 완료된 디바이스 ID
     * @return 새로운 BarcodeIngestEvent 객체
     */
    public static BarcodeIngestRequest create(String barcode, long scanTime, String deviceId) {
        return new BarcodeIngestRequest(barcode, scanTime, deviceId);
    }

}
