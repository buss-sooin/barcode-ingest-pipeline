package com.barcode.barcode_scanner_service.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.barcode.barcode_scanner_service.dto.ClientScanRequest;
import com.barcode.barcode_scanner_service.service.BarcodeBatchSender;

import lombok.RequiredArgsConstructor;

@RestController
@RequestMapping("/scan")
@RequiredArgsConstructor
public class BarcodeController {
    
    private final BarcodeBatchSender barcodeBatchSender;

    @PostMapping("/barcode")
    public ResponseEntity<String> receiveBarcode(@RequestBody ClientScanRequest clientRequest) {
        barcodeBatchSender.addBarcodeToBuffer(clientRequest);
        return ResponseEntity.ok("Barcode received and buffered successfully.");
    }

}
