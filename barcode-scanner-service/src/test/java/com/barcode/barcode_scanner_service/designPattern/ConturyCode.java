package com.barcode.barcode_scanner_service.designPattern;

public enum ConturyCode {
    KOREA("880");

    private final String code;

    ConturyCode(String code) {
        this.code = code;
    }

    public String code() {
        return code;
    }
}
