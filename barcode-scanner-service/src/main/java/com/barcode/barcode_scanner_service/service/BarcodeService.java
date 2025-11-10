package com.barcode.barcode_scanner_service.service;

import org.springframework.stereotype.Service;

import com.barcode.barcode_scanner_service.service.generator.BarcodeStrategyBuilder;
import com.barcode.barcode_scanner_service.service.generator.BarcodeType;

@Service
public class BarcodeService {

    public String makeBarcode(BarcodeType barcodeType) {
        return BarcodeStrategyBuilder.builder(barcodeType).build().generateBarcode();
    }

}
