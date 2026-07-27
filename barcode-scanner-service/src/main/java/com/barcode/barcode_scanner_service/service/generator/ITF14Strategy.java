package com.barcode.barcode_scanner_service.service.generator;

import java.util.Random;

/**
 * ITF-14(GTIN-14) 바코드 생성 전략이다. 물류 식별자(LUI, 1~8 임의값)에 국가 코드
 * "880"(한국)과 임의의 9자리를 이어붙여 13자리 데이터를 만들고, 체크 디지트는
 * 주입받은 ICheckDigitStrategy에 위임한다.
 */
class ITF14Strategy implements IBarcodeStrategy {

    private final ICheckDigitStrategy checkDigitStrategy;
    private static final Random RANDOM = new Random();

    ITF14Strategy(ICheckDigitStrategy checkDigitStrategy) {
        this.checkDigitStrategy = checkDigitStrategy;
    }

    @Override
    public String generateBarcode() {
        StringBuilder barcodeBuilder = new StringBuilder();

        int LUI = RANDOM.nextInt(8) + 1;
        barcodeBuilder.append(LUI);

        // 국가 코드 "880"(한국) 고정. 국가가 늘어나면 CountryCode 같은 enum으로
        // 분리할 수 있는 자리다.
        barcodeBuilder.append("880");

        for (int i = 0; i < 9; i++) {
            barcodeBuilder.append(RANDOM.nextInt(10)); 
        }

        String barcode13Digit = barcodeBuilder.toString();
        String ITF14CheckDigit = checkDigitStrategy.makeCheckDigit(barcode13Digit);

        return barcode13Digit + ITF14CheckDigit;
    }

}
