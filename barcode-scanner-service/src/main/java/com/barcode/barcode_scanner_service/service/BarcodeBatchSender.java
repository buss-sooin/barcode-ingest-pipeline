package com.barcode.barcode_scanner_service.service;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import com.barcode.barcode_scanner_service.config.DeviceConfig;
import com.barcode.barcode_scanner_service.dto.BarcodeRequest;
import com.barcode.barcode_scanner_service.dto.ClientScanRequest;
import com.barcode.barcode_scanner_service.service.generator.BarcodeType;

import lombok.extern.slf4j.Slf4j;

/**
 * 스캔 수신과 ingest 전송을 분리해 배치로 묶어 보낸다. 스캔 처리가 네트워크
 * I/O 지연에 영향받지 않도록, 버퍼에 모았다가 크기 또는 시간 임계값에 도달하면
 * 전송을 트리거하는 구조다.
 */
@Slf4j
@Service
public class BarcodeBatchSender {

    private final int BATCH_SIZE_LIMIT;
    private static final long TIME_TRIGGER_MS = 1000L;
    private final BlockingQueue<BarcodeRequest> buffer = new LinkedBlockingQueue<>();
    
    private final DeviceConfig deviceConfig;
    private final ApiGatewayTransmitter transmitter;
    private final BarcodeService barcodeService;
    
    public BarcodeBatchSender(DeviceConfig deviceConfig, ApiGatewayTransmitter transmitter, BarcodeService barcodeService) {
        this.deviceConfig = deviceConfig;
        this.transmitter = transmitter;
        this.barcodeService = barcodeService;
        this.BATCH_SIZE_LIMIT = deviceConfig.batchSizeLimit(); 

        log.info("BarcodeBatchSender 초기화 완료. DeviceID: {}, 배치 크기: {}, 시간 트리거: {}ms",
        deviceConfig.deviceId(), BATCH_SIZE_LIMIT, TIME_TRIGGER_MS);
    }

    public void addBarcodeToBuffer(ClientScanRequest clientRequest) {
        
        BarcodeRequest request = new BarcodeRequest(
            barcodeService.makeBarcode(BarcodeType.EAN13),
            clientRequest.scanTime(),
            deviceConfig.deviceId()
        );

        buffer.offer(request); 
        
        if (buffer.size() >= BATCH_SIZE_LIMIT) {
            log.info("크기 기반 트리거 충족. 현재 {}건. 즉시 전송을 시도합니다.", BATCH_SIZE_LIMIT);
            triggerBatchSend();
        } else {
            log.debug("바코드 추가됨. 현재 버퍼 {}건. (배치 임계값 {} 미달)", buffer.size(), BATCH_SIZE_LIMIT);
        }
    }

    @Scheduled(fixedDelay = TIME_TRIGGER_MS)
    public void timeTriggeredSend() {
        if (!buffer.isEmpty()) {
            triggerBatchSend();
        }
    }

    private void triggerBatchSend() {
        if (buffer.isEmpty()) {
            log.warn("경쟁 조건 감지. 다른 스레드가 이미 버퍼를 비워 전송을 중단합니다.");
            return;
        }

        List<BarcodeRequest> batch = new ArrayList<>();
        buffer.drainTo(batch, BATCH_SIZE_LIMIT); 

        if (!batch.isEmpty()) {
            transmitter.transmitBatch(batch); 
        }
    }

}
