package com.barcode.barcode_scanner_service.service.generator;

/**
 * EAN-13 표준(GS1)의 체크 디지트 계산 알고리즘이다. 짝수 인덱스에 가중치 1,
 * 홀수 인덱스에 가중치 3을 적용해 합산한 뒤 모듈로 10으로 체크 디지트를 구한다.
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
