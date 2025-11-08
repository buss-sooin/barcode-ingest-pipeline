package com.barcode.barcode_ingest_service.controller;

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
    
    @PostMapping("/barcode")
    public ResponseEntity<String> ingestBarcode(@RequestBody @Valid ScannerApiRequest request) {
        log.info("📥 Received barcode ingest request: {}", request);
        
        // Request → Event 변환 (불변 객체 생성)
        BarcodeIngestRequest event = request.toIngestRequest();
        
        // Kafka로 전송
        barcodeProducer.sendBarcodeEvent(event);
        
        return ResponseEntity.ok("Barcode event ingested: " + event.barcode());
    }
    
    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("Barcode Ingest Service is running");
    }
}