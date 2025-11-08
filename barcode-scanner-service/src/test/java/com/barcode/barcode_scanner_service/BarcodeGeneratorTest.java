package com.barcode.barcode_scanner_service;
import java.util.Random;

import org.junit.jupiter.api.Test;

public class BarcodeGeneratorTest {

    private static final Random RANDOM = new Random();

    public String generateRandomBarcode() {
        StringBuilder barcodeBuilder = new StringBuilder("880");

        for (int i = 0; i < 9; i++) {
            barcodeBuilder.append(RANDOM.nextInt(10)); 
        }

        String barcode12Digit = barcodeBuilder.toString();
        String EAN13CheckDigit = makeEAN13EAN13CheckDigit(barcode12Digit);

        return barcode12Digit + EAN13CheckDigit;
    }

    public String makeEAN13EAN13CheckDigit(String barcode12Digit) {
        if (barcode12Digit == null || barcode12Digit.length() != 12 || !barcode12Digit.matches("\\d+")) {
            throw new IllegalArgumentException("EAN-13 계산을 위해 12자리의 숫자 데이터가 필요합니다.");
        }

        int sum = 0;
        
        for (int i = 0; i < 12; i++) {
            int digit = Character.getNumericValue(barcode12Digit.charAt(i));
            
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

    @Test
    void printEAN13Barcode() {
        // 10개의 랜덤 바코드 데이터 생성 예시
        System.out.println("--- EAN13 Barcode Generated ---");
        for (int i = 0; i < 10; i++) {
            String barcodeData = generateRandomBarcode();
            System.out.println((i + 1) + ". " + barcodeData);
        }
        System.out.println("----------------------------------------------");
    }

    public String makeITF14CheckDigit(String barcode13Digit) {
        if (barcode13Digit == null || barcode13Digit.length() != 13 || !barcode13Digit.matches("\\d+")) {
            throw new IllegalArgumentException("ITF-14 계산을 위해 13자리의 숫자 데이터가 필요합니다.");
        }

        int sum = 0;
        
        for (int i = 12; i >= 0; i--) {
            int digit = Character.getNumericValue(barcode13Digit.charAt(i));
            
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
