package com.barcode.barcode_scanner_service.service.generator;

/**
 * EAN-13 표준에 맞는 체크 디지트 계산 알고리즘을 구현합니다.
 * * EAN-13 규칙: 12자리 데이터를 왼쪽에서 오른쪽으로 순회하며, 
 * 홀수 인덱스(1, 3, 5...)에는 가중치 3을, 짝수 인덱스(0, 2, 4...)에는 가중치 1을 적용합니다.
 * 최종 합산을 모듈로 10으로 처리하여 체크 디지트를 도출합니다.
 */
class EAN13CheckDigitStrategy implements ICheckDigitStrategy {

    @Override
    public String makeCheckDigit(String barcodeDigit) {
        if (barcodeDigit == null || barcodeDigit.length() != 12 || !barcodeDigit.matches("\\d+")) {
            throw new IllegalArgumentException("EAN-13 계산을 위해 12자리의 숫자 데이터가 필요합니다.");
        }

        int sum = 0;
        
        for (int i = 0; i < 12; i++) {
            int digit = Character.getNumericValue(barcodeDigit.charAt(i));
            
            if (i % 2 != 0) { 
                sum += digit * 3;
            } else {
                sum += digit * 1;
            }
        }

        int remainder = sum % 10;
        int EAN13CheckDigit = (remainder == 0) ? 0 : (10 - remainder);

        return String.valueOf(EAN13CheckDigit);
    }

}
