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

    /**
     * 스캔 요청을 버퍼에 적재하고 즉시 응답한다. ingest-service로의 실제 전송은
     * BarcodeBatchSender가 배치 단위로 비동기 처리하므로, 이 응답은 저장 성공을
     * 보장하지 않는다.
     */
    @PostMapping("/barcode")
    public ResponseEntity<String> receiveBarcode(@RequestBody ClientScanRequest clientRequest) {
        barcodeBatchSender.addBarcodeToBuffer(clientRequest);
        return ResponseEntity.ok("Barcode received and buffered successfully.");
    }

}
