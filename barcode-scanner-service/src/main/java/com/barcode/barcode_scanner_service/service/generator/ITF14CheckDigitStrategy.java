package com.barcode.barcode_scanner_service.service.generator;

/**
 * ITF-14 표준의 체크 디지트 계산 알고리즘이다. 오른쪽에서부터 순회하며 짝수
 * 번째 자릿수에 가중치 3, 홀수 번째 자릿수에 가중치 1을 적용해 합산한 뒤
 * 모듈로 10으로 체크 디지트를 구한다.
 */
class ITF14CheckDigitStrategy implements ICheckDigitStrategy {

    @Override
    public String makeCheckDigit(String barcodeDigit) {
        if (barcodeDigit == null || barcodeDigit.length() != 13 || !barcodeDigit.matches("\\d+")) {
            throw new IllegalArgumentException("ITF-14 계산을 위해 13자리의 숫자 데이터가 필요합니다.");
        }

        int sum = 0;
        
        for (int i = 12; i >= 0; i--) {
            int digit = Character.getNumericValue(barcodeDigit.charAt(i));
            
            if ((13 - i) % 2 == 0) { 
                sum += digit * 3;
            } else {
                sum += digit * 1;
            }
        }

        int remainder = sum % 10;
        int checkDigit = (remainder == 0) ? 0 : (10 - remainder);

        return String.valueOf(checkDigit);
    }

}
