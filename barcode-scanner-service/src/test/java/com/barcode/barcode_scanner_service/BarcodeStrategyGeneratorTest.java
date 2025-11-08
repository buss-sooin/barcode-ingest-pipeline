package com.barcode.barcode_scanner_service;

import static com.barcode.barcode_scanner_service.designPattern.BarcodeType.EAN13;
import static com.barcode.barcode_scanner_service.designPattern.BarcodeType.ITF14;

import org.junit.jupiter.api.Test;

import com.barcode.barcode_scanner_service.designPattern.builderPattern.BarcodeStrategyBuilder;

public class BarcodeStrategyGeneratorTest {

    @Test
    void builderStrategyTest() {
        String EAN13barcode = BarcodeStrategyBuilder.builder(EAN13).build().generateBarcode();
        String ITF4barcode = BarcodeStrategyBuilder.builder(ITF14).build().generateBarcode();

        System.out.println("EAN13 barcode : " + EAN13barcode);
        System.out.println("ITF14 barcode : " + ITF4barcode);
    }

}
