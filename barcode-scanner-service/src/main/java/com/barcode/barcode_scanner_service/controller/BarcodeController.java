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
    // private final RestClient restClient;

    // @GetMapping("/barcode")
    // public ResponseEntity<String> sendBarcode() {
    //     String barcode = barcodeService.makeBarcode();
    //     BarcodeRequest barcodeRequest = new BarcodeRequest(barcode, "01", "테스트상품");

    //     ResponseEntity<Void> response = restClient.post()
    //             .body(barcodeRequest)
    //             .retrieve()
    //             .toBodilessEntity();
        
    //     if (response.getStatusCode().is2xxSuccessful()) {
    //         return ResponseEntity.ok("바코드 전송 성공. 타겟 서비스에서 200 OK 확인.");
    //     }
        
    //     return ResponseEntity.status(response.getStatusCode()).body("바코드 전송 성공했으나, 예상치 못한 성공 코드입니다.");
    // }

    @PostMapping("/barcode")
    public ResponseEntity<String> receiveBarcode(@RequestBody ClientScanRequest clientRequest) {
        
        barcodeBatchSender.addBarcodeToBuffer(clientRequest);
        
        return ResponseEntity.ok("Barcode received and buffered successfully.");
    }

}
