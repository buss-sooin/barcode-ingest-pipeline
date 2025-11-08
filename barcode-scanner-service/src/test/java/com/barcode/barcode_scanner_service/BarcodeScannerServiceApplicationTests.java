package com.barcode.barcode_scanner_service;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import com.barcode.barcode_scanner_service.service.BarcodeService;
import com.barcode.barcode_scanner_service.service.generator.BarcodeType;

@SpringBootTest
class BarcodeScannerServiceApplicationTests {

	@Autowired
	private BarcodeService barcodeService;

	@Test
	void testBarcodeData() {
		System.out.println(barcodeService.makeBarcode(BarcodeType.EAN13));
	}

	@Test
	void contextLoads() {
	}

}
