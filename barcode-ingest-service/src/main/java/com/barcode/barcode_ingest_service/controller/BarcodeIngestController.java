package com.barcode.barcode_ingest_service.controller;

import java.util.List;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.barcode.barcode_ingest_service.dto.BarcodeIngestRequest;
import com.barcode.barcode_ingest_service.dto.ScannerApiRequest;
import com.barcode.barcode_ingest_service.service.BarcodeProducer;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@RestController
@RequestMapping("/ingest")
@RequiredArgsConstructor
public class BarcodeIngestController {
    
    private final BarcodeProducer barcodeProducer;
    
    @PostMapping("/barcodes")
    public ResponseEntity<String> ingestBarcodes(@RequestBody @Valid List<ScannerApiRequest> requests) {
        log.info("📥 Received {} barcode requests", requests.size());
        
        for (ScannerApiRequest request : requests) {
            BarcodeIngestRequest event = request.toIngestRequest();
            barcodeProducer.sendBarcodeEvent(event);
        }
        
        return ResponseEntity.ok("Ingested " + requests.size() + " barcodes");
    }

    @PostMapping("/barcode")
    public ResponseEntity<String> ingestBarcode(@RequestBody @Valid ScannerApiRequest request) {
        log.info("📥 Received barcode request: {}", request.barcode());
        
        BarcodeIngestRequest event = request.toIngestRequest();
        barcodeProducer.sendBarcodeEvent(event);
        
        return ResponseEntity.ok("Ingested barcode {}" + request.barcode());
    }
    
    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("Barcode Ingest Service is running");
    }
}