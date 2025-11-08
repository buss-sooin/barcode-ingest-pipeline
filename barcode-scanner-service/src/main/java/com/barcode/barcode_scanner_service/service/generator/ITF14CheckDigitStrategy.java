package com.barcode.barcode_scanner_service.service.generator;

/**
 * ITF-14 표준에 맞는 체크 디지트 계산 알고리즘을 구현합니다.
 * * ITF-14 규칙: 13자리 데이터를 오른쪽에서 왼쪽으로 순회하며, 
 * 짝수 번째 자릿수(오른쪽에서 2, 4, 6...)에는 가중치 3을, 홀수 번째 자릿수(오른쪽에서 1, 3, 5...)에는 가중치 1을 적용합니다.
 * 최종 합산을 모듈로 10으로 처리하여 체크 디지트를 도출합니다.
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
