package com.barcode.barcode_scanner_service.designPattern.strategyPattern.checkDigitStrategy;

/**
 * CheckDigitStrategy 인터페이스는 바코드 표준별로 체크 디지트를 계산하는 알고리즘을 정의합니다.
 * 이 인터페이스는 Strategy Pattern의 핵심으로, 모듈로 10 계산 로직을 캡슐화하고
 * IBarcodeStrategy 구현체에 주입되어 사용됩니다.
 */
public interface ICheckDigitStrategy {

    /**
     * 바코드 데이터(체크 디지트 제외)를 기반으로 최종 체크 디지트(1자리)를 계산합니다.
     * * @param data 체크 디지트 계산에 사용될 순수 숫자 데이터 (EAN-13은 12자리, ITF-14는 13자리)
     * @return 계산된 1자리 체크 디지트 문자열
     */
    String makeCheckDigit(String barcodeDigit);

}
