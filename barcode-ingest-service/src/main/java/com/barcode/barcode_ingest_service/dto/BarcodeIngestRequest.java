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

    public static BarcodeIngestRequest create(String barcode, long scanTime, String deviceId) {
        return new BarcodeIngestRequest(barcode, scanTime, deviceId);
    }

}
