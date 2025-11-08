package com.barcode.barcode_processing_service.dto;

public record InternalBarcode(
    String internalBarcodeId,
    String originalBarcode,
    String deviceId,
    long scanTime,
    long processedAt
) {

    public static InternalBarcode create(
        String internalBarcodeId,
        String originalBarcode,
        String deviceId,
        long scanTime,
        long processedAt
    ) {
        return new InternalBarcode(
            internalBarcodeId,
            originalBarcode,
            deviceId,
            scanTime,
            processedAt
        );
    }

}
