package com.barcode.barcode_scanner_service.service.generator;

/**
 * 바코드 표준별 체크 디지트 계산 알고리즘을 정의하는 인터페이스다. 구현체는
 * IBarcodeStrategy 구현체에 주입되어 사용된다.
 */
public interface ICheckDigitStrategy {

    /**
     * 바코드 데이터(체크 디지트 제외)로 최종 체크 디지트(1자리)를 계산한다.
     * @param barcodeDigit 체크 디지트 계산에 쓰이는 순수 숫자 데이터
     *     (EAN-13은 12자리, ITF-14는 13자리)
     * @return 계산된 1자리 체크 디지트 문자열
     */
    String makeCheckDigit(String barcodeDigit);

}
