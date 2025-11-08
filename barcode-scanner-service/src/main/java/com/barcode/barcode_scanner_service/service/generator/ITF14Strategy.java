package com.barcode.barcode_scanner_service.service.generator;

import java.util.Random;

/**
 * ITF-14 바코드의 생성 전략을 구현합니다.
 * * ITF-14는 물류 단위 식별(GTIN-14)에 사용되며 총 14자리 코드를 갖습니다. 
 * 이 전략은 한국 GS1 표준에 따라 앞자리 데이터를 생성합니다:
 * 1. 물류 식별자(LUI): 1~8 사이의 랜덤 숫자로 시작합니다.
 * 2. 국가 코드: '880'을 포함합니다.
 * * 최종적으로 생성자로 주입받은 ICheckDigitStrategy에게 계산을 위임하여 14자리 바코드를 완성합니다.
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

        barcodeBuilder.append("880");

        for (int i = 0; i < 9; i++) {
            barcodeBuilder.append(RANDOM.nextInt(10)); 
        }

        String barcode13Digit = barcodeBuilder.toString();
        String ITF14CheckDigit = checkDigitStrategy.makeCheckDigit(barcode13Digit);

        return barcode13Digit + ITF14CheckDigit;
    }

}
