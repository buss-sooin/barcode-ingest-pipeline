package com.barcode.barcode_scanner_service.dto;

public record BarcodeRequest(
    String barcode,
    long scanTime,
    String deviceId
) {

    public BarcodeRequest {
        if (barcode == null || barcode.isBlank()) {
            throw new IllegalArgumentException("Barcode must not be empty or blank.");
        }
        
        if (deviceId == null || deviceId.isBlank()) {
            throw new IllegalArgumentException("Device ID must not be empty or blank.");
        }
    }

}
