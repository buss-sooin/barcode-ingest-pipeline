package com.barcode.barcode_persistence_worker.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.barcode.barcode_persistence_worker.repository.BarcodeRepository;

import lombok.RequiredArgsConstructor;

@RestController
@RequestMapping("/api/barcode")
@RequiredArgsConstructor
public class BarcodeMaintenanceController {

    private final BarcodeRepository barcodeRepository;

    /**
     * 항목 22 측정용: 최근 삽입된 행 중 일부를 UPDATE해 실제 앱 커넥션 풀을 통한
     * 행 경합을 재현한다.
     */
    @PostMapping("/touch-recent")
    public ResponseEntity<String> touchRecent(@RequestParam(defaultValue = "5") int limit) {
        barcodeRepository.touchRecent(limit);
        return ResponseEntity.ok("touched");
    }
}
