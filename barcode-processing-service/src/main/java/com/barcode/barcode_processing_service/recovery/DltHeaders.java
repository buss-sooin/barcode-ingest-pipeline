package com.barcode.barcode_processing_service.recovery;

public final class DltHeaders {

    public static final String REPLAY_COUNT = "x-bip-dlt-replay-count";
    public static final String FAILURE_CATEGORY = "x-bip-failure-category";
    public static final String FIRST_FAILURE_AT = "x-bip-first-failure-at";
    public static final String QUARANTINE_REASON = "x-bip-quarantine-reason";
    public static final String SOURCE_DLT_TOPIC = "x-bip-source-dlt-topic";
    public static final String SOURCE_DLT_PARTITION = "x-bip-source-dlt-partition";
    public static final String SOURCE_DLT_OFFSET = "x-bip-source-dlt-offset";

    private DltHeaders() {
    }
}
