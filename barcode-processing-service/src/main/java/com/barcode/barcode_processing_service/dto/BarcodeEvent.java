package com.barcode.barcode_processing_service.dto;

public record BarcodeEvent(
    String barcode,
    long scanTime,
    String deviceId
) {

}
