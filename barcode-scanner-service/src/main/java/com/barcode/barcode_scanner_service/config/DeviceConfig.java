package com.barcode.barcode_scanner_service.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.scanner")
public record DeviceConfig(
    String deviceId,
    int batchSizeLimit
) { 
    
}
