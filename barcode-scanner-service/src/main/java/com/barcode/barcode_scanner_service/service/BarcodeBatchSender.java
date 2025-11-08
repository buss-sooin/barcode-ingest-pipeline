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

/*
 * 이 클래스는 센터 PC의 고속 바코드 스캔 처리를 담당합니다.
 * * 역할: 스캐너로부터 받은 데이터를 즉시 메모리에 모았다가, 
 * 네트워크 전송에 방해받지 않도록 배치(Batch)로 묶어 보내는 역할을 합니다.
 * * 성능 핵심: 데이터 수신(스캔)과 데이터 전송(네트워크 I/O)을 완전히 분리하여, 
 * 스캔 속도가 느려지는 것을 막습니다.
 * * 전송 조건: 데이터가 100건이 되거나 1초가 지나면 자동으로 전송을 시작합니다.
 */
@Slf4j
@Service
public class BarcodeBatchSender {

    private final int BATCH_SIZE_LIMIT;
    private static final long TIME_TRIGGER_MS = 1000L;
    private final BlockingQueue<BarcodeRequest> buffer = new LinkedBlockingQueue<>();
    private final ApiGatewayTransmitter transmitter;
    private final DeviceConfig deviceConfig;
    private final BarcodeService barcodeService;
    
    public BarcodeBatchSender(DeviceConfig deviceConfig, ApiGatewayTransmitter transmitter, BarcodeService barcodeService) {
        this.deviceConfig = deviceConfig;
        this.transmitter = transmitter;
        this.BATCH_SIZE_LIMIT = deviceConfig.batchSizeLimit(); 
        this.barcodeService = barcodeService;

        log.info("📢 BarcodeBatchSender 초기화 완료. DeviceID: {}, 배치 크기: {}, 시간 트리거: {}ms",
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
            log.info("📢 크기 기반 트리거 충족. 현재 {}건. 즉시 전송을 시도합니다.", BATCH_SIZE_LIMIT);
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
