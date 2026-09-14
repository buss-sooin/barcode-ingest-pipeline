package com.barcode.barcode_processing_service.recovery;

public enum FailureCategory {
    TRANSIENT_REDIS,
    PERMANENT_VALIDATION,
    UNKNOWN
}
