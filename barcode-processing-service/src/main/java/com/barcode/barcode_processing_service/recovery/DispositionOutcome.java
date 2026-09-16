package com.barcode.barcode_processing_service.recovery;

public record DispositionOutcome(
    DispositionResult result,
    FailureCategory failureCategory,
    int replayCount,
    String quarantineReason
) {
}
