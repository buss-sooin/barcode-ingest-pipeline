package com.barcode.barcode_processing_service.exception;

/**
 * 재시도로 바뀌지 않는 이벤트 계약 위반을 나타낸다.
 */
public class PermanentEventValidationException extends RuntimeException {

    public PermanentEventValidationException(String message) {
        super(message);
    }
}
