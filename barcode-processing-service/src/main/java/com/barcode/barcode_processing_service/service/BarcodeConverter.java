package com.barcode.barcode_processing_service.service;

import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;

import org.springframework.stereotype.Service;

import com.barcode.barcode_processing_service.dto.BarcodeEvent;
import com.barcode.barcode_processing_service.dto.InternalBarcode;

import de.huxhorn.sulky.ulid.ULID;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Service
public class BarcodeConverter {
    
    private final ULID ulid = new ULID();

    /**
     * BarcodeEvent를 내부 시스템에서 사용할 InternalBarcode 객체로 변환합니다.
     * 내부 식별자(internalId)는 ULID를 사용하여 분산 환경 고유성을 확보합니다.
     * 패턴: 'DLV-{기기ID}-{YYMMDD}-{ULID}'
     * @param event 스캔된 바코드 이벤트
     * @return 고유 ID가 부여된 InternalBarcode 객체
     */
    public InternalBarcode convert(BarcodeEvent event) {
        String deviceId = event.deviceId(); 
        
        ZonedDateTime nowKST = ZonedDateTime.now(ZoneId.of("Asia/Seoul"));
        DateTimeFormatter dateFormatter = DateTimeFormatter.ofPattern("yyMMdd");
        String datePart = nowKST.format(dateFormatter);
        
        String uniqueUlid = ulid.nextULID(); 
        
        String internalId = String.format("DLV-%s-%s-%s",
            deviceId,
            datePart,
            uniqueUlid
        );
        
        log.debug("Converted {} → {}", event.barcode(), internalId);
        
        return InternalBarcode.create(
            internalId,
            event.barcode(),
            event.deviceId(),
            event.scanTime(),
            Instant.now().toEpochMilli()
        );
    }

}
