package com.barcode.barcode_scanner_service.service.generator;

import java.util.Random;

/**
 * EAN-13(GTIN-13) 바코드 생성 전략이다. 국가 코드 "880"(한국)에 임의의 9자리를
 * 이어붙여 12자리 데이터를 만들고, 체크 디지트는 주입받은 ICheckDigitStrategy에
 * 위임한다.
 */
class EAN13Strategy implements IBarcodeStrategy {

    private final ICheckDigitStrategy checkDigitStrategy;
    private static final Random RANDOM = new Random();

    EAN13Strategy(ICheckDigitStrategy checkDigitStrategy) {
        this.checkDigitStrategy = checkDigitStrategy;
    }

    @Override
    public String generateBarcode() {
        // 국가 코드 "880"(한국) 고정. 국가가 늘어나면 CountryCode 같은 enum으로
        // 분리할 수 있는 자리다.
        StringBuilder barcodeBuilder = new StringBuilder("880");

        for (int i = 0; i < 9; i++) {
            barcodeBuilder.append(RANDOM.nextInt(10)); 
        }

        String barcode12Digit = barcodeBuilder.toString();
        String EAN13CheckDigit = checkDigitStrategy.makeCheckDigit(barcode12Digit);

        return barcode12Digit + EAN13CheckDigit;
    }

}
